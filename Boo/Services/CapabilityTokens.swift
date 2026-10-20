import Foundation

/// Per-tab secrets handed to each Boo terminal as `BOO_TOKEN`, so the socket
/// can tell which tab sent a command and with what authority. Kept in memory
/// only; a relaunch issues new ones.
///
/// This catches model mistakes and overreach, not a same-user attacker, who
/// can read another process's environment.
@MainActor
final class CapabilityTokens {
    static let shared = CapabilityTokens()

    enum Grade: String {
        /// Normal panes: everything the user could do by hand.
        case full
        /// The orchestrator: writes into panes it does not own need approval.
        case gated
    }

    struct Caller: Equatable {
        let tabID: UUID
        let grade: Grade
    }

    private var tokens: [UUID: String] = [:]
    private var callers: [String: Caller] = [:]
    /// Tabs each gated caller started (its agent tasks); it writes to them freely.
    private var owned: [UUID: Set<UUID>] = [:]

    init() {}

    /// The tab's token, issued on first use with the `full` grade.
    func token(for tabID: UUID) -> String {
        if let token = tokens[tabID] { return token }
        let token = Self.randomToken()
        tokens[tabID] = token
        callers[token] = Caller(tabID: tabID, grade: .full)
        return token
    }

    /// Sets a tab's grade; call before its surface is created.
    func setGrade(_ grade: Grade, for tabID: UUID) {
        let token = token(for: tabID)
        callers[token] = Caller(tabID: tabID, grade: grade)
    }

    func resolve(_ token: String?) -> Caller? {
        guard let token, !token.isEmpty else { return nil }
        return callers[token]
    }

    func revoke(tabID: UUID) {
        if let token = tokens.removeValue(forKey: tabID) { callers.removeValue(forKey: token) }
        owned.removeValue(forKey: tabID)
        for key in owned.keys { owned[key]?.remove(tabID) }
    }

    // MARK: - Ownership

    func markOwned(_ tabID: UUID, by caller: UUID) {
        owned[caller, default: []].insert(tabID)
    }

    func disown(_ tabID: UUID) {
        for key in owned.keys { owned[key]?.remove(tabID) }
    }

    func owns(_ caller: UUID, _ tabID: UUID) -> Bool {
        owned[caller]?.contains(tabID) == true
    }

    func ownedTabs(of caller: UUID) -> Set<UUID> {
        owned[caller] ?? []
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }
}
