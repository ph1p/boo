import Foundation

/// Decides whether a socket command may run, based on the caller's
/// `BOO_TOKEN` grade and what the command touches.
///
/// Sensitive commands are the ones that give a caller power it would not have
/// from its own shell: answering or typing into an agent, typing into a
/// remote session, closing an agent pane, merging or discarding a task. Other
/// commands need no token, so external scripts keep working. The remote-control
/// server has its own auth and is not gated.
enum OrchestratorGate {
    /// What a sensitive command acts on, resolved from its `tab_id` or `pane_id`.
    struct Target: Equatable {
        var tabIDs: [UUID]
        var isAgent: Bool
        var isRemote: Bool
    }

    enum Decision: Equatable {
        case allow
        case reject(String)
        /// Gated caller: the user decides on an approval card.
        case approve
    }

    /// Always sensitive, whatever the target.
    static let tabCommands: Set<String> = ["agent_respond", "merge_task", "discard_task"]
    /// Sensitive when the pane's tab runs an agent or a remote session.
    static let typingCommands: Set<String> = ["send_text", "send_key"]
    /// Sensitive when any tab of the pane runs an agent.
    static let closeCommands: Set<String> = ["close_pane"]
    /// Need a card even for tabs the orchestrator owns.
    static let alwaysApproved: Set<String> = ["merge_task", "discard_task"]

    static func isSensitive(cmd: String, target: Target?) -> Bool {
        if tabCommands.contains(cmd) { return true }
        guard let target else { return false }
        if typingCommands.contains(cmd) { return target.isAgent || target.isRemote }
        if closeCommands.contains(cmd) { return target.isAgent }
        return false
    }

    /// - Parameters:
    ///   - owns: whether the caller started this tab.
    ///   - granted: whether the user allowed this caller to write to this tab for the session.
    static func decide(
        cmd: String, caller: CapabilityTokens.Caller?, target: Target?,
        owns: (UUID) -> Bool, granted: (UUID) -> Bool
    ) -> Decision {
        guard isSensitive(cmd: cmd, target: target) else { return .allow }
        guard let caller else {
            return .reject("\(cmd) on this target needs the BOO_TOKEN of a Boo terminal")
        }
        if caller.grade == .full { return .allow }
        if alwaysApproved.contains(cmd) { return .approve }
        // Unresolved target: let the command fail on its own (bad or missing id).
        guard let target, !target.tabIDs.isEmpty else { return .allow }
        if target.tabIDs.allSatisfy({ owns($0) || granted($0) }) { return .allow }
        return .approve
    }

    /// The tab or pane field names the command uses for its target.
    static func needsTarget(_ cmd: String) -> Bool {
        tabCommands.contains(cmd) || typingCommands.contains(cmd) || closeCommands.contains(cmd)
    }
}
