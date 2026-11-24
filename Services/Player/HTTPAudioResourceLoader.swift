import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// AVPlayer requests media bytes through the same public URLSession transport
/// used by direct-media discovery. All request state lives on `queue`.
nonisolated final class HTTPAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.mixtape.audio-resource-loader")
    let assetURL = URL(string: "mixtape-audio://stream/\(UUID().uuidString).m4a")!
    private let remoteURL: URL
    private let headers: [String: String]
    private var pending: [ObjectIdentifier: PendingRequest] = [:]
    private var contentLength: Int64?
    private var invalidated = false

    nonisolated private final class PendingRequest: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        var task: Task<Void, Never>?
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
    }

    init(remoteURL: URL, headers: [String: String]) {
        self.remoteURL = remoteURL
        self.headers = headers
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !invalidated else {
            loadingRequest.finishLoading(with: CancellationError())
            return false
        }
        let request = PendingRequest(loadingRequest)
        pending[ObjectIdentifier(loadingRequest)] = request
        loadNextRange(for: request)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeValue(forKey: ObjectIdentifier(loadingRequest))?.task?.cancel()
    }

    /// Safe from NativePlayerSession's nonisolated deinit.
    func invalidate() {
        queue.async { [self] in
            invalidated = true
            for value in pending.values {
                value.task?.cancel()
                if !value.request.isCancelled { value.request.finishLoading(with: CancellationError()) }
            }
            pending.removeAll()
        }
    }

    private func loadNextRange(for value: PendingRequest) {
        let request = value.request
        guard !invalidated, !request.isCancelled,
              pending[ObjectIdentifier(request)] === value else { return }
        let offset: Int64
        let count: Int
        if let data = request.dataRequest {
            offset = max(data.currentOffset, data.requestedOffset)
            guard offset >= 0, data.requestedOffset >= 0 else {
                finish(value, error: HTTPAudioRangeError.invalidRequest)
                return
            }
            let end: Int64
            if data.requestsAllDataToEndOfResource {
                end = contentLength ?? Int64.max
            } else {
                guard data.requestedLength >= 0,
                      data.requestedOffset <= Int64.max - Int64(data.requestedLength) else {
                    finish(value, error: HTTPAudioRangeError.invalidRequest)
                    return
                }
                end = min(data.requestedOffset + Int64(data.requestedLength), contentLength ?? Int64.max)
            }
            if offset >= end { finish(value); return }
            count = Int(min(Int64(HTTPAudioRangeClient.maximumRangeLength), end - offset))
        } else {
            // AVFoundation also issues metadata-only requests.
            offset = 0
            count = 2
        }
        let url = remoteURL
        let requestHeaders = headers
        value.task = Task { [weak self, weak value] in
            do {
                let chunk = try await HTTPAudioRangeClient.fetch(url: url, headers: requestHeaders, offset: offset, length: count)
                try Task.checkCancellation()
                self?.queue.async { [weak self, weak value] in
                    guard let self, let value else { return }
                    self.deliver(chunk, to: value)
                }
            } catch {
                self?.queue.async { [weak self, weak value] in
                    guard let self, let value else { return }
                    self.finish(value, error: error)
                }
            }
        }
    }

    private func deliver(_ chunk: HTTPAudioRangeChunk, to value: PendingRequest) {
        let request = value.request
        guard !request.isCancelled, pending[ObjectIdentifier(request)] === value else { return }
        if let contentLength, contentLength != chunk.contentLength {
            finish(value, error: HTTPAudioRangeError.changedResource)
            return
        }
        contentLength = chunk.contentLength
        if let info = request.contentInformationRequest {
            info.contentLength = chunk.contentLength
            info.contentType = UTType(mimeType: chunk.mimeType)?.identifier ?? UTType.mpeg4Audio.identifier
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { finish(value); return }
        if !chunk.data.isEmpty { data.respond(with: chunk.data) }
        if chunk.data.isEmpty || data.currentOffset >= chunk.contentLength {
            finish(value)
        } else {
            loadNextRange(for: value)
        }
    }

    private func finish(_ value: PendingRequest, error: Error? = nil) {
        let request = value.request
        guard pending[ObjectIdentifier(request)] === value else { return }
        pending.removeValue(forKey: ObjectIdentifier(request))
        value.task = nil
        guard !request.isCancelled else { return }
        if let error { request.finishLoading(with: error) }
        else { request.finishLoading() }
    }
}
