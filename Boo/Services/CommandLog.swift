import Combine
import Foundation

/// A command that finished in a terminal tab, with where it ran.
struct FinishedCommand: Equatable, Sendable {
    var command: String
    /// nil when the shell reported none.
    var exitCode: Int32?
    var duration: TimeInterval
    var startedAt: Date
    var cwd: String
    /// The ssh/mosh host or container target; nil for local shells.
    var host: String?
    var workspaceID: UUID
    var paneID: UUID
    var tabID: UUID

    var failed: Bool { (exitCode ?? 0) != 0 }
}

/// App-wide stream of finished commands (history, triggers, error → agent),
/// plus a per-tab command-block counter.
@MainActor
final class CommandLog {
    static let shared = CommandLog()

    let finished = PassthroughSubject<FinishedCommand, Never>()
    /// Bumped at every command start; a value identifies one command block.
    private(set) var blocks: [UUID: Int] = [:]

    func commandStarted(tabID: UUID) {
        blocks[tabID, default: 0] += 1
    }

    func block(of tabID: UUID) -> Int { blocks[tabID] ?? 0 }

    func tabClosed(_ tabID: UUID) {
        blocks[tabID] = nil
    }

    func publish(_ command: FinishedCommand) {
        finished.send(command)
    }

    /// Builds the record for a tab's last finished command, if it has one.
    static func finishedCommand(
        record: CommandRecord?, tab: Pane.Tab, workspaceID: UUID, paneID: UUID
    ) -> FinishedCommand? {
        guard let record, let finishedAt = record.finishedAt, !record.command.isEmpty else { return nil }
        let host = tab.remoteSession.map(\.displayName)
        let cwd = host != nil ? (tab.remoteWorkingDirectory ?? tab.workingDirectory) : tab.workingDirectory
        return FinishedCommand(
            command: record.command, exitCode: record.exitCode,
            duration: record.duration ?? finishedAt.timeIntervalSince(record.startedAt),
            startedAt: record.startedAt, cwd: cwd, host: host,
            workspaceID: workspaceID, paneID: paneID, tabID: tab.id)
    }
}
