import Foundation
import Testing
@testable import NativeAudioTransport

/// The fixture emits synthetic MP4-looking bytes, not a decodable audio signal.
/// These tests verify actual loopback HTTP behavior independently of YouTube.
@Suite(.serialized)
struct NativeRangeIntegrationTests {
    private static let userAgent = "MixtapeTransportTests/1.0"
    private static let headers = [
        "User-Agent": userAgent,
        "Origin": "https://www.youtube.com",
        "Referer": "https://www.youtube.com/",
    ]

    @Test func nativeRangePreservesHTTPIdentityAndByteOffsets() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        let first = try await HTTPAudioRangeClient.fetch(
            url: fixture.url("identity"), headers: Self.headers, offset: 0, length: 1024
        )
        #expect(first.contentLength == Int64(AudioHTTPFixture.expected.count))
        #expect(first.data == AudioHTTPFixture.expected.prefix(1024))
        let seek = try await HTTPAudioRangeClient.fetch(
            url: fixture.url("range"), headers: Self.headers, offset: 1024, length: 512
        )
        #expect(seek.data == AudioHTTPFixture.expected.subdata(in: 1024..<1536))
    }

    @Test func nativeRangeAcceptsShortCompleteFileAndEOFRange() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        let full = try await HTTPAudioRangeClient.fetch(
            url: fixture.url("short-whole"), headers: Self.headers, offset: 0, length: 1024
        )
        #expect(full.contentLength == 256)
        #expect(full.data == AudioHTTPFixture.expected.prefix(256))
        let count = AudioHTTPFixture.expected.count
        let tail = try await HTTPAudioRangeClient.fetch(
            url: fixture.url("range"), headers: Self.headers, offset: Int64(count - 17), length: 1024
        )
        #expect(tail.data == AudioHTTPFixture.expected.suffix(17))
    }

    @Test func nativeRangeFollowsRedirectWithHTTPIdentity() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        let result = try await HTTPAudioRangeClient.fetch(
            url: fixture.url("redirect"), headers: Self.headers, offset: 0, length: 1024
        )
        #expect(result.data == AudioHTTPFixture.expected.prefix(1024))
    }

    @Test func nativeRangeRejectsIgnoredRangeHTMLMalformedTruncatedAndOverlongBodies() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        for path in ["whole", "html", "bad-range", "truncated", "overlong"] {
            do {
                _ = try await HTTPAudioRangeClient.fetch(
                    url: fixture.url(path), headers: Self.headers, offset: 0, length: 1024
                )
                Issue.record("Expected range client failure for /\(path)")
            } catch {
                // Both validated response failures and URLSession short-body
                // transport failures are expected for these fixture endpoints.
                #expect(error is HTTPAudioRangeError || error is URLError)
            }
        }
    }

    @Test func nativeRangeReportsZeroBodyHTTP403() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        do {
            _ = try await HTTPAudioRangeClient.fetch(
                url: fixture.url("forbidden"), headers: Self.headers, offset: 0, length: 1024
            )
            Issue.record("Expected HTTP 403")
        } catch HTTPAudioRangeError.httpStatus(let status) {
            #expect(status == 403)
        }
    }

    @Test func nativeRangeCancellationPropagates() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        let operation = Task {
            try await HTTPAudioRangeClient.fetch(
                url: fixture.url("slow"), headers: Self.headers, offset: 0, length: 1024
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected native range cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func offlineTransferUsesHTTPSizeWhenAPIHintIsMissingOrStale() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        for hint in [Int64(0), 1, Int64(AudioHTTPFixture.expected.count + 5000)] {
            let file = try await MixtapeHTTPAudioTransfer.fetch(
                url: fixture.url("identity"), expectedBytes: hint, userAgent: Self.userAgent, progress: { _ in }
            )
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(try Data(contentsOf: file) == AudioHTTPFixture.expected)
        }
    }

    @Test func offlineTransferAcceptsIgnoredRangeAndClippedContiguousResponses() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        for path in ["whole", "clipped"] {
            let file = try await MixtapeHTTPAudioTransfer.fetch(
                url: fixture.url(path), expectedBytes: 0, userAgent: Self.userAgent, progress: { _ in }
            )
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(try Data(contentsOf: file) == AudioHTTPFixture.expected)
        }
    }

    @Test func offlineTransferRetriesTransientHTTPFailure() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        let file = try await MixtapeHTTPAudioTransfer.fetch(
            url: fixture.url("transient"), expectedBytes: 0, userAgent: Self.userAgent, progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == AudioHTTPFixture.expected)
    }

    @Test func offlineTransferReportsZeroBodyHTTP403() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        do {
            _ = try await MixtapeHTTPAudioTransfer.fetch(
                url: fixture.url("forbidden"), expectedBytes: 0, userAgent: Self.userAgent, progress: { _ in }
            )
            Issue.record("Expected HTTP 403")
        } catch MixtapeHTTPAudioTransfer.Failure.unexpectedHTTP(let status) {
            #expect(status == 403)
        }
    }

    @Test func offlineTransferRejectsCorruptResponsesAndRemovesPartialFiles() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        for path in ["html", "bad-range", "truncated", "overlong", "changed-total"] {
            let before = try Self.temporaryAudioNames()
            do {
                _ = try await MixtapeHTTPAudioTransfer.fetch(
                    url: fixture.url(path), expectedBytes: 0, userAgent: Self.userAgent, progress: { _ in }
                )
                Issue.record("Expected offline transfer failure for /\(path)")
            } catch {
                #expect(error is MixtapeHTTPAudioTransfer.Failure || error is URLError)
            }
            #expect(try Self.temporaryAudioNames() == before)
        }
    }

    @Test func offlineTransferCancellationRemovesPartialFile() async throws {
        let fixture = try AudioHTTPFixture()
        defer { fixture.stop() }
        let before = try Self.temporaryAudioNames()
        let operation = Task {
            try await MixtapeHTTPAudioTransfer.fetch(
                url: fixture.url("slow"), expectedBytes: 0, userAgent: Self.userAgent, progress: { _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected offline transfer cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(try Self.temporaryAudioNames() == before)
    }

    private static func temporaryAudioNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("mixtape-audio-") })
    }
}

private final class AudioHTTPFixture: @unchecked Sendable {
    let process: Process
    let baseURL: URL

    static let expected: Data = {
        var data = Data([0, 0, 0, 24])
        data.append(Data("ftypM4A ".utf8))
        data.append(Data([0, 0, 0, 0]))
        data.append(Data("M4A isom".utf8))
        let pattern = Data((0...255).map(UInt8.init))
        for _ in 0..<4096 { data.append(pattern) }
        return data
    }()

    init() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/http_audio_server.py")
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--port", "0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.availableData
        do {
            let info = try JSONDecoder().decode(Ready.self, from: data)
            guard let url = URL(string: "http://127.0.0.1:\(info.port)") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.process = process
            self.baseURL = url
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    private struct Ready: Decodable { let port: Int }

    func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
