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
