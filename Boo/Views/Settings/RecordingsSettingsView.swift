import SwiftUI

// MARK: - Recordings

/// One `.cast` file in the recordings folder, as the library lists it.
struct RecordingFile: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date
    let size: Int64
    /// Playback length after idle capping; nil when the file doesn't parse.
    let duration: TimeInterval?
    let markers: Int

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Every `.cast` in `directory`, newest first. Parses each file, so call off the main thread.
    static func scan(_ directory: URL, idleLimit: TimeInterval) -> [RecordingFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "cast" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let playback = (try? String(contentsOf: url, encoding: .utf8)).flatMap {
                    try? CastPlayback(text: $0, fallbackIdleLimit: idleLimit)
                }
                return RecordingFile(
                    url: url,
                    date: playback?.startDate ?? values?.creationDate ?? values?.contentModificationDate
                        ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0),
                    duration: playback?.duration,
                    markers: playback?.markers.count ?? 0)
            }
            .sorted { $0.date > $1.date }
    }
}

struct RecordingsSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout])
    @State private var recordings: [RecordingFile] = []
    @State private var loading = false
    @State private var renaming: RecordingFile?
    @State private var newName = ""
    @State private var pendingDelete: RecordingFile?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        let _ = observer.revision
        let t = tokens
        let settings = AppSettings.shared

        SettingsPage(title: "Recordings") {
            DescriptionLabel(
                text:
                    "Terminal sessions are saved as asciicast v2 (.cast) files: a JSON header followed by one timed output event per line. Play them here, with `asciinema play`, or turn them into GIFs with `agg`."
            )

            Section(title: "Saving") {
                SettingStack(label: "Folder") {
                    HStack(spacing: 8) {
                        Text((SessionRecorder.recordingsDirectory.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(t.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseFolder).buttonStyle(.themed)
                        Button("Reveal") {
                            let dir = SessionRecorder.recordingsDirectory
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                        .buttonStyle(.themed)
                        Button("Reset") { settings.recordingsFolder = "" }
                            .buttonStyle(.themed)
                            .disabled(settings.recordingsFolder.isEmpty)
                    }
                }
                SettingsRowDivider()
                SettingStack(
                    label: "File name",
                    help:
                        "Tokens: \(SessionRecorder.templateTokens.joined(separator: " ")). A number is appended when the name is taken."
                ) {
                    HStack(spacing: 8) {
                        TextField(
                            SessionRecorder.defaultTemplate,
                            text: LayoutSettingsBindings.binding(\.recordingFileNameTemplate)
                        )
                        .themedTextField()
                        .font(.system(size: 12, design: .monospaced))
                        Button("Default") { settings.recordingFileNameTemplate = SessionRecorder.defaultTemplate }
                            .buttonStyle(.themed)
                            .disabled(settings.recordingFileNameTemplate == SessionRecorder.defaultTemplate)
                    }
                    Text("Example: \(templatePreview).cast")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                SettingsRowDivider()
                SettingStack(
                    label: "Idle time limit",
                    help:
                        "Pauses longer than this are shortened when played back. Written into each new file's header, so other players honour it too."
                ) {
                    HStack(spacing: 10) {
                        Toggle("Shorten pauses", isOn: idleEnabled).toggleStyle(.themedCheckbox)
                        if settings.recordingIdleTimeLimit > 0 {
                            Stepper(
                                value: LayoutSettingsBindings.binding(\.recordingIdleTimeLimit), in: 0.5...60, step: 0.5
                            ) {
                                Text("\(Self.seconds(settings.recordingIdleTimeLimit))")
                                    .font(.system(size: 12).monospacedDigit())
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section(title: "While Recording") {
                ToggleRow(
                    label: "Highlight recording panes",
                    help: "Draws a red frame around every pane whose terminal is being recorded.",
                    isOn: LayoutSettingsBindings.binding(\.highlightRecordingPane)
                )
                SettingsRowDivider()
                SettingStack(label: "When a recording stops") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.recordingStopAction)) {
                        ForEach(RecordingStopAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                DescriptionLabel(
                    text:
                        "Start and stop from a pane's ⋯ corner menu or Terminal ▸ Record Session. Terminal ▸ Add Recording Marker (⇧⌘M) drops a chapter mark the player can jump to."
                )
            }

            library(t)
        }
        .foregroundStyle(t.text)
        .task(id: SessionRecorder.recordingsDirectory.path + "\(settings.recordingIdleTimeLimit)") { await reload() }
        .alert(
            "Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $newName)
            Button("Rename") { if let file = renaming { rename(file, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Move “\(pendingDelete?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Move to Trash", role: .destructive) { if let file = pendingDelete { trash(file) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Library

    @ViewBuilder
    private func library(_ t: Tokens) -> some View {
        Section(title: "Library") {
            HStack {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.themed)
                Button {
                    WindowManager.shared.activeController?.openRecordingAction(nil)
                } label: {
                    Label("Open…", systemImage: "play.rectangle")
                }
                .buttonStyle(.themed)
            }
            if recordings.isEmpty, !loading {
                Text("No recordings yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(t.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recordings.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { SettingsRowDivider() }
                        RecordingRow(
                            file: file, dateText: Self.dateFormatter.string(from: file.date),
                            onPlay: { play(file) }, menu: { rowMenu(file) })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ file: RecordingFile) -> some View {
        Button("Play") { play(file) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.url.path, forType: .string)
        }
        Divider()
        Button("Rename…") {
            newName = file.name
            renaming = file
        }
        Button("Move to Trash…", role: .destructive) { pendingDelete = file }
    }

    private var summary: String {
        guard !recordings.isEmpty else { return loading ? "Loading…" : "" }
        let total = recordings.reduce(Int64(0)) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(recordings.count) recording\(recordings.count == 1 ? "" : "s") · \(size)"
    }

    private var templatePreview: String {
        let workspace = WindowManager.shared.activeController?.activeWorkspace
        let fallback = workspace.flatMap { $0.panes[$0.activePaneID]?.activeTab }
        return SessionRecorder.fileName(
            template: AppSettings.shared.recordingFileNameTemplate, title: fallback?.title ?? "zsh",
            directory: fallback?.workingDirectory ?? NSHomeDirectory(), date: Date())
    }

    private var idleEnabled: Binding<Bool> {
        Binding(
            get: { AppSettings.shared.recordingIdleTimeLimit > 0 },
            set: { AppSettings.shared.recordingIdleTimeLimit = $0 ? CastPlayback.defaultIdleLimit : 0 })
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        let dir = SessionRecorder.recordingsDirectory
        let limit = AppSettings.shared.recordingIdleTimeLimit
        let files = await Task.detached(priority: .utility) { RecordingFile.scan(dir, idleLimit: limit) }.value
        recordings = files
        loading = false
    }

    private func play(_ file: RecordingFile) {
        guard let controller = WindowManager.shared.activeController ?? WindowManager.shared.controllers.first
        else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.handleOpenTab(.file(path: file.url.path))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SessionRecorder.recordingsDirectory
        panel.message = "Choose where terminal recordings are saved"
        if panel.runModal() == .OK, let url = panel.url {
            FolderBookmarkStore.shared.save(url)
            AppSettings.shared.recordingsFolder = url.path
        }
    }

    private func rename(_ file: RecordingFile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        let target = file.url.deletingLastPathComponent().appendingPathComponent(trimmed + ".cast")
        do {
            try FileManager.default.moveItem(at: file.url, to: target)
        } catch {
            BooAlert.showError(title: "Couldn't rename recording", message: error.localizedDescription)
        }
        Task { await reload() }
    }

    private func trash(_ file: RecordingFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        } catch {
            BooAlert.showError(title: "Couldn't move recording to the Trash", message: error.localizedDescription)
        }
        Task { await reload() }
    }
}

/// One library row: name, date, length and size, with play and a ⋯ menu.
private struct RecordingRow<MenuContent: View>: View {
    let file: RecordingFile
    let dateText: String
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.tokens) private var t
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(hovered ? t.accent : t.muted)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(hovered ? t.hoverFill : t.subtleFill))
            }
            .buttonStyle(.plain)
            .help("Play")

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(t.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu(content: menu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(t.muted)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? t.subtleFill : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu(menuItems: menu)
    }

    private var details: String {
        var parts = [dateText]
        parts.append(file.duration.map { CastPlayback.formatTime($0) } ?? "unreadable")
        if file.markers > 0 { parts.append("\(file.markers) marker\(file.markers == 1 ? "" : "s")") }
        parts.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
