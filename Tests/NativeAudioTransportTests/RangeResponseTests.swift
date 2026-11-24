import Foundation
import XCTest
@testable import NativeAudioTransport

final class RangeResponseTests: XCTestCase {
    private func response(_ fields: [String: String]) -> HTTPURLResponse {
        response(206, fields)
    }

    private func response(_ status: Int, _ fields: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://media.example/audio")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: fields)!
    }

    func testMiddleRangeUsesExactAbsoluteOffsets() throws {
        let value = try HTTPAudioRangeResponse(
            response: response(["Content-Range": "bytes 262144-524287/900000", "Content-Type": "audio/mp4"]),
            offset: 262144, length: 262144
        )
        XCTAssertEqual(value.contentLength, 900000)
        XCTAssertEqual(value.bodyLength, 262144)
    }

    func testFinalAndServerLimitedRangesAdvanceByReturnedBytes() throws {
        let last = try HTTPAudioRangeResponse(
            response: response(["Content-Range": "bytes 900-999/1000"]), offset: 900, length: 256
        )
        XCTAssertEqual(last.bodyLength, 100)
        XCTAssertEqual(try HTTPAudioRangeResponse(
            response: response(["Content-Range": "bytes 900-950/1000"]), offset: 900, length: 256
        ).bodyLength, 51)
    }

    func testWrongOffsetAndInvalidTotalsAreRejected() {
        for field in ["bytes 0-99/1000", "bytes 100-199/*", "bytes 100-199/150", "bytes 100-99/1000", "invalid", "bytes -1-9/100"] {
            XCTAssertThrowsError(try HTTPAudioRangeResponse(response: response(["Content-Range": field]), offset: 100, length: 100), field)
        }
    }

    func testIgnoredRangeOnlyAcceptsSmallCompleteFileAtBeginning() throws {
        let full = response(200, ["Content-Length": "100", "Content-Type": "audio/mp4"])
        XCTAssertEqual(try HTTPAudioRangeResponse(response: full, offset: 0, length: 256).bodyLength, 100)
        XCTAssertThrowsError(try HTTPAudioRangeResponse(response: full, offset: 50, length: 256))
        XCTAssertThrowsError(try HTTPAudioRangeResponse(
            response: response(200, ["Content-Length": "10000000"]), offset: 0, length: 256
        ))
    }

    func testErrorAndHTMLResponsesAreRejected() {
        XCTAssertThrowsError(try HTTPAudioRangeResponse(response: response(403, [:]), offset: 0, length: 2))
        XCTAssertThrowsError(try HTTPAudioRangeResponse(
            response: response(["Content-Range": "bytes 0-1/100", "Content-Type": "text/html"]), offset: 0, length: 2
        ))
    }

    func testOffsetsCannotOverflow() {
        XCTAssertThrowsError(try HTTPAudioRangeResponse(response: response([:]), offset: Int64.max, length: 2))
        XCTAssertThrowsError(try HTTPAudioRangeResponse(response: response([:]), offset: -1, length: 2))
    }

    func testRangeAtEOFCanFinishWithoutDownloadingErrorBody() throws {
        let eof = try HTTPAudioRangeResponse(
            response: response(416, ["Content-Range": "bytes */1000", "Content-Type": "text/html"]),
            offset: 1000, length: 2
        )
        XCTAssertEqual(eof.contentLength, 1000)
        XCTAssertEqual(eof.bodyLength, 0)
    }
}
