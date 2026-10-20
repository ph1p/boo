import Foundation

/// The app-wide orchestrator: one Claude Code session in a terminal that is in
/// no window's split tree, driving Boo through its MCP server.
///
/// Its tab gets a `gated` token, so writes into panes it did not start go
/// through `ApprovalCenter`. Socket commands naming its pane are routed here
/// by `WindowManager.dispatchCommand`, not to a window.
@MainActor
final class OrchestratorController {
    static let shared = OrchestratorController()

    private(set) var host: DetachedPaneHost?

    var tabID: UUID? { host?.tabID }
    var paneID: UUID? { host?.paneID }
    var isRunning: Bool { host?.isRunning == true }

    init() {}

    /// The host, created on first use (its pane and tab IDs then stay stable
    /// for the app session).
    func ensureHost(workingDirectory: String = NSHomeDirectory()) -> DetachedPaneHost {
        if let host { return host }
        let host = DetachedPaneHost(workingDirectory: workingDirectory, title: "Orchestrator")
        CapabilityTokens.shared.setGrade(.gated, for: host.tabID)
        host.onExited = { [weak self] in self?.terminalExited() }
        self.host = host
        return host
    }

    /// Starts the orchestrator's terminal with `launch` unless it is running.
    func start(_ launch: LaunchSpec) {
        ensureHost().start(launch)
    }

    func stop() {
        host?.stop()
    }

    func isOrchestratorPane(_ paneID: UUID) -> Bool { self.paneID == paneID }

    // MARK: - Socket

    /// Commands that name the orchestrator's pane. It only answers reads:
    /// everything else acts on a workspace pane, which it is not.
    func handleIPCCommand(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let host, let paneID else {
            reply(["ok": false, "error": "orchestrator is not running"])
            return
        }
        switch cmd {
        case "get_screen":
            guard let terminal = host.terminal else {
                reply(["ok": false, "error": "pane has no running terminal"])
                return
            }
            let text =
                (json["lines"] as? Int).flatMap { terminal.readRecentText(lines: min($0, 5000)) }
                ?? terminal.readViewportText()
            reply([
                "ok": true, "pane_id": paneID.uuidString, "text": text ?? "", "title": host.title,
                "cwd": host.pane.tabs[0].workingDirectory
            ])
        default:
            reply(["ok": false, "error": "the orchestrator pane is not in a workspace; pass a workspace pane_id"])
        }
    }

    // MARK: - Private

    private func terminalExited() {
        // Its cards can no longer be answered into a running session.
        ApprovalCenter.shared.expireAll()
        AgentInbox.shared.applyOrchestrator(event: "end", tabID: host?.tabID ?? UUID())
    }
}
