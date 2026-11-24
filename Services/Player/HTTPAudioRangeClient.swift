import Foundation

/// The response body is always bounded by the requested range. This transport is
/// shared by AVPlayer's resource loader; it never rewrites a signed media URL.
nonisolated struct HTTPAudioRangeChunk: Sendable {
    let data: Data
    let contentLength: Int64
    let mimeType: String
}

nonisolated enum HTTPAudioRangeError: LocalizedError, Sendable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case invalidRange
    case unexpectedMediaType
    case incompleteBody
    case changedResource

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid audio byte range."
        case .invalidResponse: return "The audio server returned no HTTP response."
        case .httpStatus(let status): return "Audio server HTTP \(status)."
        case .invalidRange: return "The audio server returned a different byte range."
        case .unexpectedMediaType: return "The audio server returned a non-audio response."
        case .incompleteBody: return "The audio response was incomplete."
        case .changedResource: return "The audio file changed during playback."
        }
    }
}

/// Pure response validation is also exercised independently of AVFoundation.
nonisolated struct HTTPAudioRangeResponse: Sendable {
    let contentLength: Int64
    let bodyLength: Int
    let mimeType: String

    init(response: HTTPURLResponse, offset: Int64, length: Int) throws {
        guard offset >= 0, length > 0,
              offset <= Int64.max - Int64(length) else {
            throw HTTPAudioRangeError.invalidRequest
        }
        if response.statusCode == 416,
           let field = response.value(forHTTPHeaderField: "Content-Range"),
           field.lowercased().hasPrefix("bytes */"),
           let total = Int64(field.dropFirst(8)), total > 0, offset >= total {
            contentLength = total
            bodyLength = 0
            mimeType = "audio/mp4"
            return
        }
        guard response.statusCode == 206 || response.statusCode == 200 else {
            throw HTTPAudioRangeError.httpStatus(response.statusCode)
        }
        let mime = (response.mimeType ?? "audio/mp4").lowercased()
        guard mime.hasPrefix("audio/") || mime == "video/mp4" || mime == "application/octet-stream" else {
            throw HTTPAudioRangeError.unexpectedMediaType
        }
        mimeType = mime
        if response.statusCode == 200 {
            // A small complete file is valid. Reject a server that ignores Range
            // before buffering its potentially very large response body.
            let total = response.expectedContentLength
            guard offset == 0, total > 0, total <= Int64(length) else {
                throw HTTPAudioRangeError.invalidRange
            }
            contentLength = total
            bodyLength = Int(total)
            return
        }
        guard let field = response.value(forHTTPHeaderField: "Content-Range"),
              field.lowercased().hasPrefix("bytes ") else {
            throw HTTPAudioRangeError.invalidRange
        }
        let parts = field.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else {
            throw HTTPAudioRangeError.invalidRange
        }
        let limits = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard limits.count == 2, let start = Int64(limits[0]), let end = Int64(limits[1]),
              start == offset, end >= start, end < total,
              end <= offset + Int64(length) - 1 else {
            throw HTTPAudioRangeError.invalidRange
        }
        contentLength = total
        bodyLength = Int(end - start + 1)
    }
}

nonisolated enum HTTPAudioRangeClient {
    static let maximumRangeLength = 256 * 1024

    static func fetch(
        url: URL, headers: [String: String], offset: Int64, length: Int,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> HTTPAudioRangeChunk {
        guard (url.scheme == "https" || url.scheme == "http"),
              offset >= 0, length > 0, length <= maximumRangeLength,
              offset <= Int64.max - Int64(length) else {
            throw HTTPAudioRangeError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let operation = HTTPAudioRangeOperation(request: request, offset: offset, length: length, configuration: configuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// URLSession's serial delegate queue validates headers before receiving the body
/// and cancels a server that sends more than requested. A lock protects only the
/// continuation/task shared with Swift task cancellation.
nonisolated private final class HTTPAudioRangeOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let offset: Int64
    private let length: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPAudioRangeChunk, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    // Only the serial URLSession delegate queue accesses these three properties.
    private var responseInfo: HTTPAudioRangeResponse?
    private var body = Data()
    private var responseError: Error?
    private var completeAtEOF = false

    init(request: URLRequest, offset: Int64, length: Int, configuration: URLSessionConfiguration) {
        self.request = request
        self.offset = offset
        self.length = length
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.timeoutIntervalForResource = 45
        self.configuration.timeoutIntervalForRequest = 30
        self.configuration.httpShouldSetCookies = false
    }

    func start(_ continuation: CheckedContinuation<HTTPAudioRangeChunk, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        let active = lock.withLock {
            cancelled = true
            return task
        }
        active?.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse else { throw HTTPAudioRangeError.invalidResponse }
            responseInfo = try HTTPAudioRangeResponse(response: http, offset: offset, length: length)
            if http.statusCode == 416 {
                completeAtEOF = true
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        } catch {
            responseError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let info = responseInfo, body.count <= info.bodyLength,
              data.count <= info.bodyLength - body.count else {
            responseError = HTTPAudioRangeError.invalidRange
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = lock.withLock { () -> (CheckedContinuation<HTTPAudioRangeChunk, Error>?, Bool) in
            let saved = continuation
            continuation = nil
            self.task = nil
            self.session = nil
            return (saved, cancelled)
        }
        session.finishTasksAndInvalidate()
        guard let continuation = completion.0 else { return }
        if completion.1 { continuation.resume(throwing: CancellationError()); return }
        if completeAtEOF, let info = responseInfo {
            continuation.resume(returning: HTTPAudioRangeChunk(data: Data(), contentLength: info.contentLength, mimeType: info.mimeType))
            return
        }
        if let failure = responseError ?? error { continuation.resume(throwing: failure); return }
        guard let info = responseInfo, body.count == info.bodyLength else {
            continuation.resume(throwing: HTTPAudioRangeError.incompleteBody)
            return
        }
        continuation.resume(returning: HTTPAudioRangeChunk(data: body, contentLength: info.contentLength, mimeType: info.mimeType))
    }
}
