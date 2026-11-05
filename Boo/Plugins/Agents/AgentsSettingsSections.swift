import SwiftUI

// MARK: - Quick Access

/// The global "next agent that needs you" hotkey and the failed-command button.
struct AgentQuickAccessSettingsSection: View {
    @ObservedObject private var observer = SettingsObserver()
    @State private var hotkey = AppSettings.shared.agentJumpHotkey
    @State private var errorButton = AppSettings.shared.errorAgentButtonEnabled

    var body: some View {
        let _ = observer.revision
        let settings = AppSettings.shared

        Section(title: "Quick Access") {
            SettingRow(
                label: "Jump to waiting agent",
                help: "From any app, brings Boo forward on the next agent that needs you. "
                    + "Like ctrl+opt+j; empty is off. Inside Boo, ⇧⌘J does the same."
            ) {
                HStack(spacing: 8) {
                    SettingTextField(
                        placeholder: "off", text: $hotkey, monospaced: true, width: 160,
                        onCommit: { settings.agentJumpHotkey = hotkey.trimmingCharacters(in: .whitespaces) })
                    if let spec = HotKeySpec.parse(settings.agentJumpHotkey) {
                        ShortcutPill(text: spec.display)
                    }
                }
            }
            if let problem = AgentJumpHotKey.shared.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: settings.theme.error))
            }
            ToggleRow(
                label: "Send failed commands to agent",
                help: "Show a button on failed command blocks that sends the command and its output to an agent.",
                isOn: Binding(
                    get: { errorButton },
                    set: {
                        errorButton = $0
                        settings.errorAgentButtonEnabled = $0
                    }
                )
            )
        }
    }
}

// MARK: - Costs

/// Global cost tracking: the switch, what every Claude Code session cost by
/// period, project, model and day, and the budgets.
struct AgentCostSettingsSection: View {
    enum Period: Int, CaseIterable, Identifiable {
        case today = 1
        case week = 7
        case month = 30

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "7 days"
            case .month: "30 days"
            }
        }
    }

    @Environment(\.tokens) private var t
    @ObservedObject private var observer = SettingsObserver(topics: [.agents])
    @State private var tracking = AppSettings.shared.agentCostTracking
    @State private var period = Period.week
    @State private var records = AgentCostLedger.shared.records
    @State private var scanning = AgentCostLedger.shared.isScanning
    @State private var perTask = Self.text(AppSettings.shared.agentBudgetPerTask)
    @State private var perDay = Self.text(AppSettings.shared.agentBudgetPerDay)

    private static let listLimit = 6

    var body: some View {
        let _ = observer.revision
        let summary = AgentCostSummary(records, days: period.rawValue)

        Section(
            title: "Costs",
            footer: tracking
                ? "Estimated from token counts at list prices, for every Claude Code session on this Mac "
                    + "(subagents included), not only the agents in Boo. Subscription plans are not billed this way."
                : nil
        ) {
            ToggleRow(
                label: "Track agent costs",
                help: "Reads Claude Code transcripts to estimate what agents cost. "
                    + "Shows the cost in the agent status, the timeline and here. Off: no transcript is read for costs.",
                isOn: Binding(
                    get: { tracking },
                    set: {
                        tracking = $0
                        AppSettings.shared.agentCostTracking = $0
                        if $0 { AgentCostLedger.shared.refresh() }
                    }
                )
            )
            if tracking {
                if records.isEmpty && (scanning || AgentCostLedger.shared.lastScan == nil) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        DescriptionLabel(text: "Reading transcripts of the last 30 days…")
                    }
                } else {
                    overview(summary)
                    if summary.total > 0 {
                        breakdown("By project", summary.projects, total: summary.total, paths: true)
                        breakdown("By model", summary.models, total: summary.total, paths: false)
                    }
                }
            }
        }
        .onAppear {
            sync()
            AgentCostLedger.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentCostsChanged)) { _ in sync() }

        Section(
            title: "Budgets",
            footer:
                "Budgets only warn: the agent status shows the cost in amber at 80 % and red with a notification once a budget is passed."
        ) {
            SettingRow(label: "Per task", help: "USD for one agent session. Empty = off.") {
                SettingTextField(placeholder: "Off", text: $perTask, monospaced: true, width: 90)
                    .onChange(of: perTask) { _, value in AppSettings.shared.agentBudgetPerTask = Self.amount(value) }
            }
            SettingRow(label: "Per day", help: "USD across all Claude Code sessions today. Empty = off.") {
                SettingTextField(placeholder: "Off", text: $perDay, monospaced: true, width: 90)
                    .onChange(of: perDay) { _, value in AppSettings.shared.agentBudgetPerDay = Self.amount(value) }
            }
        }
        .disabled(!tracking)
        .opacity(tracking ? 1 : 0.5)
    }

    private func sync() {
        let ledger = AgentCostLedger.shared
        records = ledger.records
        scanning = ledger.isScanning
        tracking = AppSettings.shared.agentCostTracking
    }

    // MARK: Overview

    private func overview(_ summary: AgentCostSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("≈ " + AgentBudget.format(summary.total))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(t.text)
                    Text(detail(summary)).font(.system(size: 11)).foregroundStyle(t.muted)
                }
                Spacer()
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if summary.days.count > 1 { dayBars(summary.days) }
        }
    }

    private func detail(_ summary: AgentCostSummary) -> String {
        var parts = ["\(summary.sessions) session\(summary.sessions == 1 ? "" : "s")"]
        if summary.subagents > 0 { parts.append("subagents " + AgentBudget.format(summary.subagents)) }
        if summary.days.count > 1 {
            parts.append("⌀ " + AgentBudget.format(summary.total / Double(summary.days.count)) + " a day")
        }
        return parts.joined(separator: " · ")
    }

    private func dayBars(_ days: [AgentCostSummary.Day]) -> some View {
        let peak = days.map(\.cost).max() ?? 0
        let formatter = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        return HStack(alignment: .bottom, spacing: days.count > 10 ? 2 : 6) {
            ForEach(days, id: \.start) { day in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Calendar.current.isDateInToday(day.start) ? t.accent : t.accentEmphasis)
                    .frame(height: max(2, 44 * CGFloat(peak > 0 ? day.cost / peak : 0)))
                    .frame(maxWidth: .infinity)
                    .help("\(day.start.formatted(formatter)): ≈ \(AgentBudget.format(day.cost))")
            }
        }
        .frame(height: 44, alignment: .bottom)
    }

    // MARK: Breakdown

    private func breakdown(
        _ title: String, _ rows: [AgentCostSummary.Row], total: Double, paths: Bool
    )
        -> some View
    {
        var shown = Array(rows.prefix(Self.listLimit))
        if rows.count > Self.listLimit {
            let rest = rows.dropFirst(Self.listLimit)
            shown.append(
                AgentCostSummary.Row(
                    id: "\u{0}more", name: "\(rest.count) more", cost: rest.reduce(0) { $0 + $1.cost }))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(t.muted)
            ForEach(shown) { row in
                HStack(spacing: 8) {
                    Text(row.name).font(.system(size: 12)).foregroundStyle(t.text).lineLimit(1)
                        .truncationMode(.middle)
                        .help(paths && row.id.hasPrefix("/") ? row.id : row.name)
                    Spacer(minLength: 8)
                    RoundedRectangle(cornerRadius: 2).fill(t.accentEmphasis)
                        .frame(width: max(2, 80 * CGFloat(total > 0 ? row.cost / total : 0)), height: 4)
                        .frame(width: 80, alignment: .trailing)
                    Text(AgentBudget.format(row.cost)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t.textSecondary)
                        .frame(minWidth: 48, alignment: .trailing)
                }
            }
        }
    }

    private static func text(_ value: Double?) -> String {
        value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
    }

    static func amount(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
        return Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
    }
}
