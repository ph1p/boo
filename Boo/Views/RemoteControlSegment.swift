import Cocoa

/// Shows while the remote control server listens, so a session left running
/// is visible. Click for Copy URL / Stop.
final class RemoteControlSegment: StatusBarPlugin {
    let id = "remote-control"
    let position: StatusBarPosition = .right
    let priority = 52
    var hitRect: NSRect = .zero

    var tooltipText: String? { "Remote Control is reachable on your network — click to copy the URL or stop it" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        RemoteControlServer.shared.isRunning
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemOrange
        ]
        hitRect = Self.drawLabel("◉ Remote", attrs: attrs, endingAt: rx, y: y)
        return hitRect.width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        // nil targets: the responder chain reaches the window's MainWindowController.
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Copy Remote Control URL",
            action: #selector(MainWindowController.copyRemoteControlURLAction(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Stop Remote Control Server",
            action: #selector(MainWindowController.toggleRemoteControlAction(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: hitRect.minX, y: 0), in: barView)
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? { "Remote Control server running" }
}
