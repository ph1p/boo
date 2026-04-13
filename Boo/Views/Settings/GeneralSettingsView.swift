import Cocoa
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @State private var defaultFolder = AppSettings.shared.defaultFolder
    @State private var newTabCwdMode = AppSettings.shared.newTabCwdMode
    @State private var autoCheckUpdates = AppSettings.shared.autoCheckUpdates
    @State private var debugLogging = AppSettings.shared.debugLogging
    @State private var fileEditorCommand = AppSettings.shared.fileEditorCommand
    @State private var markdownOpenMode = AppSettings.shared.markdownOpenMode
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "General") {
            Section(title: "Default Folder") {
                HStack(spacing: 8) {
                    Text(defaultFolder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(t.muted)
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

            Section(title: "New Tab & Pane Path") {
                Picker("", selection: $newTabCwdMode) {
                    ForEach(NewTabCwdMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: newTabCwdMode) { v in AppSettings.shared.newTabCwdMode = v }
                Text(
                    "Whether new tabs and split panes open in the active tab's current directory or the workspace default folder."
                )
                .font(.system(size: 11))
                .foregroundColor(t.muted)
            }

            Section(title: "File Editor") {
                HStack(spacing: 8) {
                    TextField("vim, nvim, nano… (empty = $EDITOR)", text: $fileEditorCommand)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(t.text)
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
                        .onChange(of: fileEditorCommand) { v in
                            AppSettings.shared.fileEditorCommand =
                                v.trimmingCharacters(in: .whitespaces)
                        }
                }
                Text("Command run when clicking a file in the explorer. Leave empty to use $EDITOR.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Markdown Files") {
                Picker("", selection: $markdownOpenMode) {
                    ForEach(MarkdownOpenMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: markdownOpenMode) { v in
                    AppSettings.shared.markdownOpenMode = v
                }
                Text("How to open markdown files when clicked in the file explorer.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Updates") {
                ToggleRow(label: "Check for updates automatically", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { v in AppSettings.shared.autoCheckUpdates = v }
            }

            Section(title: "Advanced") {
                ToggleRow(label: "Debug logging", isOn: $debugLogging)
                    .onChange(of: debugLogging) { v in
                        AppSettings.shared.debugLogging = v
                        BooLogger.shared.applyDebugSetting(v)
                    }
                Text("Writes verbose output to the system log. Disable when not troubleshooting.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }
        }
        .foregroundColor(t.text)
    }
}
