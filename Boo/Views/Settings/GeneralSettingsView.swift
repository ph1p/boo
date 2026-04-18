import Cocoa
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @State private var defaultFolder = AppSettings.shared.defaultFolder
    @State private var defaultMainPage = AppSettings.shared.defaultMainPage
    @State private var defaultTabType = AppSettings.shared.defaultTabType
    @State private var newTabCwdMode = AppSettings.shared.newTabCwdMode
    @State private var autoCheckUpdates = AppSettings.shared.autoCheckUpdates
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
                HStack(spacing: 8) {
                    Text("Initial tab")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $defaultTabType) {
                        Text(ContentType.terminal.displayName).tag(ContentType.terminal)
                        Text(ContentType.browser.displayName).tag(ContentType.browser)
                        Text(ContentType.editor.displayName).tag(ContentType.editor)
                        Text(ContentType.imageViewer.displayName).tag(ContentType.imageViewer)
                        Text(ContentType.markdownPreview.displayName).tag(ContentType.markdownPreview)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: defaultTabType) { _, v in
                        AppSettings.shared.defaultTabType = v
                    }
                }

                HStack(spacing: 8) {
                    Text("Main page")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .frame(width: 80, alignment: .leading)
                    TextField("Path or URL", text: $defaultMainPage)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border, lineWidth: 1)
                        )
                        .onSubmit {
                            AppSettings.shared.defaultMainPage =
                                defaultMainPage.trimmingCharacters(in: .whitespaces)
                        }
                        .onChange(of: defaultMainPage) { _, v in
                            AppSettings.shared.defaultMainPage = v.trimmingCharacters(in: .whitespaces)
                        }
                }
                Text(
                    "Used for the first tab in a new workspace. Terminal expects a folder path, browser expects a URL, and editor/image/markdown expect a file path."
                )
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
            }

            Section(title: "New Tab & Pane Path") {
                Picker("", selection: $newTabCwdMode) {
                    ForEach(NewTabCwdMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: newTabCwdMode) { _, v in AppSettings.shared.newTabCwdMode = v }
                Text(
                    "Whether new tabs and split panes open in the active tab's current directory or the workspace default folder."
                )
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
            }

            Section(title: "File Editor") {
                HStack(spacing: 8) {
                    TextField("vim, nvim, nano… (empty = $EDITOR)", text: $fileEditorCommand)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border, lineWidth: 1)
                        )
                        .onSubmit {
                            AppSettings.shared.fileEditorCommand =
                                fileEditorCommand.trimmingCharacters(in: .whitespaces)
                        }
                        .onChange(of: fileEditorCommand) { _, v in
                            AppSettings.shared.fileEditorCommand =
                                v.trimmingCharacters(in: .whitespaces)
                        }
                }
                Text("Command run when clicking a file in the explorer. Leave empty to use $EDITOR.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }

            Section(title: "Updates") {
                ToggleRow(label: "Check for updates automatically", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, v in AppSettings.shared.autoCheckUpdates = v }
            }

            Section(title: "Advanced") {
                ToggleRow(label: "Debug logging", isOn: $debugLogging)
                    .onChange(of: debugLogging) { _, v in
                        AppSettings.shared.debugLogging = v
                        BooLogger.shared.applyDebugSetting(v)
                    }
                Text("Writes verbose output to the system log. Disable when not troubleshooting.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
        }
        .foregroundStyle(t.text)
    }
}
