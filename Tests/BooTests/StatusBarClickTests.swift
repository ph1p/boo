import XCTest

@testable import Boo

/// Tests that hidden status bar plugin segments don't intercept clicks
/// meant for visible segments that shifted into their former positions.
@MainActor
final class StatusBarClickTests: XCTestCase {

    /// A spy StatusBarPlugin that records clicks and can be hidden.
    final class SpyIconSegment: StatusBarPlugin {
        let id: String
        let position: StatusBarPosition = .right
        let priority: Int
        let associatedPanelID: String?
        var isHidden = false
        var hitRect: NSRect = .zero
        var clickCount = 0
        var onToggle: ((String) -> Void)?

        init(id: String, priority: Int, panelID: String) {
            self.id = id
            self.priority = priority
            self.associatedPanelID = panelID
        }

        func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
            !isHidden
        }

        func update(state: StatusBarState) {}

        func draw(
            at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState,
            ctx: CGContext
        ) -> CGFloat {
            let iconSize: CGFloat = 14
            let drawX = rx - iconSize - 2
            hitRect = NSRect(x: drawX - 2, y: 0, width: iconSize + 6, height: 22)
            return iconSize + 6
        }

        @MainActor func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
            guard hitRect.contains(point) else { return false }
            clickCount += 1
            onToggle?(associatedPanelID ?? "")
            return true
        }

        func accessibilitySegmentLabel(state: StatusBarState) -> String? { nil }
    }

    // MARK: - Path segment

    func testPathSegmentDropsControlCharacters() {
        XCTAssertEqual(PathSegment.drawable("~/a\u{1B}[31mb\tc"), "~/a[31mbc")
        XCTAssertEqual(PathSegment.drawable("~/日本/🧑‍💻"), "~/日本/🧑‍💻")
    }
}
