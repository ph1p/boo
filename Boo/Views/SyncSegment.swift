import AppKit

/// "⚠ Sync conflict" while files changed both here and in the sync folder.
/// Click for keep mine / take theirs / show diff per file.
final class SyncSegment: StatusBarPlugin {
    let id = "sync"
    let position: StatusBarPosition = .right
    let priority = 53
    var hitRect: NSRect = .zero
    /// Retained while the menu is open (menu items hold their target weakly).
    private var menuTarget: SyncMenuTarget?

    var tooltipText: String? { "Changed here and in the sync folder — click to resolve" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        MainActor.assumeIsolated { !SyncService.shared.conflicts.isEmpty }
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let count = MainActor.assumeIsolated { SyncService.shared.conflicts.count }
        let label = count == 1 ? "⚠ Sync conflict" : "⚠ \(count) sync conflicts"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemOrange
        ]
        hitRect = Self.drawLabel(label, attrs: attrs, endingAt: rx, y: y)
        return hitRect.width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        MainActor.assumeIsolated {
            let target = menuTarget ?? SyncMenuTarget()
            menuTarget = target
            target.makeMenu().popUp(positioning: nil, at: NSPoint(x: hitRect.minX, y: 0), in: barView)
        }
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        MainActor.assumeIsolated { "\(SyncService.shared.conflicts.count) sync conflicts" }
    }
}

@MainActor
final class SyncMenuTarget: NSObject {
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for name in SyncService.shared.conflicts {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(entry("Keep Mine", #selector(keepMine(_:)), name))
            submenu.addItem(entry("Take Theirs", #selector(takeTheirs(_:)), name))
            submenu.addItem(.separator())
            submenu.addItem(entry("Show Diff", #selector(showDiff(_:)), name))
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private func entry(_ title: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    @objc func keepMine(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SyncService.shared.resolve(name, keepLocal: true)
    }

    @objc func takeTheirs(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SyncService.shared.resolve(name, keepLocal: false)
    }

    @objc func showDiff(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SyncService.shared.openDiff(name)
    }
}
