import SwiftUI

/// Sidebar notes: the workspace note by default, with a menu to switch to the
/// global scratch note or any other workspace's note, and a search across all.
///
/// The host gives each workspace a fresh panel (`NotesPlugin.sectionIdentity`);
/// which note and mode a workspace last showed is kept in the plugin's `NotesPanelMemory`.
struct NotesPanelView: View {
    /// The workspace's own note.
    let path: String
    let title: String
    let memory: NotesPanelMemory
    var fontScale: SidebarFontScale
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    /// Note shown instead of the workspace note; nil shows the workspace note.
    @State private var other: NoteFile?
    @State private var preview: Bool
    @State private var notes: [NoteFile] = []
    @State private var previewRevision = 0
    @State private var searching = false
    @State private var query = ""
    @State private var matches: [NoteMatch] = []
    @FocusState private var searchFocused: Bool

    init(
        path: String, title: String, memory: NotesPanelMemory,
        fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    ) {
        self.path = path
        self.title = title
        self.memory = memory
        self.fontScale = fontScale
        _other = State(initialValue: memory.shown[path])
        _preview = State(initialValue: memory.previewing.contains(path))
    }

    private var currentPath: String { other?.path ?? path }
    private var currentTitle: String { other?.title ?? title }
    private var kind: NoteKind {
        other == nil ? .workspace : currentPath == NotesStore.scratchPath() ? .scratch : .other
    }

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme

        VStack(alignment: .leading, spacing: 0) {
            header(theme: theme)
            if searching {
                searchPanel(theme: theme)
            } else if preview {
                if isEmptyNote {
                    Text("This note is empty.")
                        .font(fontScale.font(.sm))
                        .foregroundStyle(Color(nsColor: theme.chromeMuted))
                        .padding(12)
                } else {
                    NotesPreview(path: currentPath).id("\(currentPath)#\(previewRevision)")
                }
            } else {
                NotesEditor(path: currentPath, placeholder: kind.placeholder(title), memory: memory).id(currentPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: theme.sidebarBg))
        .onAppear(perform: reloadList)
        .onChange(of: other) { _, note in memory.shown[path] = note }
        .onChange(of: preview) { _, on in
            if on { memory.previewing.insert(path) } else { memory.previewing.remove(path) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteAppended)) { note in
            reloadList()
            guard (note.object as? String) == currentPath else { return }
            previewRevision += 1
            NotesStore.editor(for: currentPath)?.reload()
        }
    }

    // MARK: - Header

    private func header(theme: TerminalTheme) -> some View {
        let muted = Color(nsColor: theme.chromeMuted)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                noteMenu(theme: theme)
                Spacer(minLength: 4)
                iconButton(
                    "magnifyingglass", help: searching ? "Close search" : "Search all notes",
                    tint: searching ? Color(nsColor: theme.accentColor) : muted, action: toggleSearch)
                iconButton(
                    preview && !searching ? "pencil" : "eye",
                    help: preview && !searching ? "Edit note" : "Preview note", tint: muted, action: togglePreview)
                iconButton("arrow.up.forward.square", help: "Open note in an editor tab", tint: muted) {
                    let path = currentPath
                    NotesStore.flush(path) {
                        WindowManager.shared.activeController?.openFileInEditor(path: path, line: nil, column: nil)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(kind.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if other != nil {
                    Spacer(minLength: 4)
                    Button("Back to \(title)") { open(nil, line: nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(nsColor: theme.accentColor))
                        .lineLimit(1)
                        .help("Show this workspace's note")
                }
            }
            .font(fontScale.font(.xs))
            .foregroundStyle(muted)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var isEmptyNote: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: currentPath))?[.size] as? Int ?? 0) == 0
    }

    private func noteMenu(theme: TerminalTheme) -> some View {
        let scratch = NotesStore.scratchPath()
        let rest = notes.filter { $0.path != path && $0.path != scratch }
        return Menu {
            SwiftUI.Section("This Workspace") {
                noteButton(NoteFile(path: path, title: title, modified: .distantPast), icon: NoteKind.workspace.icon)
            }
            SwiftUI.Section("Global") {
                noteButton(
                    NoteFile(path: scratch, title: NotesStore.scratchTitle, modified: .distantPast),
                    icon: NoteKind.scratch.icon)
            }
            if !rest.isEmpty {
                SwiftUI.Section("Other Workspaces") {
                    ForEach(rest) { noteButton($0, icon: NoteKind.other.icon) }
                }
            }
            Divider()
            Button("Reveal Notes Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: theme.chromeMuted))
                Text(currentTitle)
                    .font(fontScale.font(.sm).weight(.medium))
                    .foregroundStyle(Color(nsColor: theme.chromeText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(nsColor: theme.chromeMuted))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Switch note — \(abbreviatePath(currentPath))")
        .accessibilityLabel("Note: \(currentTitle). Switch note")
    }

    private func noteButton(_ note: NoteFile, icon: String) -> some View {
        Button {
            open(note.path == path ? nil : note, line: nil)
        } label: {
            Label(note.title, systemImage: note.path == currentPath ? "checkmark" : icon)
        }
    }

    private func iconButton(
        _ symbol: String, help: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        SidebarIconButton(systemName: symbol, help: help, tint: tint, action: action)
    }

    // MARK: - Search

    private func searchPanel(theme: TerminalTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search all notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(fontScale.font(.sm))
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .onAppear { searchFocused = true }
                .onExitCommand(perform: toggleSearch)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { match in
                        Button {
                            open(match.path == path ? nil : notes.first { $0.path == match.path }, line: match.line)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(match.title) · line \(match.line)")
                                    .font(fontScale.font(.xs))
                                    .foregroundStyle(Color(nsColor: theme.chromeMuted))
                                Text(match.text)
                                    .font(fontScale.font(.sm))
                                    .foregroundStyle(Color(nsColor: theme.chromeText))
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No matches")
                            .font(fontScale.font(.sm))
                            .foregroundStyle(Color(nsColor: theme.chromeMuted))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let query = query
            let found = await Task.detached(priority: .userInitiated) { NotesStore.search(query) }.value
            guard !Task.isCancelled else { return }
            matches = found
        }
    }

    // MARK: - Actions

    private func toggleSearch() {
        if searching {
            searching = false
        } else {
            // Search reads files, so save what is being typed first.
            NotesStore.flush(currentPath) {
                reloadList()
                searching = true
            }
        }
    }

    private func togglePreview() {
        if searching {
            searching = false
        } else if preview {
            preview = false
        } else {
            // Preview renders the file, so save what is being typed first.
            NotesStore.flush(currentPath) { preview = true }
        }
    }

    /// Shows `note` (nil = workspace note), optionally at `line`.
    private func open(_ note: NoteFile?, line: Int?) {
        let target = note?.path ?? path
        searching = false
        preview = false
        if let line {
            if target == currentPath, let editor = NotesStore.editor(for: target) {
                editor.reveal(line: line)
            } else {
                memory.pendingLine = line
            }
        }
        other = note
    }

    private func reloadList() {
        // Name every open workspace's note, so the menu lists names, not hashes.
        let open = WindowManager.shared.controllers.flatMap { $0.appState.workspaces }.map {
            (NotesStore.path(workspaceID: $0.id), $0.displayName)
        }
        Task {
            notes = await Task.detached(priority: .userInitiated) {
                NotesStore.rememberTitles(open)
                return NotesStore.list()
            }.value
        }
    }
}

/// Which note each workspace's panel last showed, and whether as preview,
/// keyed by the workspace note path; owned by the plugin, so it outlives the
/// fresh panel each workspace switch makes.
@MainActor
final class NotesPanelMemory {
    var shown: [String: NoteFile] = [:]
    var previewing: Set<String> = []
    /// Line to reveal in the next editor made (a search hit in another note).
    var pendingLine: Int?
}

/// What the shown note is to this workspace.
private enum NoteKind {
    case workspace, scratch, other

    var icon: String {
        switch self {
        case .workspace: "folder"
        case .scratch: "square.and.pencil"
        case .other: "doc.text"
        }
    }

    /// Says whose note is on screen, since the title alone doesn't.
    var caption: String {
        switch self {
        case .workspace: "This workspace's note"
        case .scratch: "Shared by all workspaces"
        case .other: "Another workspace's note"
        }
    }

    func placeholder(_ workspace: String) -> String {
        switch self {
        case .workspace: "Notes for \(workspace). Saved as you type."
        case .scratch: "Scratch note, shared by all workspaces."
        case .other: "Empty note."
        }
    }
}

/// Compact Monaco editor on the note file, autosaving. The panel reloads it
/// when text is appended from elsewhere (palette "Append Selection to Note");
/// the append saves its pending edits first via `NotesStore.flush`.
private struct NotesEditor: NSViewRepresentable {
    let path: String
    let placeholder: String
    let memory: NotesPanelMemory

    func makeNSView(context: Context) -> EditorContentView {
        let view = EditorContentView(filePath: path)
        view.autosave = true
        view.optionOverrides = [
            "lineNumbers": "off",
            "wordWrap": "on",
            "minimap": false,
            "rulers": [Int](),
            "folding": false,
            "glyphMargin": false,
            "placeholder": placeholder
        ]
        if let line = memory.pendingLine {
            memory.pendingLine = nil
            view.reveal(line: line)
        }
        NotesStore.register(view, for: path)
        return view
    }

    func updateNSView(_ view: EditorContentView, context: Context) {}

    static func dismantleNSView(_ view: EditorContentView, coordinator: ()) {
        NotesStore.unregister(view)
        guard view.hasUnsavedChanges else { return view.cleanup() }
        view.saveFile { _ in view.cleanup() }
    }
}

/// Rendered markdown of the saved note.
private struct NotesPreview: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> MarkdownPreviewContentView {
        MarkdownPreviewContentView(filePath: path)
    }

    func updateNSView(_ view: MarkdownPreviewContentView, context: Context) {}

    static func dismantleNSView(_ view: MarkdownPreviewContentView, coordinator: ()) {
        view.cleanup()
    }
}
