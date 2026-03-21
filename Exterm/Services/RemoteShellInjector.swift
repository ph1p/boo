import Foundation

/// Placeholder — remote CWD tracking uses out-of-band SSH/Docker commands
/// via RemoteExplorer. Title-based extraction (user@host:path in terminal
/// title) provides CWD for hosts with shell prompts that set the title.
/// For hosts without title-setting prompts, ControlMaster socket sharing
/// enables the file explorer to multiplex on the user's interactive session.
final class RemoteShellInjector {
    func injectIfNeeded(paneID: UUID) {}
    func sessionEnded(paneID: UUID) {}
    func cleanupAll() {}
}
