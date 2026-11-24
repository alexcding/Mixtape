import Foundation

/// HTTP ranges for offline AAC files. Network data lands in temporary files;
/// only a small copy buffer is held in memory, including servers ignoring Range.
nonisolated enum MixtapeHTTPAudioTransfer {
    static let maximumFileSize: Int64 = 200_000_000
    static let chunkSize: Int64 = 512 * 1024

    enum Failure: LocalizedError {
        case invalidSize
        case unexpectedHTTP(Int)
        case wrongRange
        case wrongLength(Int, Int)
        case invalidResponse
        case invalidMedia

        var errorDescription: String? {
            switch self {
            case .invalidSize: return "The audio file is empty or exceeds the download limit."
            case .unexpectedHTTP(let status): return "Audio server returned HTTP \(status)."
            case .wrongRange: return "The audio server returned an inconsistent byte range."
            case .wrongLength(let actual, let expected):
                return "Incomplete audio range (\(actual) of \(expected) bytes)."
            case .invalidResponse: return "The audio server returned an invalid response."
            case .invalidMedia: return "The server response is not an MP4 audio file."
            }
        }
    }

    struct ByteRange: Equatable, Sendable {
        let start: Int64
        let end: Int64
        let total: Int64
        var count: Int64 { end - start + 1 }

        init(_ header: String) throws {
            let fields = header.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].lowercased() == "bytes" else { throw Failure.wrongRange }
            let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let total = Int64(parts[1]), total > 0,
                  total <= maximumFileSize else { throw Failure.invalidSize }
            let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, end >= start, end < total else { throw Failure.wrongRange }
            self.start = start
            self.end = end
            self.total = total
        }

        func validate(offset: Int64, requestedEnd: Int64, previousTotal: Int64?, received: Int64) throws {
            guard start == offset, end <= requestedEnd,
                  previousTotal == nil || previousTotal == total else { throw Failure.wrongRange }
            guard received == count else { throw Failure.wrongLength(Int(received), Int(count)) }
        }
    }

    static func request(url: URL, userAgent: String, start: Int64, end: Int64) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    static func validateMediaType(_ response: HTTPURLResponse) throws {
        guard let mime = response.mimeType?.lowercased() else { return }
        guard ["audio/mp4", "video/mp4", "application/mp4", "application/octet-stream", "binary/octet-stream"].contains(mime)
        else { throw Failure.invalidMedia }
    }

    static func validateMP4Prefix(_ prefix: Data) throws {
        guard prefix.count >= 12, String(data: prefix.dropFirst(4).prefix(4), encoding: .ascii) == "ftyp"
        else { throw Failure.invalidMedia }
    }

    /// Probe the first real bytes with the identity used for playback/downloads.
    /// Small files are valid; there is no hard-coded second offset beyond EOF.
    static func probe(url: URL, userAgent: String) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request(url: url, userAgent: userAgent, start: 0, end: 1023))
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 206 else { return http.statusCode }
        try validateMediaType(http)
        let range: ByteRange?
        if http.statusCode == 206 {
            range = try ByteRange(http.value(forHTTPHeaderField: "Content-Range") ?? "")
        } else { range = nil }
        var prefix = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            prefix.append(byte)
            if http.statusCode == 200 && prefix.count == 1024 { break }
            guard prefix.count <= 1024 else { throw Failure.wrongRange }
        }
        if let range { try range.validate(offset: 0, requestedEnd: 1023, previousTotal: nil, received: Int64(prefix.count)) }
        try validateMP4Prefix(prefix)
        return http.statusCode
    }

    /// expectedBytes is an API hint. The first HTTP response supplies the actual
    /// total, so missing/stale metadata never forces the broken full-file path.
    static func fetch(
        url: URL, expectedBytes: Int64, userAgent: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("mixtape-audio-\(UUID().uuidString).m4a")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer: FileHandle
        do { writer = try FileHandle(forWritingTo: output) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            var total: Int64?
            var offset: Int64 = 0
            repeat {
                try Task.checkCancellation()
                // HTTP Content-Range, rather than an API length hint, determines EOF.
                let requestedEnd = min(offset + chunkSize - 1, (total ?? maximumFileSize) - 1)
                let request = request(url: url, userAgent: userAgent, start: offset, end: requestedEnd)
                let (temporary, response) = try await downloadRange(request, session: session)
                do {
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                    guard http.statusCode == 206 || (http.statusCode == 200 && offset == 0)
                    else { throw Failure.unexpectedHTTP(http.statusCode) }
                    let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    guard size > 0, size <= maximumFileSize else { throw Failure.invalidSize }
                    try validateMediaType(http)
                    if http.statusCode == 206 {
                        let range = try ByteRange(http.value(forHTTPHeaderField: "Content-Range") ?? "")
                        try range.validate(offset: offset, requestedEnd: requestedEnd, previousTotal: total, received: size)
                        total = range.total
                    } else {
                        if http.expectedContentLength > 0, http.expectedContentLength != size {
                            throw Failure.wrongLength(Int(size), Int(http.expectedContentLength))
                        }
                        total = size
                    }
                    let reader = try FileHandle(forReadingFrom: temporary)
                    defer { try? reader.close() }
                    if offset == 0 {
                        try validateMP4Prefix(try reader.read(upToCount: 16) ?? Data())
                        try reader.seek(toOffset: 0)
                    }
                    while let buffer = try reader.read(upToCount: 64 * 1024), !buffer.isEmpty {
                        try Task.checkCancellation()
                        try writer.write(contentsOf: buffer)
                    }
                    offset += size
                    await progress(Double(offset) / Double(total ?? offset))
                }
            } while offset < (total ?? maximumFileSize)
            try Task.checkCancellation()
            try writer.close()
            return output
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func downloadRange(_ request: URLRequest, session: URLSession) async throws -> (URL, URLResponse) {
        for attempt in 0...1 {
            let limiter = AudioDownloadLimitDelegate(limit: maximumFileSize)
            do {
                let result = try await session.download(for: request, delegate: limiter)
                if let http = result.1 as? HTTPURLResponse, http.statusCode == 429 || http.statusCode >= 500 {
                    try? FileManager.default.removeItem(at: result.0)
                    throw Failure.unexpectedHTTP(http.statusCode)
                }
                return result
            } catch {
                try Task.checkCancellation()
                if limiter.exceeded { throw Failure.invalidSize }
                let transient: Bool
                if case Failure.unexpectedHTTP(let code) = error { transient = code == 429 || code >= 500 }
                else if let network = error as? URLError {
                    transient = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(network.code)
                } else { transient = false }
                guard attempt == 0, transient else { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw Failure.invalidResponse
    }
}

/// A per-task delegate bounds disk use if the server ignores the Range header.
nonisolated private final class AudioDownloadLimitDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let lock = NSLock()
    private var didExceed = false
    var exceeded: Bool { lock.withLock { didExceed } }
    init(limit: Int64) { self.limit = limit }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.withLock { didExceed = true }
            downloadTask.cancel()
        }
    }
}
