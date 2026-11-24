import AVFoundation
import Foundation
import os

/// Native AAC playback. PlayerManager owns the queue and audio session;
/// NowPlayingManager owns remote commands for every playback engine.
@MainActor
final class YTMusicNativePlayer: YTMusicPlayer {
    var onPlaybackUpdate: ((_ isPlaying: Bool, _ currentTime: TimeInterval, _ duration: TimeInterval) -> Void)?
    var onTrackEnded: (() -> Void)?
    var onTrackMetadataChanged: ((_ title: String, _ artist: String, _ thumbnailUrl: String) -> Void)?
    var onLikeStatusChanged: ((_ status: LikeStatus) -> Void)?
    var onError: ((_ error: Error) -> Void)?
    var onAudioQualityChanged: ((_ bitrateKbps: Int, _ codec: String) -> Void)?
    var onStateChange: ((_ state: PlayerManager.PlaybackState) -> Void)?

    private let streamFetcher = StreamFetcher()
    private var session: NativePlayerSession?
    private var resolutionTask: Task<Void, Never>?
    private var streamRequestSerial = 0
    private var rejectedClients: Set<String> = []
    private var currentStreamClient: StreamClient?
    private var streamFetchTime: Date?
    private var pendingSeek: TimeInterval?
    private var lastReportedPosition: TimeInterval = 0

    private(set) var currentVideoId: String?
    private(set) var currentAudioFormat: AudioFormatInfo?
    private(set) var volume: Float = 1
    private(set) var wantsPlayback = false
    private(set) var isResolvingStream = false
    private(set) var nativeStreamFetchCompletedAt: Date?
    private(set) var hasActuallyStartedCurrentStream = false
    private(set) var lastPlaybackProgressAt: Date?

    var isPlaying: Bool { session?.isPlaying ?? false }
    var audioFormatDescription: String? { currentAudioFormat?.description }

    func loadVideo(videoId: String) async {
        if currentVideoId == videoId, let session, let fetched = streamFetchTime,
           Date().timeIntervalSince(fetched) < 5 * 60 * 60 {
            if case .failed = session.status {
                // A failed AVPlayerItem cannot be restarted by calling play().
            } else {
                play()
                return
            }
        }
        stop()
        currentVideoId = videoId
        wantsPlayback = true
        let serial = streamRequestSerial
        onStateChange?(.loading)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resolveStream(videoId: videoId, serial: serial)
        }
        resolutionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveStream(videoId: String, serial: Int) async {
        guard currentVideoId == videoId, streamRequestSerial == serial, !Task.isCancelled else { return }
        isResolvingStream = true
        nativeStreamFetchCompletedAt = nil
        MixtapeNativeAudioTrace.add("native request #\(serial) resolving; excluded profiles=\(rejectedClients.count)")
        let quality = UserDefaults.standard.string(forKey: "mixtape.ios18.streamingQuality") ?? "balanced"
        let result = await streamFetcher.fetchStream(videoId: videoId, excludingClients: rejectedClients) {
            $0.preferredNativeAudioFormat(quality: quality)
        }
        guard currentVideoId == videoId, streamRequestSerial == serial, !Task.isCancelled else { return }
        isResolvingStream = false
        nativeStreamFetchCompletedAt = Date()
        resolutionTask = nil

        switch result {
        case .success(let stream):
            currentStreamClient = stream.client
            streamFetchTime = Date()
            currentAudioFormat = streamFetcher.makeAudioFormatInfo(from: stream.format, availableFormats: stream.audioFormats.count)
            let bitrate = (stream.format.bitrate ?? 0) / 1000
            let codec = StreamFetcher.parseCodec(from: stream.format.mimeType)
            onAudioQualityChanged?(bitrate, codec)
            MixtapeNativeAudioTrace.add("native AAC \(bitrate)kbps itag=\(stream.format.itag) profile=\(stream.client.name); URLSession ranges")
            let newSession = NativePlayerSession(
                url: stream.streamURL,
                headers: [
                    "User-Agent": stream.client.userAgent,
                    "Origin": "https://www.youtube.com",
                    "Referer": "https://www.youtube.com/",
                ],
                apiDuration: stream.apiDuration
            )
            installSession(newSession, videoId: videoId, serial: serial)
        case .failure(let error):
            // PlayerManager chooses an optional fallback for this same track.
            // Preserve pause intent; a failure is never an ended-track event.
            MixtapeNativeAudioTrace.add("native discovery failed \(MixtapeNativeAudioTrace.describe(error))")
            onError?(error)
        }
    }

    private func installSession(_ newSession: NativePlayerSession, videoId: String?, serial: Int) {
        session?.pause()
        session = newSession
        hasActuallyStartedCurrentStream = false
        lastPlaybackProgressAt = nil
        lastReportedPosition = pendingSeek ?? 0

        newSession.onTimeUpdate = { [weak self, weak newSession] time, duration, playing in
            guard let self, let newSession, self.session === newSession,
                  self.streamRequestSerial == serial else { return }
            if playing && time > self.lastReportedPosition + 0.05 {
                self.lastPlaybackProgressAt = Date()
            }
            self.lastReportedPosition = time
            self.onPlaybackUpdate?(playing, time, duration)
        }
        newSession.onStatusChanged = { [weak self, weak newSession] status in
            guard let self, let newSession, self.session === newSession,
                  self.streamRequestSerial == serial else { return }
            switch status {
            case .ready:
                MixtapeNativeAudioTrace.add("AVPlayer readyToPlay")
            case .playing:
                guard self.wantsPlayback else { newSession.pause(); return }
                if !self.hasActuallyStartedCurrentStream {
                    MixtapeNativeAudioTrace.add("AVPlayer PLAYING")
                    self.lastPlaybackProgressAt = Date()
                }
                self.hasActuallyStartedCurrentStream = true
                self.onStateChange?(.playing)
            case .buffering:
                if self.wantsPlayback { self.onStateChange?(.loading) }
            case .paused:
                if !self.wantsPlayback { self.onStateChange?(.paused) }
            case .failed(let error):
                MixtapeNativeAudioTrace.add("AVPlayer failed \(MixtapeNativeAudioTrace.describe(error))")
            case .idle, .completed:
                break
            }
        }
        newSession.onTrackEnded = { [weak self, weak newSession] in
            guard let self, let newSession, self.session === newSession,
                  self.streamRequestSerial == serial else { return }
            self.wantsPlayback = false
            self.onStateChange?(.ended)
            self.onTrackEnded?()
        }
        newSession.onError = { [weak self, weak newSession] error in
            guard let self, let newSession, self.session === newSession,
                  self.streamRequestSerial == serial else { return }
            MixtapeNativeAudioTrace.add("native session error \(MixtapeNativeAudioTrace.describe(error))")
            guard let videoId, let client = self.currentStreamClient else {
                self.onError?(error)
                return
            }
            self.retryFailedStream(videoId: videoId, serial: serial, client: client.name, error: error)
        }
        newSession.volume = volume
        if let pendingSeek {
            newSession.seek(to: pendingSeek)
            self.pendingSeek = nil
        }
        if wantsPlayback { newSession.play() }
        else { onStateChange?(.paused) }
    }

    /// Obtain a fresh URL from a different profile, never replay a rejected URL.
    private func retryFailedStream(videoId: String, serial: Int, client: String, error: Error) {
        guard resolutionTask == nil else { return }
        rejectedClients.insert(client)
        pendingSeek = max(pendingSeek ?? 0, session?.currentTime ?? 0)
        session?.pause()
        session = nil
        if rejectedClients.count >= StreamClient.fallbackClients.count {
            onError?(error)
            return
        }
        if wantsPlayback { onStateChange?(.loading) }
        resolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resolveStream(videoId: videoId, serial: serial)
        }
    }

    func loadAsset(_ asset: AVURLAsset) async {
        stop()
        wantsPlayback = true
        onStateChange?(.loading)
        installSession(NativePlayerSession(asset: asset), videoId: nil, serial: streamRequestSerial)
    }

    func play() {
        wantsPlayback = true
        if let session, case .failed = session.status, let videoId = currentVideoId,
           let client = currentStreamClient {
            retryFailedStream(videoId: videoId, serial: streamRequestSerial, client: client.name,
                              error: YTMusicError.playbackError(message: "The native audio session failed."))
        } else {
            session?.play()
        }
        // Actual AVPlayer events confirm playback, never the act of requesting it.
        if isResolvingStream || session == nil { onStateChange?(.loading) }
    }

    func pause() {
        wantsPlayback = false
        session?.pause()
        onStateChange?(.paused)
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        let target = max(0, time)
        lastPlaybackProgressAt = Date()
        lastReportedPosition = target
        if let session { session.seek(to: target) }
        else { pendingSeek = target }
    }

    func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        self.volume = max(0, min(1, volume))
        session?.volume = self.volume
    }

    func stop() {
        streamRequestSerial += 1
        resolutionTask?.cancel()
        resolutionTask = nil
        wantsPlayback = false
        session?.pause()
        session = nil
        currentVideoId = nil
        currentAudioFormat = nil
        currentStreamClient = nil
        streamFetchTime = nil
        pendingSeek = nil
        rejectedClients.removeAll()
        isResolvingStream = false
        nativeStreamFetchCompletedAt = nil
        hasActuallyStartedCurrentStream = false
        lastPlaybackProgressAt = nil
    }
}

/// Persist only status, timing and domains/codes: no media URL or credentials.
@MainActor
enum MixtapeNativeAudioTrace {
    private static let key = "mixtape.ios18.v35.nativeTrace"

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var result = "\(ns.domain):\(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += " underlying=\(underlying.domain):\(underlying.code)"
        }
        return result
    }

    static func add(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let safe = message.replacingOccurrences(of: #"https?://[^\s]+"#, with: "[URL]", options: .regularExpression)
        var lines = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(stamp) \(String(safe.prefix(220)))")
        UserDefaults.standard.set(lines.suffix(75).joined(separator: "\n"), forKey: key)
    }
}
