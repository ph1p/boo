import Foundation

/// One command a terminal's shell ran, from Boo's cmd_start to OSC 133 D.
struct CommandRecord: Equatable {
    var command: String
    /// nil while the command runs, or when the shell reported none.
    var exitCode: Int32?
    /// Ghostty's measured run time; nil until the command finishes.
    var duration: TimeInterval?
    var startedAt: Date
    var finishedAt: Date?

    var isRunning: Bool { finishedAt == nil }
}

/// A terminal's recent commands, oldest first.
struct CommandHistory: Equatable {
    static let limit = 500

    private(set) var records: [CommandRecord] = []

    var last: CommandRecord? { records.last }

    mutating func start(_ command: String, at date: Date = Date()) {
        records.append(CommandRecord(command: command, startedAt: date))
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }

    /// Closes the running command. A finish without a start (a program that
    /// emits OSC 133 itself) has no command text and is not recorded.
    /// - Parameters:
    ///   - exitCode: -1 when the shell sent none.
    ///   - durationNanos: Ghostty's run time; 0 when unknown.
    mutating func finish(exitCode: Int32, durationNanos: UInt64, at date: Date = Date()) {
        guard let index = records.indices.last, records[index].isRunning else { return }
        records[index].exitCode = exitCode < 0 ? nil : exitCode
        records[index].duration =
            durationNanos > 0
            ? TimeInterval(durationNanos) / 1_000_000_000
            : date.timeIntervalSince(records[index].startedAt)
        records[index].finishedAt = date
    }
}
