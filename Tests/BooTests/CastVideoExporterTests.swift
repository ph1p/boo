import AVFoundation
import XCTest

@testable import Boo

final class CastVideoExporterTests: XCTestCase {
    func testGeometryUsesPreferredScaleAndEvenSize() {
        let g = CastVideoExporter.Geometry.make(columns: 80, rows: 24, cell: CGSize(width: 8, height: 17))
        XCTAssertEqual(g.scale, 2)
        XCTAssertEqual(g.cell, CGSize(width: 16, height: 34))
        XCTAssertEqual(g.padding, 24)
        XCTAssertEqual(g.size, CGSize(width: 80 * 16 + 48, height: 24 * 34 + 48))
    }

    func testGeometryShrinksToFitMaxSize() {
        let g = CastVideoExporter.Geometry.make(columns: 400, rows: 120, cell: CGSize(width: 8, height: 17))
        XCTAssertLessThan(g.scale, 2)
        XCTAssertLessThanOrEqual(g.size.width, CastVideoExporter.maxSize.width)
        XCTAssertLessThanOrEqual(g.size.height, CastVideoExporter.maxSize.height)
        XCTAssertEqual(Int(g.size.width) % 2, 0)
        XCTAssertEqual(Int(g.size.height) % 2, 0)
    }

    func testMaxGridCoversResizes() throws {
        let cast = """
            {"version": 2, "width": 80, "height": 24}
            [0.1, "o", "hi"]
            [0.2, "r", "120x20"]
            [0.3, "r", "100x50"]
            """
        let pb = try CastPlayback(text: cast)
        let grid = CastVideoExporter.maxGrid(pb)
        XCTAssertEqual(grid.columns, 120)
        XCTAssertEqual(grid.rows, 50)
    }

    func testFrameCountIncludesTail() {
        XCTAssertEqual(CastVideoExporter.frameCount(duration: 0), Int(CastVideoExporter.fps) + 1)
        XCTAssertEqual(CastVideoExporter.frameCount(duration: 2), 3 * Int(CastVideoExporter.fps) + 1)
    }

    func testDefaultFileName() {
        XCTAssertEqual(CastVideoExporter.defaultFileName(for: "/a/b/build 1.cast"), "build 1.mp4")
    }

    func testExportWritesPlayableVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cast = dir.appendingPathComponent("demo.cast")
        let out = dir.appendingPathComponent("demo.mp4")
        // Red background over the whole screen, some styled text, a resize.
        try """
        {"version": 2, "width": 20, "height": 5}
        [0.0, "o", "\\u001b[41m\\u001b[2J\\u001b[H\\u001b[1;4mhello\\u001b[0;41m wörld 🎉"]
        [0.5, "r", "30x6"]
        [1.0, "o", "\\r\\n$ "]
        """.write(to: cast, atomically: true, encoding: .utf8)

        let white = TerminalColor(r: 255, g: 255, b: 255)
        let black = TerminalColor(r: 0, g: 0, b: 0)
        var ansi = Array(repeating: white, count: 16)
        ansi[1] = TerminalColor(r: 255, g: 0, b: 0)
        let style = CastVideoExporter.Style(
            foreground: white, background: black, cursor: white, ansi: ansi, fontName: "Menlo", fontSize: 13,
            cursorStyle: .block)
        let progress = ProgressBox()
        try await CastVideoExporter.export(cast: cast, to: out, style: style, idleLimit: 0) { progress.set($0) }
        XCTAssertEqual(progress.value, 1)

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertEqual(Int(size.width) % 2, 0)

        // A cell in the middle of the first grid is red background.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 1, timescale: 10)).image
        let pixel = try XCTUnwrap(Self.pixel(image, x: image.width / 3, y: image.height / 2))
        XCTAssertGreaterThan(pixel.r, 200)
        XCTAssertLessThan(pixel.g, 60)
        XCTAssertLessThan(pixel.b, 60)
    }

    func testExportCancels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cast = dir.appendingPathComponent("long.cast")
        let out = dir.appendingPathComponent("long.mp4")
        var lines = [#"{"version": 2, "width": 80, "height": 24}"#]
        for i in 0..<600 { lines.append("[\(Double(i) * 0.5), \"o\", \"line \(i)\\r\\n\"]") }
        try lines.joined(separator: "\n").write(to: cast, atomically: true, encoding: .utf8)
        let c = TerminalColor(r: 128, g: 128, b: 128)
        let style = CastVideoExporter.Style(
            foreground: c, background: c, cursor: c, ansi: Array(repeating: c, count: 16), fontName: "Menlo",
            fontSize: 13, cursorStyle: .beam)

        let task = Task.detached {
            try await CastVideoExporter.export(cast: cast, to: out, style: style, idleLimit: 0) { _ in }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var data = [UInt8](repeating: 0, count: 4)
        guard
            let ctx = CGContext(
                data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double = 0
    var value: Double { lock.withLock { _value } }
    func set(_ v: Double) { lock.withLock { _value = v } }
}
