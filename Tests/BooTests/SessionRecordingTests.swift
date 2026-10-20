import XCTest

@testable import Boo

final class SessionRecordingTests: XCTestCase {
    func testHeaderIsAsciicastV2() throws {
        let w = AsciicastWriter(
            width: 120, height: 40, startDate: Date(timeIntervalSince1970: 1_700_000_000), title: "build",
            env: ["TERM": "xterm-256color"])
        let line = w.header()
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["version"] as? Int, 2)
        XCTAssertEqual(obj["width"] as? Int, 120)
        XCTAssertEqual(obj["height"] as? Int, 40)
        XCTAssertEqual(obj["timestamp"] as? Int, 1_700_000_000)
        XCTAssertEqual(obj["title"] as? String, "build")
    }

    func testEventLinesEscapeControlCharacters() throws {
        let line = AsciicastWriter.outputEvent(time: 1.5, text: "a\"b\\c\n\u{1b}[0m\t")
        XCTAssertTrue(line.hasPrefix("[1.500000, \"o\", "))
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any])
        XCTAssertEqual(arr[2] as? String, "a\"b\\c\n\u{1b}[0m\t")
        XCTAssertTrue(line.contains("\\u001b"))
    }

    func testResizeEvent() {
        XCTAssertEqual(AsciicastWriter.resizeEvent(time: 2, columns: 100, rows: 30), "[2.000000, \"r\", \"100x30\"]\n")
    }

    func testUTF8CarryJoinsSplitSequence() {
        var carry = UTF8Carry()
        let bytes = Array("é€😀".utf8)  // 2 + 3 + 4 bytes
        XCTAssertEqual(carry.decode(Array(bytes[0..<1])), "")
        XCTAssertEqual(carry.decode(Array(bytes[1..<4])), "é")
        XCTAssertEqual(carry.decode(Array(bytes[4..<7])), "€")
        XCTAssertEqual(carry.decode(Array(bytes[7...])), "😀")
        XCTAssertEqual(carry.flush(), "")
    }

    func testUTF8CarryReplacesInvalidBytes() {
        var carry = UTF8Carry()
        XCTAssertEqual(carry.decode([0x61, 0xFF, 0x62]), "a\u{FFFD}b")
        XCTAssertEqual(carry.decode([0xE2, 0x82]), "")
        XCTAssertEqual(carry.flush(), "\u{FFFD}")
    }

    func testRecorderWritesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-rec-\(UUID().uuidString).cast")
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = try SessionRecorder(url: url, columns: 80, rows: 24, title: "t")
        let bytes = Array("hi\r\n".utf8)
        bytes.withUnsafeBufferPointer { rec.append($0.baseAddress!, count: $0.count) }
        rec.resized(columns: 100, rows: 30)
        let done = expectation(description: "finish")
        rec.finish { done.fulfill() }
        wait(for: [done], timeout: 2)

        let pb = try CastPlayback(text: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(pb.width, 80)
        XCTAssertEqual(pb.events.map(\.event), [.output("hi\r\n"), .resize(columns: 100, rows: 30)])
    }

    func testDefaultURLSanitizesTitle() {
        let date = Date(timeIntervalSince1970: 0)
        let url = SessionRecorder.defaultURL(title: "~/dev: vim  a/b", date: date)
        XCTAssertEqual(url.pathExtension, "cast")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-dev-vim-a-b.cast"), url.lastPathComponent)
    }

    // MARK: - Playback

    private let cast = """
        {"version": 2, "width": 90, "height": 20}
        [0.5, "o", "a"]
        [1.0, "i", "x"]
        [1.5, "o", "b"]
        [11.5, "o", "c"]
        [12.0, "r", "100x30"]
        garbage
        [12.25, "o", "d"]
        """

    func testPlaybackCapsIdleAndSkipsInput() throws {
        let pb = try CastPlayback(text: cast)
        XCTAssertEqual(pb.width, 90)
        XCTAssertEqual(pb.height, 20)
        XCTAssertEqual(pb.events.map(\.time), [0.5, 1.5, 3.5, 4.0, 4.25])
        XCTAssertEqual(pb.duration, 4.25)
        XCTAssertEqual(pb.events[3].event, .resize(columns: 100, rows: 30))
    }

    func testPlaybackHonoursHeaderIdleLimit() throws {
        let text = cast.replacingOccurrences(of: "\"height\": 20", with: "\"height\": 20, \"idle_time_limit\": 0.5")
        let pb = try CastPlayback(text: text)
        XCTAssertEqual(pb.events.map(\.time), [0.5, 1.0, 1.5, 2.0, 2.25])
    }

    func testPlaybackReadsMarkersOnCappedTimeline() throws {
        let text = """
            {"version": 2, "width": 80, "height": 24, "timestamp": 1700000000}
            [0.5, "o", "a"]
            [1.0, "m", "intro"]
            [11.0, "m", ""]
            [11.5, "o", "b"]
            """
        let pb = try CastPlayback(text: text)
        XCTAssertEqual(pb.markers, [.init(time: 1.0, label: "intro"), .init(time: 3.0, label: "")])
        XCTAssertEqual(pb.events.map(\.time), [0.5, 3.5])
        XCTAssertEqual(pb.duration, 3.5)
        XCTAssertEqual(pb.startDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(pb.marker(after: 0)?.label, "intro")
        XCTAssertEqual(pb.marker(after: 1.0)?.time, 3.0)
        XCTAssertNil(pb.marker(after: 3.0))
        XCTAssertEqual(pb.marker(before: 3.5)?.time, 1.0)
        XCTAssertNil(pb.marker(before: 1.5))
    }

    func testIdleLimitPrecedenceAndZeroDisablesCap() throws {
        // Explicit beats the header; the fallback applies only without either; 0 means no cap.
        let header = cast.replacingOccurrences(of: "\"height\": 20", with: "\"height\": 20, \"idle_time_limit\": 0.5")
        XCTAssertEqual(try CastPlayback(text: header, idleLimit: 1).events.map(\.time), [0.5, 1.5, 2.5, 3.0, 3.25])
        XCTAssertEqual(try CastPlayback(text: cast, fallbackIdleLimit: 0).duration, 12.25)
        XCTAssertEqual(try CastPlayback(text: header, fallbackIdleLimit: 0).duration, 2.25)
    }

    func testHeaderWritesIdleLimitAndMarkerEvent() throws {
        var w = AsciicastWriter(width: 80, height: 24, startDate: Date(), title: nil, env: [:])
        XCTAssertFalse(w.header().contains("idle_time_limit"))
        w.idleTimeLimit = 1.5
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(w.header().utf8)) as? [String: Any])
        XCTAssertEqual(obj["idle_time_limit"] as? Double, 1.5)
        XCTAssertEqual(AsciicastWriter.markerEvent(time: 2, label: "x"), "[2.000000, \"m\", \"x\"]\n")
    }

    func testDueIndexAndGrid() throws {
        let pb = try CastPlayback(text: cast)
        XCTAssertEqual(pb.dueIndex(at: 0), 0)
        XCTAssertEqual(pb.dueIndex(at: 1.5), 2)
        XCTAssertEqual(pb.dueIndex(at: 100, from: 2), 5)
        XCTAssertEqual(pb.grid(before: 3).columns, 90)
        XCTAssertEqual(pb.grid(before: 4).columns, 100)
        XCTAssertEqual(pb.grid(before: 4).rows, 30)
    }

    func testPlaybackRejectsOtherFormats() {
        XCTAssertThrowsError(try CastPlayback(text: "not json"))
        XCTAssertThrowsError(try CastPlayback(text: "{\"version\": 1}")) { error in
            XCTAssertEqual(error as? CastPlayback.ParseError, .unsupportedVersion(1))
        }
    }

    func testCastFilesOpenInPlayer() {
        XCTAssertEqual(ContentType.forFile("/tmp/x.cast"), .castPlayer)
        XCTAssertEqual(CastPlayback.formatTime(75.9), "1:15")
    }
}
