import AVFoundation
import Foundation
import os

/// Represents a native audio playback session with AVPlayer.
/// Encapsulates the player, player item, and all observers.
@MainActor
final class NativePlayerSession {
    // MARK: - Properties

    let player: AVPlayer
    let playerItem: AVPlayerItem
    private let resourceLoader: HTTPAudioResourceLoader?

    /// Duration from API (more reliable than playerItem.duration for streams).
    let apiDuration: TimeInterval?

    private(set) var currentTime: TimeInterval = 0
    private(set) var status: Status = .idle
    private var pendingSeek: TimeInterval?

    // These observers need nonisolated(unsafe) to be accessible from deinit.
    // Safe because deinit only runs when no other references exist.
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var statusObserver: NSKeyValueObservation?
    nonisolated(unsafe) private var timeControlStatusObserver: NSKeyValueObservation?
    nonisolated(unsafe) private var endTimeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var errorLogObserver: NSObjectProtocol?
    private var reportedErrorLogEvents = 0

    private let logger = DiagnosticsLogger.player

    // MARK: - Callbacks

    var onStatusChanged: ((Status) -> Void)?
    var onTimeUpdate: ((_ currentTime: TimeInterval, _ duration: TimeInterval, _ isPlaying: Bool) -> Void)?
    var onTrackEnded: (() -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Status Enum

    enum Status {
        case idle
        case ready
        case playing
        case paused
        case buffering
        case completed
        case failed(Error)

        var isCompleted: Bool {
            if case .completed = self { return true }
            return false
        }
    }

    // MARK: - Computed Properties

    var duration: TimeInterval {
        if let apiDur = apiDuration, apiDur.isFinite, apiDur > 0 {
            return apiDur
        }
        let itemDuration = playerItem.duration.seconds
        return itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
    }

    /// Logs duration sources for debugging
    func logDurationSources() {
        let apiDur = apiDuration ?? 0
        let itemDur = playerItem.duration.seconds
        let itemDurStr = itemDur.isNaN ? "NaN" : String(format: "%.2f", itemDur)
        logger.info("[PlayerSession] Duration sources: apiDuration=\(apiDur)s, playerItem.duration=\(itemDurStr)s, using=\(self.duration)s")
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    // MARK: - Initialization

    init(url: URL, headers: [String: String]? = nil, apiDuration: TimeInterval? = nil) {
        self.apiDuration = apiDuration

        // AVFoundation delegates every remote byte range to URLSession so the
        // selected client identity remains identical to stream discovery.
        let asset: AVURLAsset
        if url.scheme == "https" || url.scheme == "http" {
            let loader = HTTPAudioResourceLoader(remoteURL: url, headers: headers ?? [:])
            self.resourceLoader = loader
            asset = AVURLAsset(url: loader.assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        } else {
            self.resourceLoader = nil
            asset = AVURLAsset(url: url)
        }

        self.playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)

        setupObservers()
        if let apiDur = apiDuration {
            logger.info("[PlayerSession] Created with apiDuration: \(apiDur)s (\(self.formatTime(apiDur)))")
        } else {
            logger.info("[PlayerSession] Created without apiDuration, will use playerItem.duration")
        }
    }

    /// Creates a session from a pre-existing AVURLAsset (e.g., a downloaded offline asset).
    init(asset: AVURLAsset, apiDuration: TimeInterval? = nil) {
        self.apiDuration = apiDuration
        self.resourceLoader = nil
        self.playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)

        setupObservers()
        logger.info("[PlayerSession] Created from local asset")
    }

    deinit {
        resourceLoader?.invalidate()
        // Cleanup observers synchronously (can't call MainActor methods from deinit)
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        statusObserver?.invalidate()
        timeControlStatusObserver?.invalidate()
        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        player.pause()
    }

    // MARK: - Playback Control

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        guard playerItem.status == .readyToPlay else {
            pendingSeek = max(0, time)
            return
        }
        let clampedTime = duration > 0 ? max(0, min(time, duration - 0.5)) : max(0, time)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        player.seek(to: cmTime) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let position = self.player.currentTime().seconds
                if position.isFinite { self.currentTime = position }
                self.sendTimeUpdate()
            }
        }
    }

    // MARK: - Observer Setup

    private func setupObservers() {
        // AVPlayer may populate its HTTP log AFTER status becomes failed.
        // Record only status codes, never event URIs, signed links or headers.
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordNewMediaErrorEvents(context: "notification")
            }
        }

        // Observe player item status
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            let status = item.status
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status)
            }
        }

        // Observe timeControlStatus for play/pause/buffering
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatus(status)
            }
        }

        // Periodic time observer (1 second interval)
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handleTimeUpdate(time)
            }
        }

        // Track ended notification
        endTimeObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.info("[PlayerSession] AVPlayerItemDidPlayToEndTime notification received")
                self?.handleTrackEnded()
            }
        }
        logger.info("[PlayerSession] Registered end time observer for playerItem")
    }

    /// Decode the AVPlayerItem network failure itself rather than relying
    /// exclusively on CoreMediaErrorDomain:-12660 -> presumed HTTP 403.
    private func recordNewMediaErrorEvents(context: String) {
        guard let events = playerItem.errorLog()?.events,
              events.count > reportedErrorLogEvents else { return }
        for event in events.dropFirst(reportedErrorLogEvents) {
            let code = event.errorStatusCode
            let status = (100...599).contains(code) ? "HTTP \(code)" : "media code \(code)"
            MixtapeNativeAudioTrace.add("AVPlayerItem error-log [\(context)]: \(status)")
        }
        reportedErrorLogEvents = events.count
    }

    // MARK: - Event Handlers

    private func handleItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            logger.info("[PlayerSession] Ready to play")
            logDurationSources()
            updateStatus(.ready)
            if let pendingSeek {
                self.pendingSeek = nil
                seek(to: pendingSeek)
            }
            sendTimeUpdate()
        case .failed:
            if let error = playerItem.error {
                let nsError = error as NSError
                logger.error("❌ [PlayerSession] Failed: domain=\(nsError.domain), code=\(nsError.code), description=\(error.localizedDescription)")
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    logger.error("   ↳ Underlying: domain=\(underlyingError.domain), code=\(underlyingError.code), description=\(underlyingError.localizedDescription)")
                }
                recordNewMediaErrorEvents(context: "item-failed")
                updateStatus(.failed(error))
                onError?(error)
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            logger.debug("[PlayerSession] Playing")
            updateStatus(.playing)
        case .paused:
            logger.debug("[PlayerSession] Paused")
            updateStatus(.paused)
        case .waitingToPlayAtSpecifiedRate:
            logger.debug("[PlayerSession] Buffering")
            updateStatus(.buffering)
        @unknown default:
            break
        }
        sendTimeUpdate()
    }

    private func handleTimeUpdate(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite, duration > 0, !status.isCompleted else { return }
        currentTime = seconds
        sendTimeUpdate()

        // Only AVPlayerItemDidPlayToEndTime ends the track. API duration can be
        // rounded or shorter than the media; a time estimate must not cut it off.
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func handleTrackEnded() {
        // Guard against multiple calls (time observer fallback + AVPlayerItemDidPlayToEndTime)
        guard !status.isCompleted else { return }
        logger.info("[PlayerSession] Track ended")
        updateStatus(.completed)
        onTrackEnded?()
    }

    private func sendTimeUpdate() {
        guard duration > 0 else { return }
        onTimeUpdate?(currentTime, duration, isPlaying)
    }

    private func updateStatus(_ newStatus: Status) {
        status = newStatus
        onStatusChanged?(newStatus)
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        statusObserver?.invalidate()
        statusObserver = nil

        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil

        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            endTimeObserver = nil
        }

        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
