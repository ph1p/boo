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

// MARK: - Budgets

struct AgentBudgetSettingsSection: View {
    @State private var perTask = Self.text(AppSettings.shared.agentBudgetPerTask)
    @State private var perDay = Self.text(AppSettings.shared.agentBudgetPerDay)

    var body: some View {
        Section(
            title: "Budgets",
            footer:
                "Budgets only warn: the agent status shows the cost in amber at 80 % and red with a notification once a budget is passed."
        ) {
            SettingRow(label: "Per task", help: "USD, estimated from the transcript. Empty = off.") {
                SettingTextField(placeholder: "Off", text: $perTask, monospaced: true, width: 90)
                    .onChange(of: perTask) { _, value in AppSettings.shared.agentBudgetPerTask = Self.amount(value) }
            }
            SettingRow(label: "Per day", help: "USD across all agents today. Empty = off.") {
                SettingTextField(placeholder: "Off", text: $perDay, monospaced: true, width: 90)
                    .onChange(of: perDay) { _, value in AppSettings.shared.agentBudgetPerDay = Self.amount(value) }
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
