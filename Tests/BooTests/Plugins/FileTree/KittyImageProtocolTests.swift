import CGhostty
import CoreGraphics
import ImageIO
import XCTest

@testable import Boo

final class KittyImageProtocolTests: XCTestCase {

    // MARK: - sendImage

    func testSendImageReturnsFalseForMissingImage() {
        let result = KittyImageProtocol.sendImage(
            imagePath: "/tmp/does_not_exist_\(UUID().uuidString).png",
            to: getpid()
        )
        XCTAssertFalse(result, "sendImage must return false when image file does not exist")
    }

    func testSendImageReturnsFalseForInvalidPID() {
        let url = writeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        // PID 0 has no controlling TTY
        let result = KittyImageProtocol.sendImage(imagePath: url.path, to: 0)
        XCTAssertFalse(result, "sendImage must return false for a PID with no controlling TTY")
    }

    // MARK: - ttyPath

    func testTTYPathReturnsNilForInvalidPID() {
        XCTAssertNil(KittyImageProtocol.ttyPath(for: 0))
    }

    func testTTYPathReturnsDevTTYForCurrentProcess() {
        // Skipped gracefully when there is no controlling TTY (e.g. headless CI).
        guard let path = KittyImageProtocol.ttyPath(for: getpid()) else { return }
        XCTAssertTrue(path.hasPrefix("/dev/tty"), "tty path must be under /dev/tty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - buildPayload

    func testPayloadContainsKittyAPCHeader() throws {
        let url = writeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let (pixels, w, h) = KittyImageProtocol.loadRGBA(path: url.path) else {
            XCTFail("loadRGBA returned nil")
            return
        }
        let payload = KittyImageProtocol.buildPayload(
            pixels: pixels, width: w, height: h,
            cols: nil, rows: nil)
        // Kitty APC: ESC _ G <control> ; <base64-data> ESC backslash
        XCTAssertTrue(payload.count > 3)
        XCTAssertEqual(payload[0], 0x1B, "must start with ESC")
        XCTAssertEqual(payload[1], 0x5F, "second byte must be '_' (APC)")
        XCTAssertEqual(payload[2], 0x47, "third byte must be 'G'")

        let text = String(data: Data(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("a=T"), "must request transmit+display action")
        XCTAssertTrue(text.contains("f=32"), "must use 32-bit RGBA format")
        XCTAssertTrue(text.contains("s=4"), "must encode image width")
        XCTAssertTrue(text.contains("v=4"), "must encode image height")
    }

    func testPayloadWithCellSizeContainsCellKeys() throws {
        let url = writeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let (pixels, w, h) = KittyImageProtocol.loadRGBA(path: url.path) else {
            XCTFail("loadRGBA returned nil")
            return
        }
        let payload = KittyImageProtocol.buildPayload(
            pixels: pixels, width: w, height: h,
            cols: 40, rows: 20)
        let text = String(data: Data(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("c=40"), "payload must contain column count")
        XCTAssertTrue(text.contains("r=20"), "payload must contain row count")
    }

    // MARK: - fitCells

    func testFitCellsReturnsNilForNilTerminalSize() {
        let (cols, rows) = KittyImageProtocol.fitCells(
            imageWidth: 100, imageHeight: 100,
            terminalSize: nil)
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testFitCellsReturnsNilForZeroCellDimensions() {
        var size = ghostty_surface_size_s()
        size.columns = 80
        size.rows = 24
        size.cell_width_px = 0
        size.cell_height_px = 0
        let (cols, rows) = KittyImageProtocol.fitCells(
            imageWidth: 100, imageHeight: 100,
            terminalSize: size)
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testFitCellsFillsHeightAndPreservesAspectRatio() {
        var size = ghostty_surface_size_s()
        size.columns = 200
        size.rows = 40
        size.cell_width_px = 8
        size.cell_height_px = 16
        // Square image → cols should equal rows * cellH / cellW = 40 * 16/8 = 80
        let (cols, rows) = KittyImageProtocol.fitCells(
            imageWidth: 100, imageHeight: 100,
            terminalSize: size)
        XCTAssertEqual(rows, 40)
        XCTAssertEqual(cols, 80)
    }

    func testFitCellsClampsToMaxColumns() {
        var size = ghostty_surface_size_s()
        size.columns = 20
        size.rows = 40
        size.cell_width_px = 8
        size.cell_height_px = 16
        // Wide image would need more than 20 cols — should clamp to 90% of columns
        let (cols, rows) = KittyImageProtocol.fitCells(
            imageWidth: 1000, imageHeight: 100,
            terminalSize: size)
        XCTAssertEqual(cols, 18)  // max(1, Int(20 * 0.9))
        XCTAssertNotNil(rows)
        XCTAssertLessThanOrEqual(rows!, 40)
    }

    // MARK: - PluginActions wiring

    @MainActor
    func testDisplayImageInTerminalNilHandlerIsNoOp() {
        let actions = PluginActions()
        actions.displayImageInTerminal?("/some/image.png", true)  // must not crash
        actions.displayImageInTerminal?("/some/image.png", false)  // must not crash
    }

    @MainActor
    func testDisplayImageInTerminalCallsHandlerWithNewTab() {
        let actions = PluginActions()
        var receivedPath: String?
        var receivedNewTab: Bool?
        actions.displayImageInTerminal = { path, newTab in
            receivedPath = path
            receivedNewTab = newTab
        }
        actions.displayImageInTerminal?("/tmp/test.png", true)
        XCTAssertEqual(receivedPath, "/tmp/test.png")
        XCTAssertEqual(receivedNewTab, true)
    }

    @MainActor
    func testDisplayImageInTerminalCallsHandlerWithoutNewTab() {
        let actions = PluginActions()
        var receivedPath: String?
        var receivedNewTab: Bool?
        actions.displayImageInTerminal = { path, newTab in
            receivedPath = path
            receivedNewTab = newTab
        }
        actions.displayImageInTerminal?("/tmp/test.png", false)
        XCTAssertEqual(receivedPath, "/tmp/test.png")
        XCTAssertEqual(receivedNewTab, false)
    }

    // MARK: - Helpers

    /// Creates a 4×4 red PNG via CoreGraphics and writes it to a temp file.
    private func writeTinyPNG() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitty_test_\(UUID().uuidString).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 255
            pixels[i + 3] = 255  // red, fully opaque
        }
        guard
            let ctx = CGContext(
                data: &pixels, width: 4, height: 4,
                bitsPerComponent: 8, bytesPerRow: 16,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = ctx.makeImage()
        else { return url }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
}
