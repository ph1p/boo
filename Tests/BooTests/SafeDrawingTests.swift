import Cocoa
import XCTest

@testable import Boo

/// NSString.safeDraw / safeSize must turn an Objective-C exception from AppKit into a
/// skipped draw instead of terminating the process.
@MainActor
final class SafeDrawingTests: XCTestCase {

    /// A non-NSFont `.font` value makes AppKit send font selectors to an NSString,
    /// which raises NSInvalidArgumentException (unrecognized selector).
    private let throwingAttrs: [NSAttributedString.Key: Any] = [.font: "not a font"]

    private func withBitmapContext(_ body: () -> Void) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    func testSafeDrawSurvivesAppKitException() {
        withBitmapContext {
            ("main" as NSString).safeDraw(at: .zero, withAttributes: throwingAttrs)
        }
    }

    func testSafeSizeReturnsZeroOnAppKitException() {
        XCTAssertEqual(("main" as NSString).safeSize(withAttributes: throwingAttrs), .zero)
    }

    func testSafeHelpersMatchAppKitForValidAttributes() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let str = "feature/⎇-branch" as NSString
        XCTAssertEqual(str.safeSize(withAttributes: attrs), str.size(withAttributes: attrs))
        withBitmapContext { str.safeDraw(at: .zero, withAttributes: attrs) }
    }
}
