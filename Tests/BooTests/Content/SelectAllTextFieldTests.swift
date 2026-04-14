import Cocoa
import XCTest

@testable import Boo

/// Tests for SelectAllTextField focus callbacks and URLBarPillView focus state.
///
/// Focus-loss detection uses NSApplication.didUpdateNotification which requires
/// a live AppKit event pump — untestable in headless XCTest. Those paths are
/// covered by integration / manual testing. What we verify here:
///   - gain-callback wiring and ordering
///   - isFieldActive transitions on becomeFirstResponder
///   - nil-safety
///   - pill state toggling
final class SelectAllTextFieldTests: XCTestCase {

    // MARK: - becomeFirstResponder

    func testGainCallbackFiresOnFocus() {
        let (field, window) = makeFieldInWindow()
        var gainCount = 0
        field.onFocusGained = { gainCount += 1 }
        window.makeFirstResponder(field)
        XCTAssertEqual(gainCount, 1)
    }

    func testGainCallbackNotCalledWhenBecomeFirstResponderFails() {
        // Field not in a window — becomeFirstResponder returns false.
        let field = SelectAllTextField()
        var gainCount = 0
        field.onFocusGained = { gainCount += 1 }
        _ = field.becomeFirstResponder()
        XCTAssertEqual(gainCount, 0)
    }

    func testGainCallbackFiresSynchronously() {
        // onFocusGained must fire synchronously inside becomeFirstResponder,
        // before the async selectAll dispatch.
        let (field, window) = makeFieldInWindow()
        var gainFired = false
        field.onFocusGained = { gainFired = true }
        window.makeFirstResponder(field)
        XCTAssertTrue(gainFired)
    }

    func testIsFieldActiveSetAfterFocus() {
        let (field, window) = makeFieldInWindow()
        window.makeFirstResponder(field)
        XCTAssertTrue(field.isFieldActive)
    }

    func testIsFieldActiveRemainsAfterFieldEditorTakesFocus() {
        // AppKit installs the shared NSTextView field editor as firstResponder
        // immediately after becomeFirstResponder. isFieldActive must stay true —
        // the field editor is not a focus loss.
        let (field, window) = makeFieldInWindow()
        window.makeFirstResponder(field)
        // Spin one run-loop tick so any async dispatches (incl. the didUpdateNotification
        // observer installed inside becomeFirstResponder) can fire.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(
            field.isFieldActive,
            "isFieldActive must stay true while the field editor owns focus")
    }

    func testNilCallbacksDoNotCrash() {
        let (field, window) = makeFieldInWindow()
        field.onFocusGained = nil
        field.onFocusLost = nil
        window.makeFirstResponder(field)
    }

    func testJustBecameFirstResponderSetOnFocus() {
        let (field, window) = makeFieldInWindow()
        window.makeFirstResponder(field)
        XCTAssertTrue(
            field.justBecameFirstResponder,
            "justBecameFirstResponder must be true immediately after becomeFirstResponder")
    }

    func testJustBecameFirstResponderClearedByAsyncSelectAll() {
        let (field, window) = makeFieldInWindow()
        window.makeFirstResponder(field)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(
            field.justBecameFirstResponder,
            "async block clears justBecameFirstResponder when no mouseDown consumed it (Tab path)")
    }

    func testMultipleFocusCyclesDontLeakObserver() {
        // Each becomeFirstResponder removes the previous observer before installing a new one.
        // If observers leaked, onFocusGained would be called multiple times per focus.
        let (field, window) = makeFieldInWindow()
        let (other, _) = makeSecondFieldIn(window)
        var gainCount = 0
        field.onFocusGained = { gainCount += 1 }

        window.makeFirstResponder(field)  // cycle 1
        window.makeFirstResponder(other)
        window.makeFirstResponder(field)  // cycle 2
        window.makeFirstResponder(other)
        window.makeFirstResponder(field)  // cycle 3

        XCTAssertEqual(gainCount, 3, "Each focus cycle must fire onFocusGained exactly once")
    }

    // MARK: - URLBarPillView

    func testPillIsFocusedDefaultsFalse() {
        XCTAssertFalse(URLBarPillView().isFocused)
    }

    func testPillIsFocusedOnFocusGained() {
        let (field, window) = makeFieldInWindow()
        let pill = URLBarPillView()
        field.onFocusGained = { [weak pill] in pill?.isFocused = true }
        field.onFocusLost = { [weak pill] in pill?.isFocused = false }

        window.makeFirstResponder(field)
        XCTAssertTrue(pill.isFocused)
    }

    func testPillThemeAssignment() {
        let pill = URLBarPillView()
        XCTAssertNil(pill.theme)
        pill.theme = TerminalTheme.themes.first!
        XCTAssertNotNil(pill.theme)
    }

    // MARK: - Helpers

    private func makeFieldInWindow() -> (SelectAllTextField, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let field = SelectAllTextField()
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        window.contentView?.addSubview(field)
        return (field, window)
    }

    private func makeSecondFieldIn(_ window: NSWindow) -> (NSTextField, NSWindow) {
        let other = NSTextField()
        other.frame = NSRect(x: 210, y: 0, width: 150, height: 24)
        window.contentView?.addSubview(other)
        return (other, window)
    }
}
