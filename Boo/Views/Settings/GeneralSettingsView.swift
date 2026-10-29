import Cocoa
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(\.tokens) private var tokens
    @State private var defaultFolder = AppSettings.shared.defaultFolder
    @State private var defaultMainPage = AppSettings.shared.defaultMainPage
    @State private var defaultTabType = AppSettings.shared.defaultTabType
    @State private var newTabCwdMode = AppSettings.shared.newTabCwdMode
    @State private var debugLogging = AppSettings.shared.debugLogging
    @State private var fileEditorCommand = AppSettings.shared.fileEditorCommand
    @State private var restoreScrollback = AppSettings.shared.restoreScrollback
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "General") {
            Section(title: "Folders") {
                PathRow(label: "Default folder", path: defaultFolder, help: "Where new workspaces open.") {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
                        panel.message = "Choose the default folder for new workspaces"
                        if panel.runModal() == .OK, let url = panel.url {
                            FolderBookmarkStore.shared.save(url)
                            defaultFolder = url.path
                            AppSettings.shared.defaultFolder = url.path
                        }
                    }
                    Button("Reset") {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        defaultFolder = home
                        AppSettings.shared.defaultFolder = home
                    }
                    .disabled(defaultFolder == FileManager.default.homeDirectoryForCurrentUser.path)
                }
                SettingStack(
                    label: "New tabs and panes open in",
                    help: "The active tab's current directory, or the workspace default folder."
                ) {
                    Picker("", selection: $newTabCwdMode) {
                        ForEach(NewTabCwdMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: newTabCwdMode) { _, v in AppSettings.shared.newTabCwdMode = v }
                }
            }

            Section(title: "Startup") {
                SettingRow(label: "Initial tab") {
                    Picker("", selection: $defaultTabType) {
                        Text(ContentType.terminal.displayName).tag(ContentType.terminal)
                        Text(ContentType.browser.displayName).tag(ContentType.browser)
                        Text(ContentType.editor.displayName).tag(ContentType.editor)
                        Text(ContentType.imageViewer.displayName).tag(ContentType.imageViewer)
                        Text(ContentType.markdownPreview.displayName).tag(ContentType.markdownPreview)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: defaultTabType) { _, v in
                        AppSettings.shared.defaultTabType = v
                    }
                }

                SettingRow(
                    label: "Main page",
                    help:
                        "Used for the first tab in a new workspace. Terminal expects a folder path, browser expects a URL, and editor/image/markdown expect a file path."
                ) {
                    SettingTextField(
                        placeholder: "Path or URL",
                        text: $defaultMainPage,
                        monospaced: true,
                        onCommit: {
                            AppSettings.shared.defaultMainPage =
                                defaultMainPage.trimmingCharacters(in: .whitespaces)
                        }
                    )
                    .onChange(of: defaultMainPage) { _, v in
                        AppSettings.shared.defaultMainPage = v.trimmingCharacters(in: .whitespaces)
                    }
                }

                ToggleRow(
                    label: "Restore terminal scrollback",
                    help:
                        "On quit, save each terminal's output to ~/.boo/scrollback (owner-only) and show it again when the session is restored.",
                    isOn: $restoreScrollback
                )
                .onChange(of: restoreScrollback) { _, v in
                    AppSettings.shared.restoreScrollback = v
                    if !v { ScrollbackStore.clear() }
                }
            }

            Section(title: "File Editor") {
                SettingRow(
                    label: "Command",
                    help: "Command run when clicking a file in the explorer. Leave empty to use $EDITOR."
                ) {
                    SettingTextField(
                        placeholder: "vim, nvim, nano… (empty = $EDITOR)",
                        text: $fileEditorCommand,
                        monospaced: true,
                        onCommit: {
                            AppSettings.shared.fileEditorCommand =
                                fileEditorCommand.trimmingCharacters(in: .whitespaces)
                        }
                    )
                    .onChange(of: fileEditorCommand) { _, v in
                        AppSettings.shared.fileEditorCommand =
                            v.trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            CommandHistorySection()

            SyncFolderSection()

            AgentsSection()

            Section(title: "Advanced") {
                ToggleRow(
                    label: "Debug logging",
                    help: "Writes verbose output to the system log. Disable when not troubleshooting.",
                    isOn: $debugLogging
                )
                .onChange(of: debugLogging) { _, v in
                    AppSettings.shared.debugLogging = v
                    BooLogger.shared.applyDebugSetting(v)
                }
            }
        }
        .foregroundStyle(t.text)
    }
}

// MARK: - Agents

private struct AgentsSection: View {
    @State private var errorButton = AppSettings.shared.errorAgentButtonEnabled
    @State private var perTask = Self.text(AppSettings.shared.agentBudgetPerTask)
    @State private var perDay = Self.text(AppSettings.shared.agentBudgetPerDay)

    var body: some View {
        Section(
            title: "Agents",
            footer:
                "Budgets only warn: the agent status shows the cost in amber at 80 % and red with a notification once a budget is passed."
        ) {
            ToggleRow(
                label: "Send failed commands to agent",
                help: "Show a button on failed command blocks that sends the command and its output to an agent.",
                isOn: Binding(
                    get: { errorButton },
                    set: {
                        errorButton = $0
                        AppSettings.shared.errorAgentButtonEnabled = $0
                    }
                )
            )
            SettingRow(label: "Budget per task", help: "USD, estimated from the transcript. Empty = off.") {
                SettingTextField(placeholder: "Off", text: $perTask, monospaced: true, width: 90)
                    .onChange(of: perTask) { _, value in AppSettings.shared.agentBudgetPerTask = Self.amount(value) }
            }
            SettingRow(label: "Budget per day", help: "USD across all agents today. Empty = off.") {
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

// MARK: - Sync Folder

/// Mirrors settings, profiles, rules, key tables, snippets, themes and recipes
/// with a folder such as one in iCloud Drive.
private struct SyncFolderSection: View {
    @State private var folder = AppSettings.shared.syncFolder
    @State private var status = ""

    var body: some View {
        Section(
            title: "Sync",
            footer:
                "Mirrors appearance, editor, status bar, plugin and history settings, custom themes, "
                + "profiles, rules, key tables, snippets, themes and recipes. Folders, paths and "
                + "window layout stay per machine."
        ) {
            PathRow(label: "Sync folder", path: folder, placeholder: "Off", help: status.isEmpty ? nil : status) {
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose a folder to mirror Boo's settings with (e.g. in iCloud Drive)"
                    if panel.runModal() == .OK, let url = panel.url {
                        folder = url.path
                        AppSettings.shared.syncFolder = url.path
                    }
                }
                Button("Sync Now") { SyncService.shared.syncNow() }
                    .disabled(folder.isEmpty)
                Button("Turn Off") {
                    folder = ""
                    AppSettings.shared.syncFolder = ""
                }
                .disabled(folder.isEmpty)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .syncStatusChanged)) { _ in refresh() }
    }

    private func refresh() {
        let service = SyncService.shared
        if let error = service.lastError {
            status = error
        } else if !service.conflicts.isEmpty {
            status = "Conflicts: \(service.conflicts.joined(separator: ", ")) — resolve from the status bar"
        } else if let last = service.lastSync {
            status = "Last synced \(last.formatted(date: .omitted, time: .shortened))"
        } else {
            status = ""
        }
    }
}

// MARK: - Command History

/// Settings for the shell command history behind ⌃R and the palette's `!`.
private struct CommandHistorySection: View {
    @Environment(\.tokens) private var tokens
    @State private var enabled = AppSettings.shared.historyEnabled
    @State private var shortcut = AppSettings.shared.historySearchShortcutEnabled
    @State private var ignorePattern = AppSettings.shared.historyIgnorePattern
    @State private var retentionDays = AppSettings.shared.historyRetentionDays
    @State private var entryCount: Int?
    @State private var confirmClear = false

    private var patternError: String? {
        guard !ignorePattern.isEmpty, (try? NSRegularExpression(pattern: ignorePattern)) == nil else { return nil }
        return "Invalid regex; the default pattern is used instead."
    }

    var body: some View {
        let t = tokens
        Section(title: "Command History") {
            ToggleRow(
                label: "Record commands",
                help: "Saves finished commands with their folder, exit code and duration to ~/.boo/history.db.",
                isOn: $enabled
            )
            .onChange(of: enabled) { _, v in AppSettings.shared.historyEnabled = v }

            ToggleRow(
                label: "⌃R opens history search",
                help: "At a shell prompt with Boo's shell integration. Off leaves ⌃R to the shell.",
                isOn: $shortcut
            )
            .onChange(of: shortcut) { _, v in AppSettings.shared.historySearchShortcutEnabled = v }

            SettingRow(
                label: "Ignore pattern",
                help: "Commands matching this regex are never saved. Empty saves everything."
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        SettingTextField(
                            placeholder: "regex", text: $ignorePattern, monospaced: true)
                        Button("Default") {
                            ignorePattern = AppSettings.defaultHistoryIgnorePattern
                        }
                        .buttonStyle(.themed)
                        .disabled(ignorePattern == AppSettings.defaultHistoryIgnorePattern)
                    }
                    if let patternError {
                        Text(patternError).font(.system(size: 11)).foregroundStyle(t.error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onChange(of: ignorePattern) { _, v in AppSettings.shared.historyIgnorePattern = v }
            }

            SettingRow(label: "Keep for", help: "Older commands are removed at launch. 0 keeps them forever.") {
                Stepper(value: $retentionDays, in: 0...3650, step: 30) {
                    Text(retentionDays == 0 ? "Forever" : "\(retentionDays) days")
                        .font(.system(size: 12).monospacedDigit())
                }
                .controlSize(.small)
                .onChange(of: retentionDays) { _, v in AppSettings.shared.historyRetentionDays = v }
            }

            HStack {
                Text(entryCount.map { "\($0) commands saved" } ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .buttonStyle(.themed)
                    .disabled(entryCount == 0)
            }
        }
        .task { entryCount = await HistoryStore.shared.count() }
        .confirmationDialog("Clear all command history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                HistoryStore.shared.clear {
                    Task { @MainActor in entryCount = 0 }
                }
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}
