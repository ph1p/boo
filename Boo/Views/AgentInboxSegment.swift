import Cocoa

/// Status bar summary of the agent inbox ("● Claude needs your input",
/// "2 agents"). Click lists every agent across windows; picking one jumps there.
final class AgentInboxSegment: StatusBarPlugin {
    let id = "agent-inbox"
    let position: StatusBarPosition = .right
    let priority = 60
    var hitRect: NSRect = .zero
    /// Retained while the menu is open (menu items hold their target weakly).
    private var menuTarget: AgentInboxMenuTarget?

    var tooltipText: String? { "Agents — click to jump" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        MainActor.assumeIsolated { !AgentInbox.shared.items.isEmpty }
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let (label, color) = MainActor.assumeIsolated { Self.label(theme: theme) }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]
        let str = label as NSString
        let size = str.safeSize(withAttributes: attrs)
        let dot: CGFloat = 6
        let width = dot + 4 + size.width
        let x = rx - width - 4
        let barH = DensityMetrics.current.statusBarHeight
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: x, y: (barH - dot) / 2, width: dot, height: dot))
        str.safeDraw(at: NSPoint(x: x + dot + 4, y: y), withAttributes: attrs)
        hitRect = NSRect(x: x - 4, y: 0, width: width + 8, height: barH)
        return width + 8
    }

    @MainActor private static func label(theme: TerminalTheme) -> (String, NSColor) {
        let inbox = AgentInbox.shared
        let waiting = inbox.sortedItems.filter(\.needsAttention)
        if waiting.count == 1, let item = waiting.first {
            return (AgentInbox.summary(of: item, short: true), color(for: item, theme: theme))
        }
        if let first = waiting.first {
            return ("\(waiting.count) agents waiting", color(for: first, theme: theme))
        }
        let count = inbox.items.count
        return (count == 1 ? "1 agent" : "\(count) agents", theme.textTertiary)
    }

    @MainActor static func color(for item: AgentInbox.Item, theme: TerminalTheme) -> NSColor {
        switch item.state {
        case .needsInput: return theme.warning
        case .error: return theme.error
        case .done: return item.seen ? theme.textTertiary : theme.success
        case .working: return theme.accentColor
        }
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        AgentInbox.shared.prune()
        let target = menuTarget ?? AgentInboxMenuTarget()
        menuTarget = target
        let menu = target.makeMenu(theme: AppSettings.shared.theme)
        menu.popUp(positioning: nil, at: NSPoint(x: hitRect.minX, y: 0), in: barView)
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        MainActor.assumeIsolated { "Agents: " + Self.label(theme: AppSettings.shared.theme).0 }
    }
}

/// Builds the inbox menu and handles picks.
@MainActor
final class AgentInboxMenuTarget: NSObject {
    func makeMenu(theme: TerminalTheme) -> NSMenu {
        let menu = NSMenu()
        let inbox = AgentInbox.shared
        for item in inbox.sortedItems {
            let where_ = inbox.locate(item.tabID).map { $0.workspace.displayName } ?? ""
            let title = where_.isEmpty ? AgentInbox.summary(of: item) : "\(where_) — \(AgentInbox.summary(of: item))"
            let menuItem = NSMenuItem(title: title, action: #selector(jump(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.tabID
            menuItem.image = Self.dot(AgentInboxSegment.color(for: item, theme: theme))
            menu.addItem(menuItem)
        }
        let timelines = inbox.sortedItems.filter { $0.sessionID != nil }
        if !timelines.isEmpty {
            menu.addItem(.separator())
            let parent = NSMenuItem(title: "Show Timeline", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for item in timelines {
                let entry = NSMenuItem(
                    title: AgentHandoff.label(for: item), action: #selector(showTimeline(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.tabID
                submenu.addItem(entry)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        if inbox.attentionCount > 0 {
            menu.addItem(.separator())
            let next = NSMenuItem(
                title: "Jump to Next Waiting Agent", action: #selector(jumpNext(_:)), keyEquivalent: "")
            next.target = self
            menu.addItem(next)
        }
        return menu
    }

    @objc func jump(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        AgentInbox.shared.jump(to: id)
    }

    @objc func showTimeline(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        WindowManager.shared.activeController?.openTimeline(agentTab: id)
    }

    @objc func jumpNext(_ sender: Any?) { AgentInbox.shared.jumpToNextAttention() }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}
