import Cocoa
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @State private var defaultFolder = AppSettings.shared.defaultFolder
    @State private var defaultMainPage = AppSettings.shared.defaultMainPage
    @State private var defaultTabType = AppSettings.shared.defaultTabType
    @State private var newTabCwdMode = AppSettings.shared.newTabCwdMode
    @State private var debugLogging = AppSettings.shared.debugLogging
    @State private var fileEditorCommand = AppSettings.shared.fileEditorCommand
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "General") {
            Section(title: "Default Folder") {
                HStack(spacing: 8) {
                    Text(defaultFolder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(t.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
                        panel.message = "Choose the default folder for new workspaces"
                        if panel.runModal() == .OK, let url = panel.url {
                            defaultFolder = url.path
                            AppSettings.shared.defaultFolder = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reset") {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        defaultFolder = home
                        AppSettings.shared.defaultFolder = home
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                    .frame(maxWidth: 220, alignment: .leading)
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
            }

            Section(title: "New Tab & Pane Path") {
                Picker("", selection: $newTabCwdMode) {
                    ForEach(NewTabCwdMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: newTabCwdMode) { _, v in AppSettings.shared.newTabCwdMode = v }
                DescriptionLabel(
                    text:
                        "Whether new tabs and split panes open in the active tab's current directory or the workspace default folder."
                )
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
