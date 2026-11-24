import AVFoundation
import Foundation
import Observation
import os
#if os(iOS)
import UIKit
#endif

// MARK: - DownloadManager

/// Manages offline AAC downloads through validated HTTP byte ranges.
///
/// Downloads direct AAC audio streams as `.m4a` files that `AVPlayer` can play
/// natively offline. Persists a JSON catalog following the `FavoritesManager` pattern.
@MainActor
@Observable
final class DownloadManager: NSObject, DownloadManagerProtocol {

    // MARK: - Observable State

    /// Completed downloads available for offline playback.
    private(set) var downloads: [DownloadedSong] = []

    /// Active and pending download tasks.
    private(set) var activeTasks: [DownloadTaskInfo] = []

    /// Saved playlists/albums with their associated song IDs.
    private(set) var playlists: [DownloadedPlaylist] = []

    /// Whether any download is currently in progress.
    var isDownloading: Bool {
        activeTasks.contains { $0.state == .downloading || $0.state == .fetchingURL }
    }

    /// Songs not associated with any downloaded playlist.
    var looseSongs: [DownloadedSong] {
        let playlistSongIds = Set(playlists.flatMap(\.songIds))
        return downloads.filter { !playlistSongIds.contains($0.id) }
    }

    // MARK: - Constants

    private static let maxConcurrentDownloads = 3
    private static let sessionIdentifier = "com.alexcding.mixtape.downloads"

    // MARK: - Private Properties

    private let logger = DiagnosticsLogger.download
    private let skipPersistence: Bool

    @ObservationIgnored
    private let streamFetcher = StreamFetcher()

    /// Maps `URLSessionDownloadTask.taskIdentifier` → videoId for delegate callbacks.
    @ObservationIgnored
    private var taskIdentifierToVideoId: [Int: String] = [:]

    /// Background download session.
    @ObservationIgnored
    private var _downloadSession: URLSession?

    /// One foreground worker owns resolution, transfer and finalization for each song.
    @ObservationIgnored
    private var segmentedDownloadTasks: [String: Task<Void, Never>] = [:]

    /// A cancelled attempt must never update a newly queued attempt for the same song.
    @ObservationIgnored
    private var attemptTokens: [String: UUID] = [:]

    @ObservationIgnored
    private var legacyTaskTokens: [Int: UUID] = [:]

    @ObservationIgnored
    private var legacyFinalizationTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var repairTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    @ObservationIgnored
    private var isReconcilingSession = false

    /// Atomic writes also need ordering: an older snapshot must not overwrite a newer one.
    @ObservationIgnored
    private let catalogWriteQueue = DispatchQueue(label: "com.alexcding.mixtape.download-catalog")

    /// Returns (or creates) the background download session.
    private func getDownloadSession() -> URLSession {
        if let session = _downloadSession { return session }
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        let session = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: .main
        )
        _downloadSession = session
        return session
    }

    // MARK: - Persistence

    private static var catalogURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let mixtapeDir = appSupport.appendingPathComponent("Mixtape", isDirectory: true)
        return mixtapeDir.appendingPathComponent("downloads-catalog.json")
    }

    private static var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
    }

    private static var thumbnailsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    // MARK: - Initialization

    override init() {
        self.skipPersistence = false
        super.init()
        loadCatalog()
        reconcileWithSession()
    }

    /// Testing initializer that skips persistence and session setup.
    init(skipPersistence: Bool) {
        self.skipPersistence = skipPersistence
        super.init()
        if !skipPersistence {
            loadCatalog()
            reconcileWithSession()
        }
    }

    // MARK: - Query Methods

    func isDownloaded(videoId: String) -> Bool {
        localFileURL(for: videoId) != nil
    }

    func downloadState(for videoId: String) -> DownloadTaskInfo.DownloadState? {
        if isDownloaded(videoId: videoId) { return .completed }
        return activeTasks.first { $0.id == videoId }?.state
    }

    func progress(for videoId: String) -> Double {
        activeTasks.first { $0.id == videoId }?.progress ?? 0
    }

    func localAsset(for videoId: String) -> AVURLAsset? {
        guard let fileURL = localFileURL(for: videoId) else { return nil }
        return AVURLAsset(url: fileURL)
    }

    func localFileURL(for videoId: String) -> URL? {
        guard let downloaded = downloads.first(where: { $0.id == videoId }) else { return nil }
        let fileURL = Self.audioDirectory.appendingPathComponent(downloaded.assetLocation)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.warning("Downloaded audio missing at: \(downloaded.assetLocation)")
            return nil
        }
        return fileURL
    }

    // MARK: - Download Actions

    func download(song: Song) async {
        // Skip if already downloaded or in queue
        guard !isDownloaded(videoId: song.videoId),
              !activeTasks.contains(where: { $0.id == song.videoId })
        else {
            logger.info("Song already downloaded or queued: \(song.videoId)")
            return
        }

        let task = DownloadTaskInfo(
            id: song.videoId,
            song: song,
            state: .pending,
            progress: 0,
            error: nil,
            addedAt: Date()
        )
        activeTasks.append(task)
        saveCatalog()
        logger.info("Queued download: \(song.title)")

        await processQueue()
    }

    func downloadAll(songs: [Song]) async {
        for song in songs {
            guard !isDownloaded(videoId: song.videoId),
                  !activeTasks.contains(where: { $0.id == song.videoId })
            else { continue }

            let task = DownloadTaskInfo(
                id: song.videoId,
                song: song,
                state: .pending,
                progress: 0,
                error: nil,
                addedAt: Date()
            )
            activeTasks.append(task)
        }
        saveCatalog()
        logger.info("Queued batch download: \(songs.count) songs")

        await processQueue()
    }

    func downloadPlaylist(_ playlist: Playlist, songs: [Song]) async {
        let songIds = songs.map(\.videoId)

        // Create or update the playlist entry
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            // Merge new song IDs (preserve order, avoid duplicates)
            let existing = Set(playlists[index].songIds)
            let newIds = songIds.filter { !existing.contains($0) }
            playlists[index].songIds.append(contentsOf: newIds)
        } else {
            let downloadedPlaylist = DownloadedPlaylist(
                id: playlist.id,
                title: playlist.title,
                thumbnailURL: playlist.thumbnailURL,
                author: playlist.author,
                isAlbum: playlist.isAlbum,
                songIds: songIds,
                downloadedAt: Date()
            )
            playlists.append(downloadedPlaylist)
        }

        // Queue the actual song downloads
        await downloadAll(songs: songs)
    }

    func deletePlaylist(playlistId: String) {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }

        // Find songs unique to this playlist (not in other playlists)
        let otherPlaylistSongIds = Set(
            playlists.filter { $0.id != playlistId }.flatMap(\.songIds)
        )
        let uniqueSongIds = playlist.songIds.filter { !otherPlaylistSongIds.contains($0) }

        // Delete songs that aren't shared with other playlists
        for videoId in uniqueSongIds {
            deleteDownload(videoId: videoId)
        }

        playlists.removeAll { $0.id == playlistId }
        saveCatalog()
        logger.info("Deleted playlist: \(playlist.title) (\(uniqueSongIds.count) songs removed)")
    }

    func cancel(videoId: String) {
        repairTasks.removeValue(forKey: videoId)?.task.cancel()
        if let taskId = taskIdentifierToVideoId.first(where: { $0.value == videoId })?.key {
            getDownloadSession().getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == taskId }?.cancel()
            }
            taskIdentifierToVideoId.removeValue(forKey: taskId)
            legacyTaskTokens.removeValue(forKey: taskId)
        }

        segmentedDownloadTasks.removeValue(forKey: videoId)?.cancel()
        attemptTokens.removeValue(forKey: videoId)
        activeTasks.removeAll { $0.id == videoId }
        saveCatalog()
        logger.info("Cancelled download: \(videoId)")

        Task { await processQueue() }
    }

    func retry(videoId: String) async {
        guard let index = activeTasks.firstIndex(where: { $0.id == videoId && $0.state == .failed }) else { return }
        activeTasks[index].state = .pending
        activeTasks[index].progress = 0
        activeTasks[index].error = nil
        saveCatalog()
        logger.info("Retrying download: \(videoId)")

        await processQueue()
    }

    func deleteDownload(videoId: String) {
        repairTasks.removeValue(forKey: videoId)?.task.cancel()
        guard let downloaded = downloads.first(where: { $0.id == videoId }) else { return }

        // Remove the audio file
        let audioURL = Self.audioDirectory.appendingPathComponent(downloaded.assetLocation)
        try? FileManager.default.removeItem(at: audioURL)

        // Remove cached thumbnail
        if let thumbFile = downloaded.thumbnailFileName {
            let thumbURL = Self.thumbnailsDirectory.appendingPathComponent(thumbFile)
            try? FileManager.default.removeItem(at: thumbURL)
        }

        downloads.removeAll { $0.id == videoId }
        saveCatalog()
        logger.info("Deleted download: \(videoId)")
    }

    func deleteAllDownloads() {
        // Cancel all active session tasks
        getDownloadSession().getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
        taskIdentifierToVideoId.removeAll()
        legacyTaskTokens.removeAll()
        attemptTokens.removeAll()
        for repair in repairTasks.values { repair.task.cancel() }
        repairTasks.removeAll()
        for (_, task) in segmentedDownloadTasks { task.cancel() }
        segmentedDownloadTasks.removeAll()
        activeTasks.removeAll()

        // Delete all audio files and thumbnails
        let fm = FileManager.default
        try? fm.removeItem(at: Self.audioDirectory)
        try? fm.removeItem(at: Self.thumbnailsDirectory)

        downloads.removeAll()
        playlists.removeAll()
        saveCatalog()
        logger.info("Deleted all downloads")
    }

    // MARK: - Queue Processing

    private func processQueue() async {
        guard !isReconcilingSession else { return }
        // Reserve every slot before yielding to a resolver. Reentrant callers see
        // the reserved state rather than a stale snapshot of pending songs.
        let activeCount = activeTasks.filter { $0.state == .downloading || $0.state == .fetchingURL }.count
        let slotsAvailable = max(0, Self.maxConcurrentDownloads - activeCount)
        let pendingIDs = Array(activeTasks.filter { $0.state == .pending }.prefix(slotsAvailable).map(\.id))
        for videoId in pendingIDs {
            guard let index = activeTasks.firstIndex(where: { $0.id == videoId && $0.state == .pending }),
                  segmentedDownloadTasks[videoId] == nil else { continue }
            let token = UUID()
            attemptTokens[videoId] = token
            activeTasks[index].state = .fetchingURL
            activeTasks[index].error = nil
            segmentedDownloadTasks[videoId] = Task { @MainActor [weak self] in
                guard let self else { return }
                await BackgroundTaskHelper.withBackgroundTask {
                    await self.startDownload(videoId: videoId, token: token)
                }
                // An older cancelled task must not remove the replacement's handle.
                if self.attemptTokens[videoId] == token {
                    self.segmentedDownloadTasks.removeValue(forKey: videoId)
                    self.attemptTokens.removeValue(forKey: videoId)
                }
                await self.processQueue()
            }
        }
        if !pendingIDs.isEmpty { saveCatalog() }
    }

    private func isCurrentAttempt(videoId: String, token: UUID) -> Bool {
        !Task.isCancelled && attemptTokens[videoId] == token &&
            activeTasks.contains { $0.id == videoId }
    }

    private func failAttempt(videoId: String, token: UUID, error: Error) {
        guard isCurrentAttempt(videoId: videoId, token: token),
              let index = activeTasks.firstIndex(where: { $0.id == videoId }) else { return }
        activeTasks[index].state = .failed
        activeTasks[index].error = error.localizedDescription
        saveCatalog()
        MixtapeNativeAudioTrace.add("download failed \(MixtapeNativeAudioTrace.describe(error))")
    }

    private func startDownload(videoId: String, token: UUID) async {
        let desiredQuality = UserDefaults.standard.string(forKey: "mixtape.ios18.downloadQuality") ?? "balanced"
        var excludedClients: Set<String> = []
        // A refused/expired URL gets one fresh resolution through another profile.
        // Replaying a full-file request against the same refused URL cannot repair it.
        for resolutionAttempt in 0...1 {
            guard isCurrentAttempt(videoId: videoId, token: token) else { return }
            let result = await streamFetcher.fetchStream(videoId: videoId, excludingClients: excludedClients) { response in
                response.preferredNativeAudioFormat(quality: desiredQuality)
            }
            guard isCurrentAttempt(videoId: videoId, token: token) else { return }
            switch result {
            case .failure(let error):
                failAttempt(videoId: videoId, token: token, error: error)
                return
            case .success(let stream):
                guard let index = activeTasks.firstIndex(where: { $0.id == videoId }) else { return }
                activeTasks[index].state = .downloading
                activeTasks[index].progress = 0
                saveCatalog()
                MixtapeNativeAudioTrace.add("download: range transfer profile=\(stream.client.name) itag=\(stream.format.itag)")
                do {
                    let temporary = try await MixtapeHTTPAudioTransfer.fetch(
                        url: stream.streamURL,
                        expectedBytes: stream.format.contentLengthBytes ?? 0,
                        userAgent: stream.client.userAgent
                    ) { [weak self] fraction in
                        guard let self, self.isCurrentAttempt(videoId: videoId, token: token),
                              let i = self.activeTasks.firstIndex(where: { $0.id == videoId }) else { return }
                        self.activeTasks[i].progress = min(max(fraction, 0), 1)
                    }
                    await finishDownloadedAudio(
                        videoId: videoId, token: token, fileURL: temporary,
                        mimeType: stream.format.mimeType
                    )
                    return
                } catch {
                    guard isCurrentAttempt(videoId: videoId, token: token) else { return }
                    if resolutionAttempt == 0,
                       let failure = error as? MixtapeHTTPAudioTransfer.Failure,
                       case .unexpectedHTTP(let status) = failure,
                       [401, 403, 410].contains(status) {
                        excludedClients.insert(stream.client.name)
                        if let i = activeTasks.firstIndex(where: { $0.id == videoId }) {
                            activeTasks[i].state = .fetchingURL
                            activeTasks[i].progress = 0
                        }
                        saveCatalog()
                        MixtapeNativeAudioTrace.add("download: HTTP \(status), refreshing stream profile")
                        continue
                    }
                    failAttempt(videoId: videoId, token: token, error: error)
                    return
                }
            }
        }
    }

    // MARK: - Session Reconciliation

    /// Reconciles persisted catalog with actual session tasks after app relaunch.
    private func reconcileWithSession() {
        guard !skipPersistence else { return }
        isReconcilingSession = true
        getDownloadSession().getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var restoredIDs: Set<String> = []
                for task in tasks where task.state == .running || task.state == .suspended {
                    // New foreground range transfers persist their queue entry and restart
                    // after termination. Old background tasks can be retained only when
                    // their stable identity is known; never infer it from a signed URL.
                    guard let videoId = task.taskDescription,
                          self.activeTasks.contains(where: { $0.id == videoId }),
                          restoredIDs.insert(videoId).inserted else {
                        task.cancel()
                        continue
                    }
                    let token = self.attemptTokens[videoId] ?? UUID()
                    self.attemptTokens[videoId] = token
                    self.taskIdentifierToVideoId[task.taskIdentifier] = videoId
                    self.legacyTaskTokens[task.taskIdentifier] = token
                    if let index = self.activeTasks.firstIndex(where: { $0.id == videoId }) {
                        self.activeTasks[index].state = .downloading
                    }
                    if task.state == .suspended { task.resume() }
                }
                for index in self.activeTasks.indices {
                    let task = self.activeTasks[index]
                    if (task.state == .fetchingURL || task.state == .downloading),
                       !restoredIDs.contains(task.id), self.attemptTokens[task.id] == nil {
                        self.activeTasks[index].state = .pending
                        self.activeTasks[index].progress = 0
                        self.activeTasks[index].error = nil
                    }
                }
                self.isReconcilingSession = false
                self.saveCatalog()
                self.logger.info("Session reconciled: \(restoredIDs.count) identified background tasks")
                await self.processQueue()
            }
        }
    }

    // MARK: - Catalog Persistence

    private func loadCatalog() {
        do {
            guard FileManager.default.fileExists(atPath: Self.catalogURL.path) else {
                logger.debug("No download catalog found, starting fresh")
                return
            }
            let data = try Data(contentsOf: Self.catalogURL)
            let catalog = try JSONDecoder().decode(DownloadCatalog.self, from: data)
            var seenDownloads: Set<String> = []
            downloads = Array(catalog.downloads.reversed().filter { seenDownloads.insert($0.id).inserted }.reversed())
            let completedIDs = Set(downloads.filter {
                FileManager.default.fileExists(atPath: Self.audioDirectory.appendingPathComponent($0.assetLocation).path)
            }.map(\.id))
            var seenTasks: Set<String> = []
            activeTasks = catalog.pendingTasks.filter {
                !completedIDs.contains($0.id) && seenTasks.insert($0.id).inserted
            }
            for index in activeTasks.indices where activeTasks[index].state == .completed {
                activeTasks[index].state = .pending
                activeTasks[index].progress = 0
            }
            playlists = catalog.playlists
            logger.info("Loaded catalog: \(catalog.downloads.count) downloads, \(catalog.playlists.count) playlists, \(catalog.pendingTasks.count) pending")
        } catch {
            logger.error("Failed to load download catalog: \(error.localizedDescription)")
            downloads = []
            activeTasks = []
            playlists = []
        }
    }

    private func saveCatalog() {
        guard !skipPersistence else { return }

        let snapshot = DownloadCatalog(
            downloads: downloads,
            pendingTasks: activeTasks,
            playlists: playlists
        )
        let targetURL = Self.catalogURL
        let logger = self.logger

        do {
            let data = try JSONEncoder().encode(snapshot)
            catalogWriteQueue.async {
                do {
                    let directory = targetURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: targetURL, options: .atomic)
                    logger.debug("Saved download catalog")
                } catch {
                    logger.error("Failed to save download catalog: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to encode download catalog: \(error.localizedDescription)")
        }
    }

    // MARK: - Repair audio tails (iOS 18)

    /// Find the last audible decoded PCM frame, even if container timestamps
    /// or AAC padding make AVPlayer report a much longer duration. This function
    /// runs off the main actor, never during app initialization.
    nonisolated private static func audibleEndOfM4A(_ url: URL) -> (decoded: Double, audible: Double)? {
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            let frames = file.length
            guard rate > 0, frames > 0,
                  Double(frames) / rate < 10_800,
                  file.processingFormat.commonFormat == .pcmFormatFloat32,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
            else { return nil }

            var cursor = frames
            let channels = Int(file.processingFormat.channelCount)
            guard channels > 0 else { return nil }
            // Work backwards in small PCM blocks; stop at the last frame whose
            // peak exceeds -56 dBFS. Only long tails are candidates for repair.
            while cursor > 0 {
                guard !Task.isCancelled else { return nil }
                let start = max(0, cursor - AVAudioFramePosition(8192))
                file.framePosition = start
                try file.read(into: buffer, frameCount: AVAudioFrameCount(cursor - start))
                guard let data = buffer.floatChannelData else { return nil }
                if buffer.frameLength > 0 {
                    for i in stride(from: Int(buffer.frameLength) - 1, through: 0, by: -1) {
                        var audible = false
                        for channel in 0..<channels {
                            if abs(data[channel][i]) > 0.0016 {
                                audible = true
                                break
                            }
                        }
                        if audible {
                            return (Double(frames) / rate, Double(start + AVAudioFramePosition(i) + 1) / rate)
                        }
                    }
                }
                cursor = start
            }
        } catch { return nil }
        return nil  // No audible samples; never replace with an empty file.
    }

    /// Only repairs long, high-confidence silent tails. Never removes short
    /// fades or ordinary intentional quiet transitions.
    private func repairM4ATailIfNeeded(at url: URL, expectedDuration: TimeInterval?) async {
        guard url.pathExtension.lowercased() == "m4a" else { return }
        let readingTask = Task.detached(priority: .utility) {
            Self.audibleEndOfM4A(url)
        }
        let reading = await withTaskCancellationHandler {
            await readingTask.value
        } onCancel: {
            readingTask.cancel()
        }
        guard !Task.isCancelled, let reading else {
            logger.warning("Cannot scan downloaded AAC: \(url.lastPathComponent)")
            return
        }

        let asset = AVURLAsset(url: url)
        guard let reported = try? await asset.load(.duration).seconds, !Task.isCancelled,
              reported.isFinite, reported > 5 else { return }
        let trailing = reading.decoded - reading.audible
        let hasLongSilence = trailing >= 45 && trailing / reading.decoded > 0.18
        let veryLongSilentTail = trailing >= 90 && trailing / reading.decoded > 0.30
        let hasPhantomDuration = reported > reading.decoded + 45 &&
            abs(reading.audible - reading.decoded) < 12
        // Metadata can ALSO be wrong (even double the actual track duration).
        // A very long decoded silent tail is sufficient evidence by itself.
        let agreesWithReference = expectedDuration == nil ||
            abs((expectedDuration ?? reading.audible) - reading.audible) < 25
        guard veryLongSilentTail || (hasLongSilence && agreesWithReference) || hasPhantomDuration else {
            logger.info("Audio tail check: media=\(reported)s, decoded=\(reading.decoded)s, audible=\(reading.audible)s; preserved")
            return
        }

        let cutAt = min(reading.audible + 0.8, reading.decoded)
        guard cutAt >= 10, reported > cutAt + 30 else { return }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
              exporter.supportedFileTypes.contains(.m4a) else {
            logger.warning("AAC tail repair export unavailable")
            return
        }
        let tempURL = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString)-repaired.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        exporter.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: cutAt, preferredTimescale: 600)
        )
        do {
            try await exporter.export(to: tempURL, as: .m4a)
            try Task.checkCancellation()
            let trimmedAsset = AVURLAsset(url: tempURL)
            let trimmed = try await trimmedAsset.load(.duration).seconds
            try Task.checkCancellation()
            guard trimmed.isFinite, abs(trimmed - cutAt) < 8,
                  let size = try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 4096 else {
                throw NSError(domain: "MixtapeAudioTail", code: 1)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            logger.info("Audio tail repaired: \(reported)s -> \(trimmed)s (\(url.lastPathComponent))")
        } catch {
            logger.warning("Tail repair skipped; original preserved: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Explicit repair for songs downloaded by earlier versions.
    func repairExistingDownloadIfNeeded(videoId: String, force: Bool = false) async {
        // Quiet endings can be intentional. Only the explicit repair menu may trim audio.
        guard force else { return }
        if let existing = repairTasks[videoId] {
            await existing.task.value
            return
        }
        guard let downloaded = downloads.first(where: { $0.id == videoId }),
              let local = localFileURL(for: videoId) else { return }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.repairM4ATailIfNeeded(at: local, expectedDuration: downloaded.song.duration)
            guard !Task.isCancelled, self.repairTasks[videoId]?.token == token,
                  let index = self.downloads.firstIndex(where: {
                      $0.id == videoId && $0.assetLocation == downloaded.assetLocation
                  }), let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            let old = self.downloads[index]
            self.downloads[index] = DownloadedSong(
                id: old.id, song: old.song, assetLocation: old.assetLocation,
                fileSize: Int64(size), downloadedAt: old.downloadedAt,
                thumbnailFileName: old.thumbnailFileName
            )
            self.saveCatalog()
        }
        repairTasks[videoId] = (token, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if repairTasks[videoId]?.token == token { repairTasks.removeValue(forKey: videoId) }
    }

    /// Decode samples near the beginning, middle and end before publishing a file.
    /// Silence is valid music data and is never trimmed by download validation.
    nonisolated private static func validateDownloadedAudio(at url: URL) throws -> Int64 {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0 else {
            throw NSError(domain: "MixtapeDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloaded audio is empty"])
        }
        let audio = try AVAudioFile(forReading: url)
        let format = audio.processingFormat
        guard audio.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw NSError(domain: "MixtapeDownload", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded file has no decodable audio"])
        }
        let positions: [AVAudioFramePosition] = [0, max(0, audio.length / 2 - 2048), max(0, audio.length - 4096)]
        for position in Set(positions) {
            audio.framePosition = position
            let requested = AVAudioFrameCount(min(4096, audio.length - position))
            try audio.read(into: buffer, frameCount: requested)
            guard requested > 0, buffer.frameLength == requested else {
                throw NSError(domain: "MixtapeDownload", code: 3, userInfo: [NSLocalizedDescriptionKey: "Downloaded audio is incomplete"])
            }
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) where !channels[channel][frame].isFinite {
                        throw NSError(domain: "MixtapeDownload", code: 4, userInfo: [NSLocalizedDescriptionKey: "Downloaded audio contains invalid samples"])
                    }
                }
            }
        }
        return size
    }

    /// Both HTTP range transfers and restored background tasks use this finalizer.
    private func finishDownloadedAudio(videoId: String, token: UUID, fileURL: URL, mimeType: String) async {
        // The staged URL belongs only to this attempt, so cancelling cannot delete
        // another attempt's media while validation is suspended.
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard isCurrentAttempt(videoId: videoId, token: token) else { return }
        do {
            let size = try await Task.detached(priority: .utility) {
                try Self.validateDownloadedAudio(at: fileURL)
            }.value
            guard isCurrentAttempt(videoId: videoId, token: token),
                  let index = activeTasks.firstIndex(where: { $0.id == videoId }) else { return }
            let song = activeTasks[index].song
            let ext = mimeType.hasPrefix("audio/webm") ? "opus" : "m4a"
            let fileName = "\(token.uuidString).\(ext)"
            let destination = Self.audioDirectory.appendingPathComponent(fileName)
            try FileManager.default.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            let previous = downloads.filter { $0.id == videoId }
            downloads.removeAll { $0.id == videoId }
            downloads.append(DownloadedSong(
                id: videoId, song: song, assetLocation: fileName,
                fileSize: size, downloadedAt: Date(), thumbnailFileName: nil
            ))
            activeTasks.remove(at: index)
            saveCatalog()
            for old in previous {
                if old.assetLocation != fileName {
                    try? FileManager.default.removeItem(at: Self.audioDirectory.appendingPathComponent(old.assetLocation))
                }
                if let thumbnail = old.thumbnailFileName {
                    try? FileManager.default.removeItem(at: Self.thumbnailsDirectory.appendingPathComponent(thumbnail))
                }
            }
            MixtapeNativeAudioTrace.add("download: saved decodable AAC bytes=\(size)")
            Task { [weak self] in
                guard let self, let thumbnail = await self.cacheThumbnail(for: song) else { return }
                guard let i = self.downloads.firstIndex(where: { $0.id == videoId && $0.assetLocation == fileName }) else {
                    try? FileManager.default.removeItem(at: Self.thumbnailsDirectory.appendingPathComponent(thumbnail))
                    return
                }
                let old = self.downloads[i]
                self.downloads[i] = DownloadedSong(
                    id: old.id, song: old.song, assetLocation: old.assetLocation,
                    fileSize: old.fileSize, downloadedAt: old.downloadedAt,
                    thumbnailFileName: thumbnail
                )
                self.saveCatalog()
            }
        } catch {
            failAttempt(videoId: videoId, token: token, error: error)
        }
    }

    // MARK: - Thumbnail Caching

    private func cacheThumbnail(for song: Song) async -> String? {
        guard let thumbnailURL = song.thumbnailURL else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: thumbnailURL)
            let fileName = "\(UUID().uuidString).jpg"
            let dir = Self.thumbnailsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            logger.warning("Failed to cache thumbnail for \(song.videoId): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Storage Info

    /// Total size of all downloaded assets in bytes.
    var totalDownloadSize: Int64 {
        downloads.reduce(0) { $0 + $1.fileSize }
    }

    /// Formatted total download size string.
    var totalDownloadSizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadSize, countStyle: .file)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let mimeType = response?.mimeType ?? "unknown"
        // URLSession owns `location` only until this delegate method returns.
        // Preserve it synchronously before starting asynchronous validation.
        MainActor.assumeIsolated {
            guard let videoId = taskIdentifierToVideoId.removeValue(forKey: taskId),
                  let token = legacyTaskTokens.removeValue(forKey: taskId),
                  isCurrentAttempt(videoId: videoId, token: token) else { return }
            guard (200..<300).contains(status) else {
                failAttempt(videoId: videoId, token: token, error: MixtapeHTTPAudioTransfer.Failure.unexpectedHTTP(status))
                attemptTokens.removeValue(forKey: videoId)
                Task { await processQueue() }
                return
            }
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            do {
                try FileManager.default.moveItem(at: location, to: staged)
                legacyFinalizationTasks[token] = Task { @MainActor [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: staged)
                        return
                    }
                    await self.finishDownloadedAudio(videoId: videoId, token: token, fileURL: staged, mimeType: mimeType)
                    self.legacyFinalizationTasks.removeValue(forKey: token)
                    if self.attemptTokens[videoId] == token {
                        self.attemptTokens.removeValue(forKey: videoId)
                    }
                    await self.processQueue()
                }
            } catch {
                failAttempt(videoId: videoId, token: token, error: error)
                attemptTokens.removeValue(forKey: videoId)
                Task { await processQueue() }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
        } else {
            progress = 0
        }

        MainActor.assumeIsolated {
            guard let videoId = taskIdentifierToVideoId[taskId],
                  let token = legacyTaskTokens[taskId],
                  isCurrentAttempt(videoId: videoId, token: token) else { return }
            if let index = activeTasks.firstIndex(where: { $0.id == videoId }) {
                activeTasks[index].progress = progress
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskId = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let videoId = taskIdentifierToVideoId.removeValue(forKey: taskId),
                  let token = legacyTaskTokens.removeValue(forKey: taskId),
                  attemptTokens[videoId] == token else { return }
            // Cancellation removes queue entries explicitly in cancel/deleteAll.
            // A system/network cancellation leaves a retryable error instead.
            failAttempt(videoId: videoId, token: token, error: error)
            attemptTokens.removeValue(forKey: videoId)
            Task { await processQueue() }
        }
    }

    #if os(iOS)
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                  let handler = appDelegate.backgroundSessionCompletionHandler else { return }
            appDelegate.backgroundSessionCompletionHandler = nil
            let finalizers = Array(legacyFinalizationTasks.values)
            Task { @MainActor in
                for finalizer in finalizers { await finalizer.value }
                // Let every preceding catalogue snapshot reach disk before iOS suspends us.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    catalogWriteQueue.async { continuation.resume() }
                }
                handler()
            }
        }
    }
    #endif
}
