import Foundation

/// A tab's OSC 9;4 progress report (ConEmu's sequence, sent by cargo, winget,
/// systemd and others), shown as a bar on the tab, the workspace pill and the
/// dock tile.
struct TerminalProgress: Equatable {
    enum State: Equatable {
        case normal, error, indeterminate, paused
    }

    /// One report as Ghostty delivers it.
    enum Report: Equatable {
        case remove, set, error, indeterminate, pause
    }

    var state: State
    /// 0–100, or nil when the program never sent a value.
    var percent: Int?
    var updatedAt: Date

    /// A program that dies mid-run never sends "remove"; clear the bar after
    /// this long without a report.
    static let staleAfter: TimeInterval = 15 * 60

    /// The progress after `report`; nil when the bar should go away. A report
    /// without a value (-1) keeps the previous percent for error and pause, as
    /// Windows Terminal does.
    static func applying(
        _ report: Report, percent raw: Int, to current: TerminalProgress?, now: Date = Date()
    ) -> TerminalProgress? {
        let value = raw < 0 ? nil : min(raw, 100)
        switch report {
        case .remove:
            return nil
        case .set:
            return TerminalProgress(state: .normal, percent: value ?? 0, updatedAt: now)
        case .error:
            return TerminalProgress(state: .error, percent: value ?? current?.percent, updatedAt: now)
        case .pause:
            return TerminalProgress(state: .paused, percent: value ?? current?.percent, updatedAt: now)
        case .indeterminate:
            return TerminalProgress(state: .indeterminate, percent: nil, updatedAt: now)
        }
    }

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    /// Bar fill 0–1; indeterminate fills the whole bar.
    var fraction: Double {
        guard state != .indeterminate else { return 1 }
        return Double(percent ?? 0) / 100
    }

    /// For a summary (workspace pill, dock): an error wins so it isn't hidden,
    /// then the furthest-along determinate bar, then any indeterminate one.
    static func summary(_ all: [TerminalProgress], now: Date = Date()) -> TerminalProgress? {
        let live = all.filter { !$0.isStale(now: now) }
        if let error = live.first(where: { $0.state == .error }) { return error }
        let determinate = live.filter { $0.state != .indeterminate }
        if let furthest = determinate.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) { return furthest }
        return live.first
    }
}
