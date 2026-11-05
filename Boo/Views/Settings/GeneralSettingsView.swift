import Cocoa
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(\.tokens) private var tokens
    @State private var defaultFolder = AppSettings.shared.defaultFolder
    @State private var defaultMainPage = AppSettings.shared.defaultMainPage
    @State private var defaultTabType = AppSettings.shared.defaultTabType
    @State private var debugLogging = AppSettings.shared.debugLogging
    @State private var fileEditorCommand = AppSettings.shared.fileEditorCommand
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "General") {
            Section(title: "New Workspaces") {
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
                SettingRow(label: "First tab") {
                    ThemedMenuPicker(
                        selection: $defaultTabType,
                        options: [.terminal, .browser, .editor, .imageViewer, .markdownPreview]
                    ) { $0.displayName }
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

            Section(title: "File Tree") {
                SettingRow(
                    label: "Edit files with",
                    help: "Terminal editor run when a file in the file tree opens in a terminal. Empty uses $EDITOR."
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

            SyncFolderSection()

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
