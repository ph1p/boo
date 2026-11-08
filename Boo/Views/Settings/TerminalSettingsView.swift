import SwiftUI

// MARK: - Terminal

/// Everything about the terminal itself: how it looks, where new ones start,
/// what survives a restart, where clicked links go, and the commands it remembers.
struct TerminalSettingsView: View {
    @Environment(\.tokens) private var tokens
    @State private var cursorStyle = AppSettings.shared.cursorStyle
    @State private var fontSize = Double(AppSettings.shared.fontSize)
    @State private var fontName = AppSettings.shared.fontName
    @State private var shader = AppSettings.shared.terminalShader
    @State private var newTabCwdMode = AppSettings.shared.newTabCwdMode
    @State private var restoreScrollback = AppSettings.shared.restoreScrollback
    @State private var tmuxIntegration = AppSettings.shared.tmuxIntegration
    @State private var tmuxMode = AppSettings.shared.tmuxMode
    @State private var agentRecovery = AppSettings.shared.agentRecovery
    @State private var resumeAgentsAfterQuit = AppSettings.shared.resumeAgentsAfterQuit
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .terminal])

    private let monoFonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Terminal") {
            Section(title: "Font") {
                SettingRow(label: "Family") {
                    FontChooser(selectedFont: $fontName, fonts: monoFonts)
                        .onChange(of: fontName) { _, v in AppSettings.shared.fontName = v }
                }
                SettingRow(label: "Size") {
                    FontSizePicker(value: $fontSize, range: 10...28)
                        .onChange(of: fontSize) { _, v in AppSettings.shared.fontSize = CGFloat(v) }
                }
                Text("$ echo \"Hello, Boo\"")
                    .font(.custom(fontName, size: CGFloat(fontSize)))
                    .foregroundStyle(t.fg)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.termBg))
            }

            Section(title: "Look") {
                SettingStack(label: "Cursor") {
                    ThemedSegmentedPicker(selection: $cursorStyle) { $0.label }
                        .onChange(of: cursorStyle) { _, v in AppSettings.shared.cursorStyle = v }
                }
                SettingRow(
                    label: "Shader",
                    help: "Post-processing for every terminal. Profiles can override it. "
                        + "Custom files are Shadertoy-style GLSL (mainImage, iChannel0)."
                ) {
                    ShaderPicker(value: $shader)
                        .onChange(of: shader) { _, v in AppSettings.shared.terminalShader = v }
                }
            }

            Section(title: "Sessions") {
                SettingStack(
                    label: "New tabs and panes open in",
                    help: "The active tab's current directory, or the workspace default folder."
                ) {
                    ThemedSegmentedPicker(selection: $newTabCwdMode) { $0.label }
                        .onChange(of: newTabCwdMode) { _, v in AppSettings.shared.newTabCwdMode = v }
                }
                ToggleRow(
                    label: "Restore scrollback",
                    help:
                        "Save each terminal's output to ~/.boo/scrollback (owner-only) on quit and every few minutes, and show it again when the session is restored.",
                    isOn: $restoreScrollback
                )
                .onChange(of: restoreScrollback) { _, v in
                    AppSettings.shared.restoreScrollback = v
                    if !v { ScrollbackStore.clear() }
                }
                SettingStack(
                    label: "After a crash, agents",
                    help:
                        "Resume starts each tab's agent conversation again (Claude Code, Codex, OpenCode). Ask shows a prompt at launch."
                ) {
                    ThemedSegmentedPicker(selection: $agentRecovery) { $0.label }
                        .onChange(of: agentRecovery) { _, v in AppSettings.shared.agentRecovery = v }
                }
                if agentRecovery != .off {
                    ToggleRow(
                        label: "Also after a normal quit",
                        help: "Resume agents after quitting Boo or restarting it for an update, too.",
                        isOn: $resumeAgentsAfterQuit
                    )
                    .onChange(of: resumeAgentsAfterQuit) { _, v in AppSettings.shared.resumeAgentsAfterQuit = v }
                }
                ToggleRow(
                    label: "Native tmux windows",
                    help:
                        "Show `tmux -CC` sessions as workspaces and panes. Takes effect in terminals opened afterwards.",
                    isOn: $tmuxIntegration
                )
                .onChange(of: tmuxIntegration) { _, v in
                    AppSettings.shared.tmuxIntegration = v
                    tmuxMode = AppSettings.shared.tmuxMode
                }
                if tmuxIntegration {
                    SettingStack(
                        label: "Typing `tmux` opens it as tabs and splits",
                        help:
                            "Ask shows a one-line prompt in the shell. Start or attach sessions any time from the command palette (tmux)."
                    ) {
                        ThemedSegmentedPicker(selection: $tmuxMode) { $0.label }
                            .onChange(of: tmuxMode) { _, v in AppSettings.shared.tmuxMode = v }
                    }
                }
            }

            TerminalLinksSection()

            CommandHistorySection()

            QuickTerminalSettingsSection()
        }
        .foregroundStyle(t.text)
    }
}

// MARK: - Links

/// Where ⌘-clicked links in terminal output open: file:line links and web links.
private struct TerminalLinksSection: View {
    @State private var linkTarget = AppSettings.shared.defaultLinkTarget
    @State private var editorPreset = AppSettings.shared.externalEditorPreset
    @State private var editorTemplate = AppSettings.shared.externalEditorTemplate
    @State private var linkOpenMode = AppSettings.shared.linkOpenMode

    var body: some View {
        Section(title: "Links") {
            SettingRow(
                label: "⌘-click on a file opens",
                help: "file:line links in terminal output. ⌘⌥-click opens the other one. "
                    + "Remote panes always use the built-in editor."
            ) {
                ThemedMenuPicker(selection: $linkTarget) { $0.displayName }
                    .onChange(of: linkTarget) { _, v in AppSettings.shared.defaultLinkTarget = v }
            }
            SettingRow(label: "External editor") {
                ThemedMenuPicker(selection: $editorPreset) { $0.displayName }
                    .onChange(of: editorPreset) { _, v in AppSettings.shared.externalEditorPreset = v }
            }
            if editorPreset == .custom {
                SettingRow(
                    label: "Command",
                    help: "A URL or shell command. {path}, {line} and {col} are filled in; "
                        + "paths are quoted for you."
                ) {
                    SettingTextField(
                        placeholder: "nvim +{line} {path}", text: $editorTemplate, monospaced: true
                    )
                    .onChange(of: editorTemplate) { _, v in AppSettings.shared.externalEditorTemplate = v }
                }
            }
            SettingRow(label: "⌘-click on a web link opens") {
                ThemedMenuPicker(selection: $linkOpenMode) { $0.displayName }
                    .onChange(of: linkOpenMode) { _, v in AppSettings.shared.linkOpenMode = v }
            }
        }
    }
}

// MARK: - Command History

/// Settings for the shell command history behind ⌃R and the palette's `!`.
struct CommandHistorySection: View {
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
                ThemedStepper(value: $retentionDays, in: 0...3650, step: 30) {
                    $0 == 0 ? "Forever" : "\($0) days"
                }
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
