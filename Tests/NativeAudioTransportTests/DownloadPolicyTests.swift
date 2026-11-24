import Foundation
import XCTest
@testable import NativeAudioTransport

final class DownloadPolicyTests: XCTestCase {
    func testServerClippedRangeAdvancesByActualBodyLength() throws {
        let range = try MixtapeHTTPAudioTransfer.ByteRange("bytes 0-999/600000")
        try range.validate(offset: 0, requestedEnd: 524287, previousTotal: nil, received: 1000)
        XCTAssertEqual(range.count, 1000)
        XCTAssertEqual(range.total, 600000)
    }

    func testRejectsRangeGapsTruncationAndChangingTotal() throws {
        let range = try MixtapeHTTPAudioTransfer.ByteRange("bytes 1000-1999/600000")
        XCTAssertThrowsError(try range.validate(offset: 0, requestedEnd: 2000, previousTotal: nil, received: 1000))
        XCTAssertThrowsError(try range.validate(offset: 1000, requestedEnd: 2000, previousTotal: nil, received: 999))
        XCTAssertThrowsError(try range.validate(offset: 1000, requestedEnd: 2000, previousTotal: 599999, received: 1000))
        XCTAssertThrowsError(try range.validate(offset: 1000, requestedEnd: 1998, previousTotal: nil, received: 1000))
    }

    func testRejectsUnknownNegativeOrExcessiveTotals() {
        for header in ["bytes 0-0/*", "bytes -1-1/10", "bytes 1-0/10", "bytes 0-10/10", "bytes 0-1/200000001", "items 0-1/10", "bytes 0-1/0"] {
            XCTAssertThrowsError(try MixtapeHTTPAudioTransfer.ByteRange(header), header)
        }
    }

    func testAFileSmallerThanProbeRangeIsValid() throws {
        let range = try MixtapeHTTPAudioTransfer.ByteRange("bytes 0-127/128")
        try range.validate(offset: 0, requestedEnd: 1023, previousTotal: nil, received: 128)
        XCTAssertEqual(range.count, 128)
    }

    func testMP4HeaderIsRequiredBeforeSaving() throws {
        let prefix = Data([0, 0, 0, 24]) + Data("ftypM4A ".utf8)
        XCTAssertNoThrow(try MixtapeHTTPAudioTransfer.validateMP4Prefix(prefix))
        XCTAssertThrowsError(try MixtapeHTTPAudioTransfer.validateMP4Prefix(Data("<html>error</html>".utf8)))
        XCTAssertThrowsError(try MixtapeHTTPAudioTransfer.validateMP4Prefix(Data()))
    }

    func testDownloadRequestKeepsProfileIdentityAndDoesNotSendCookies() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/audio?signature=unchanged"))
        let request = MixtapeHTTPAudioTransfer.request(url: url, userAgent: "test-profile", start: 20, end: 40)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=20-40")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "test-profile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testNativeQualityPolicyHonorsEconomicalBeforeStandardItag() throws {
        let response = try response(formats: [
            ["itag": 140, "bitrate": 128000, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\""],
            ["itag": 141, "bitrate": 256000, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\""],
            ["itag": 999, "bitrate": 64000, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\""],
            ["itag": 251, "bitrate": 320000, "mimeType": "audio/webm; codecs=\"opus\""],
        ])
        XCTAssertEqual(response.preferredNativeAudioFormat(quality: "economical")?.itag, 999)
        XCTAssertEqual(response.preferredNativeAudioFormat(quality: "balanced")?.itag, 140)
        XCTAssertEqual(response.preferredNativeAudioFormat(quality: "maximum")?.itag, 141)
    }

    func testNativePolicyRetainsValidHEAACIfNoLCFormatExists() throws {
        let response = try response(formats: [["itag": 139, "bitrate": 48000, "mimeType": "audio/mp4; codecs=\"mp4a.40.5\""]])
        XCTAssertEqual(response.preferredNativeAudioFormat(quality: "balanced")?.itag, 139)
    }

    func testNativePolicyRejectsCipherOnlyVideoAndDubbedFormats() throws {
        let response = try response(formats: [
            ["itag": 140, "bitrate": 128000, "mimeType": "audio/mp4", "audioTrack": ["audioIsDefault": false]],
            ["itag": 141, "bitrate": 256000, "mimeType": "audio/mp4", "url": NSNull()],
            ["itag": 18, "bitrate": 128000, "mimeType": "video/mp4", "width": 640, "height": 360],
        ])
        XCTAssertNil(response.preferredNativeAudioFormat(quality: "maximum"))
    }

    private func response(formats: [[String: Any]]) throws -> PlayerResponse {
        let data: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["adaptiveFormats": formats.map { format in
                var fields: [String: Any] = ["url": "https://example.com/audio"]
                fields.merge(format) { _, new in new }
                return fields
            }],
        ]
        return try JSONDecoder().decode(PlayerResponse.self, from: JSONSerialization.data(withJSONObject: data))
    }
}
