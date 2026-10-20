import Cocoa

/// Status bar toggle for the orchestrator drawer: a dot in the orchestrator's
/// state color, plus the number of cards waiting for you. Shown once the
/// orchestrator exists or a card waits.
final class OrchestratorSegment: StatusBarPlugin {
    let id = "orchestrator"
    let position: StatusBarPosition = .right
    let priority = 61
    var hitRect: NSRect = .zero

    var tooltipText: String? { "Orchestrator — click to toggle (⌥⌘O)" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        MainActor.assumeIsolated {
            OrchestratorController.shared.host != nil || !ApprovalCenter.shared.pending.isEmpty
        }
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

    @MainActor static func label(theme: TerminalTheme) -> (String, NSColor) {
        let pending = ApprovalCenter.shared.pending.count
        if pending > 0 {
            return (pending == 1 ? "Orchestrator · 1 card" : "Orchestrator · \(pending) cards", theme.warning)
        }
        let color =
            AgentInbox.shared.orchestrator.map { AgentInboxSegment.color(for: $0, theme: theme) }
            ?? (OrchestratorController.shared.isRunning ? theme.textSecondary : theme.textTertiary)
        return ("Orchestrator", color)
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        MainActor.assumeIsolated {
            guard let controller = WindowManager.shared.controllers.first(where: { $0.window === barView.window })
            else { return }
            OrchestratorController.shared.toggleDrawer(in: controller)
        }
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        MainActor.assumeIsolated { Self.label(theme: AppSettings.shared.theme).0 }
    }
}
