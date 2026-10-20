import Foundation

/// How a new tab's terminal starts: a command typed into its shell, a working
/// directory and extra environment. Handed to `GhosttyView.pendingLaunch`
/// before the tab's surface is created.
struct LaunchSpec: Equatable {
    /// Typed into the shell as soon as it starts (no trailing newline).
    var command: String?
    /// Overrides the tab's working directory.
    var cwd: String?
    /// Added to the shell's environment; `BOO_*` keys are ignored.
    var env: [String: String] = [:]
}

extension LaunchSpec {
    /// Reads `command` and `env` from a socket command; nil when neither is set.
    /// Non-string env values are dropped.
    static func from(json: [String: Any]) -> LaunchSpec? {
        let command = (json["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let env = (json["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        guard command != nil || !env.isEmpty else { return nil }
        return LaunchSpec(command: command, env: env)
    }
}
