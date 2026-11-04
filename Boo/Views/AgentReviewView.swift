import AppKit
import SwiftUI

/// State behind a diff tab: an agent review (the workspace's changes and the
/// comments being collected for the agent), or the Git panel's staged or
/// unstaged changes, read only.
@MainActor
final class AgentReviewModel: ObservableObject {
    let workspaceID: UUID
    let folder: String
    let source: AgentReview.Source
    /// This tab's layout and wrap: start from the Git settings, flipped per tab.
    @Published var layout = DiffSettings.layout
    @Published var wrap = DiffSettings.wrap

    @Published private(set) var changes: AgentReview.Changes?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorktree = false
    @Published var selectedPath: String?
    @Published private(set) var comments: [AgentReview.Comment] = [] {
        didSet { indexComments() }
    }
    /// Line being commented on: file + line number.
    @Published var draftAnchor: Anchor?
    @Published private(set) var status: String?
    /// Typed text lives in its own objects so a keystroke re-renders only the
    /// field, not the whole diff observing this model.
    let note = TextBox()
    let draft = TextBox()
    /// Comments by file, then line, so diff rows don't filter every comment.
    private var commentIndex: [String: [Int: [AgentReview.Comment]]] = [:]

    final class TextBox: ObservableObject {
        @Published var text = ""
    }

    struct Anchor: Equatable {
        let file: String
        let line: Int
        let snippet: String
    }

    init(workspaceID: UUID, folder: String, source: AgentReview.Source = .branch, selectedPath: String? = nil) {
        self.workspaceID = workspaceID
        self.folder = folder
        self.source = source
        self.selectedPath = selectedPath
        Self.open.setObject(self, forKey: Self.key(folder: folder, source: source) as NSString)
    }

    /// Comments and "Send to Agent" apply to an agent review only.
    var isReview: Bool { source == .branch }

    /// Open git diff tabs, so a second click selects the file in the same tab.
    private static let open = NSMapTable<NSString, AgentReviewModel>.strongToWeakObjects()

    static func key(folder: String, source: AgentReview.Source) -> String { "\(source)|\(folder)" }

    static func existing(folder: String, source: AgentReview.Source) -> AgentReviewModel? {
        open.object(forKey: key(folder: folder, source: source) as NSString)
    }

    /// Moves the selection by `offset` files (arrow keys in the file list).
    func selectAdjacent(_ offset: Int) {
        guard let files = changes?.files, !files.isEmpty else { return }
        let current = files.firstIndex { $0.path == selectedFile?.path } ?? 0
        selectedPath = files[min(files.count - 1, max(0, current + offset))].path
    }

    /// Looked up per action: the workspace may have moved to another window.
    private var controller: MainWindowController? {
        WindowManager.shared.controller(owningWorkspace: workspaceID)
    }

    var selectedFile: AgentReview.FileDiff? {
        changes?.files.first { $0.path == selectedPath } ?? changes?.files.first
    }

    func reload() {
        isLoading = true
        let folder = folder
        let source = source
        let context = DiffSettings.context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AgentReview.changes(in: folder, source: source, context: context) }
            let isWorktree = (try? result.get())?.branch != nil && AgentWorktree.looksLikeWorktree(folder)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let changes):
                    self.changes = changes
                    self.error = nil
                    self.isWorktree = isWorktree
                    if !changes.files.contains(where: { $0.path == self.selectedPath }) {
                        self.selectedPath = changes.files.first?.path
                    }
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func beginComment(file: String, line: AgentReview.DiffLine) {
        guard let number = line.newLine ?? line.oldLine else { return }
        draftAnchor = Anchor(file: file, line: number, snippet: line.text)
        draft.text = ""
    }

    func commitDraft() {
        guard let anchor = draftAnchor else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            comments.append(.init(file: anchor.file, line: anchor.line, snippet: anchor.snippet, text: text))
        }
        draftAnchor = nil
        draft.text = ""
    }

    func removeComment(_ id: AgentReview.Comment.ID) {
        comments.removeAll { $0.id == id }
    }

    func comments(file: String, line: Int) -> [AgentReview.Comment] {
        commentIndex[file]?[line] ?? []
    }

    func commentCount(file: String) -> Int {
        commentIndex[file]?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    private func indexComments() {
        var index: [String: [Int: [AgentReview.Comment]]] = [:]
        for comment in comments { index[comment.file, default: [:]][comment.line, default: []].append(comment) }
        commentIndex = index
    }

    var canSend: Bool {
        !comments.isEmpty || !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        commitDraft()
        guard canSend, let controller else { return }
        let text = AgentReview.compose(comments, note: note.text)
        if controller.sendToAgent(workspaceID: workspaceID, text: text) {
            comments = []
            note.text = ""
            status = nil
        } else {
            status = "No terminal tab in this workspace to send to."
        }
    }

    func merge() { controller?.mergeAgentTask(workspaceID: workspaceID) }
    func discard() { controller?.discardAgentTask(workspaceID: workspaceID) }
}

/// Diff tab: changed files on the left, the selected file's diff on the right,
/// unified or side by side. In an agent review, click a line to comment;
/// "Send to Agent" pastes every comment into the agent's prompt.
struct AgentReviewView: View {
    @ObservedObject var model: AgentReviewModel
    /// Repaints on editor-font changes; the theme comes from the tab host.
    @StateObject private var settings = SettingsObserver(topics: [.editor])
    @Environment(\.tokens) private var t
    @FocusState private var fileListFocused: Bool

    private var fontSize: CGFloat { max(10, CGFloat(AppSettings.shared.editorFontSize) - 1) }
    private var mono: Font { .custom(AppSettings.shared.editorFontName, size: fontSize) }
    /// One character of the editor font, to size unwrapped side-by-side columns.
    private var charWidth: CGFloat {
        let font =
            NSFont(name: AppSettings.shared.editorFontName, size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    var body: some View {
        let _ = settings.revision
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.separator).frame(height: 1)
            if let error = model.error {
                placeholder(error)
            } else if let changes = model.changes, changes.files.isEmpty {
                placeholder(emptyText(changes))
            } else if model.changes == nil {
                placeholder("Loading changes…")
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 240)
                    Rectangle().fill(t.separator).frame(width: 1)
                    diffPane
                }
            }
            if model.isReview {
                Rectangle().fill(t.separator).frame(height: 1)
                footer
            }
        }
        .background(t.termBg)
    }

    private func emptyText(_ changes: AgentReview.Changes) -> String {
        switch model.source {
        case .branch: return "No changes against \(changes.base)."
        case .unstaged: return "No unstaged changes."
        case .staged: return "Nothing staged."
        }
    }

    // MARK: Header / footer

    private var title: String {
        let repo = (model.folder as NSString).lastPathComponent
        switch model.source {
        case .branch: return model.changes?.branch ?? repo
        case .unstaged: return "Unstaged changes in \(repo)"
        case .staged: return "Staged changes in \(repo)"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
                if let changes = model.changes {
                    let adds = changes.files.reduce(0) { $0 + $1.additions }
                    let dels = changes.files.reduce(0) { $0 + $1.deletions }
                    Text(
                        "\(changes.files.count) file\(changes.files.count == 1 ? "" : "s") changed against \(changes.base)  +\(adds) −\(dels)"
                    )
                    .font(.system(size: 11)).foregroundStyle(t.textSecondary)
                }
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small).tint(t.textSecondary) }
            Picker("Layout", selection: $model.layout) {
                Image(systemName: "rectangle").help("Unified").tag(DiffLayout.unified)
                Image(systemName: "rectangle.split.2x1").help("Side by side").tag(DiffLayout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Unified or side by side, for this tab (default in Settings › Git)")
            Toggle(isOn: $model.wrap) {
                Image(systemName: "arrow.turn.down.left")
            }
            .toggleStyle(.button)
            .help("Wrap long lines, for this tab (default in Settings › Git)")
            Button("Refresh") { model.reload() }.buttonStyle(.themed)
                .keyboardShortcut("r", modifiers: .command)
            if model.isWorktree {
                Button("Merge…") { model.merge() }.buttonStyle(.themed)
                Button("Discard…") { model.discard() }.buttonStyle(.themed)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var commentSummary: String {
        let count = model.comments.count
        return count == 0 ? "Click a line to comment" : "\(count) comment\(count == 1 ? "" : "s")"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(commentSummary)
                .font(.system(size: 11)).foregroundStyle(t.textSecondary)
            NoteField(model: model, note: model.note)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Note field and Send button: the only views observing the note text.
    private struct NoteField: View {
        @ObservedObject var model: AgentReviewModel
        @ObservedObject var note: AgentReviewModel.TextBox
        @Environment(\.tokens) private var t

        var body: some View {
            TextField("Overall note for the agent (optional)", text: $note.text)
                .themedTextField()
                .onSubmit { model.send() }
            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(t.error)
            }
            Button("Send to Agent") { model.send() }
                .buttonStyle(.themedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend && model.draftAnchor == nil)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(t.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: File list

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.changes?.files ?? []) { file in
                        fileRow(file).id(file.path)
                    }
                }
                .padding(.vertical, 4)
            }
            // ↑/↓ walk the files like a source list.
            .focusable()
            .focused($fileListFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: model.selectAdjacent(-1)
                case .down: model.selectAdjacent(1)
                default: break
                }
            }
            .onChange(of: model.selectedFile?.path) { _, path in
                if let path { proxy.scrollTo(path) }
            }
            .onAppear {
                fileListFocused = true
                if let path = model.selectedFile?.path { proxy.scrollTo(path, anchor: .center) }
            }
        }
    }

    private func fileRow(_ file: AgentReview.FileDiff) -> some View {
        let selected = model.selectedFile?.path == file.path
        let commentCount = model.commentCount(file: file.path)
        return Button {
            model.selectedPath = file.path
            fileListFocused = true
        } label: {
            HStack(spacing: 6) {
                Text(statusLetter(file.status))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 12)).foregroundStyle(t.text).lineLimit(1)
                    let dir = (file.path as NSString).deletingLastPathComponent
                    if !dir.isEmpty {
                        Text(dir).font(.system(size: 10)).foregroundStyle(t.textTertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if commentCount > 0 {
                    Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(t.accent)
                }
                diffStat(file)
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? t.accentSelectionFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusLetter(_ status: AgentReview.FileDiff.Status) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        }
    }

    private func statusColor(_ status: AgentReview.FileDiff.Status) -> Color {
        switch status {
        case .modified, .renamed: return t.warning
        case .added: return t.success
        case .deleted: return t.error
        }
    }

    // MARK: Diff

    private static let markerWidth: CGFloat = 18

    /// Line-number columns: an added file has no old side, a deleted one no new side.
    private struct Columns {
        var old = true
        var new = true
        /// One number column, wide enough for the file's largest line number.
        var number: CGFloat
        /// Numbers plus marker: where a line's text starts.
        var inset: CGFloat { (old ? number : 0) + (new ? number : 0) + AgentReviewView.markerWidth }
    }

    private func columns(for file: AgentReview.FileDiff, charWidth: CGFloat) -> Columns {
        let largest = file.hunks.lazy.flatMap(\.lines).map { max($0.oldLine ?? 0, $0.newLine ?? 0) }.max() ?? 0
        return Columns(
            old: file.status != .added, new: file.status != .deleted,
            number: CGFloat(max(3, String(largest).count)) * charWidth + 12)
    }

    private var diffPane: some View {
        Group {
            if let file = model.selectedFile {
                VStack(spacing: 0) {
                    fileHeader(file)
                    Rectangle().fill(t.separator).frame(height: 1)
                    if file.isBinary {
                        placeholder("Binary file, not shown")
                    } else if file.hunks.isEmpty {
                        placeholder("No content changes")
                    } else {
                        diffBody(file)
                    }
                }
                .id(file.path)
            } else {
                placeholder("Select a file")
            }
        }
    }

    private func fileHeader(_ file: AgentReview.FileDiff) -> some View {
        HStack(spacing: 8) {
            Text(statusLetter(file.status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(file.status))
            Text(file.path)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(t.text)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            if let old = file.oldPath {
                Text("from \(old)")
                    .font(.system(size: 11)).foregroundStyle(t.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { diffStat(file) }
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// "+12 −3", zeros dimmed.
    @ViewBuilder
    private func diffStat(_ file: AgentReview.FileDiff) -> some View {
        if !file.isBinary {
            Text("+\(file.additions)").foregroundStyle(file.additions == 0 ? t.textTertiary : t.success)
            Text("−\(file.deletions)").foregroundStyle(file.deletions == 0 ? t.textTertiary : t.error)
        }
    }

    private func diffBody(_ file: AgentReview.FileDiff) -> some View {
        // A whole added or deleted file has nothing to stand beside.
        let oneSided = file.status == .added || file.status == .deleted
        let split = model.layout == .split && !oneSided
        let charWidth = charWidth
        let columns = columns(for: file, charWidth: charWidth)
        // Each side of a split shows one number column.
        let side = Columns(old: false, new: true, number: columns.number)
        // A whole file's one hunk header says nothing the file header doesn't.
        let showHunkHeaders = !(oneSided && file.hunks.count == 1)
        return GeometryReader { geometry in
            // Unwrapped, each side is as wide as the file's longest line.
            let longest = file.hunks.lazy.flatMap(\.lines).map(\.text.count).max() ?? 0
            let sideWidth = max((geometry.size.width - 1) / 2, CGFloat(longest) * charWidth + side.inset + 8)
            ScrollView(model.wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One lazy child per hunk: flattening header and lines into the
                    // lazy stack gave them colliding index ids, and line 1 vanished.
                    ForEach(file.hunks.indices, id: \.self) { h in
                        let hunk = file.hunks[h]
                        VStack(alignment: .leading, spacing: 0) {
                            if showHunkHeaders { hunkHeader(hunk.header) }
                            if split {
                                let rows = AgentReview.splitRows(hunk.lines)
                                ForEach(rows.indices, id: \.self) { i in
                                    splitRow(
                                        rows[i], file: file.path, side: side,
                                        sideWidth: model.wrap ? nil : sideWidth)
                                }
                            } else {
                                ForEach(hunk.lines.indices, id: \.self) { i in
                                    lineRow(hunk.lines[i], file: file.path, columns: columns)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(
                    minWidth: geometry.size.width,
                    maxWidth: model.wrap ? geometry.size.width : nil,
                    alignment: .leading)
            }
            // A short diff otherwise floats in the middle of the pane.
            .defaultScrollAnchor(.topLeading)
        }
    }

    /// "@@ -12,5 +14,7 @@ func name()": the range dimmed, the enclosing scope readable.
    private func hunkHeader(_ header: String) -> some View {
        var range = header
        var scope = ""
        if let end = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) {
            range = String(header[..<end.upperBound])
            scope = header[end.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return HStack(spacing: 12) {
            Text(range).foregroundStyle(t.textTertiary)
            Text(scope).foregroundStyle(t.textSecondary)
        }
        .font(mono)
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.accent.opacity(0.08))
    }

    private func lineText(_ line: AgentReview.DiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .foregroundStyle(t.text)
            .fixedSize(horizontal: !model.wrap, vertical: true)
            .frame(maxWidth: model.wrap ? .infinity : nil, alignment: .leading)
            .padding(.leading, 4)
    }

    /// Line numbers and the +/− marker, tinted a shade deeper than the line.
    private func gutter(_ numbers: [Int?], kind: AgentReview.DiffLine.Kind?, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(numbers.indices, id: \.self) { i in
                Text(numbers[i].map(String.init) ?? "")
                    .padding(.trailing, 6)
                    .frame(width: width, alignment: .trailing)
            }
            Text(kind.map(marker) ?? "")
                .foregroundStyle(markerColor(kind))
                .frame(width: Self.markerWidth)
        }
        .foregroundStyle(t.textTertiary)
        .frame(maxHeight: .infinity, alignment: .top)
        // Over the line's own tint, so a changed line's numbers read a shade deeper.
        .background(kind.map(lineBackground) ?? .clear)
    }

    @ViewBuilder
    private func lineRow(_ line: AgentReview.DiffLine, file: String, columns: Columns) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(
                (columns.old ? [line.oldLine] : []) + (columns.new ? [line.newLine] : []),
                kind: line.kind, width: columns.number)
            lineText(line)
            Spacer(minLength: 0)
        }
        .font(mono)
        .fixedSize(horizontal: false, vertical: true)
        .background(lineBackground(line.kind))
        .contentShape(Rectangle())
        .onTapGesture { if model.isReview { model.beginComment(file: file, line: line) } }
        .help(model.isReview ? "Click to comment on this line" : "")
        annotations(line, file: file, inset: columns.inset)
    }

    /// Old line left, new line right; `sideWidth` nil wraps each side to half the pane.
    @ViewBuilder
    private func splitRow(
        _ row: AgentReview.SplitRow, file: String, side: Columns, sideWidth: CGFloat?
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            splitSide(row.left, number: row.left?.oldLine, file: file, side: side, width: sideWidth)
            Rectangle().fill(t.separator).frame(width: 1)
            splitSide(row.right, number: row.right?.newLine, file: file, side: side, width: sideWidth)
        }
        // Both sides as tall as the taller one, so the tints line up when wrapped.
        .fixedSize(horizontal: false, vertical: true)
        if let left = row.left { annotations(left, file: file, inset: side.inset) }
        if let right = row.right, right != row.left { annotations(right, file: file, inset: side.inset) }
    }

    private func splitSide(
        _ line: AgentReview.DiffLine?, number: Int?, file: String, side: Columns, width: CGFloat?
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gutter([number], kind: line?.kind, width: side.number)
            if let line { lineText(line) }
            Spacer(minLength: 0)
        }
        .font(mono)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
        .background(line.map { lineBackground($0.kind) } ?? t.subtleFill)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isReview, let line { model.beginComment(file: file, line: line) }
        }
        .help(model.isReview && line != nil ? "Click to comment on this line" : "")
    }

    /// Comments on a line and the comment being written there.
    @ViewBuilder
    private func annotations(_ line: AgentReview.DiffLine, file: String, inset: CGFloat) -> some View {
        if model.isReview {
            let number = line.newLine ?? line.oldLine ?? 0
            ForEach(model.comments(file: file, line: number)) { comment in
                commentBubble(comment, inset: inset)
            }
            if let anchor = model.draftAnchor, anchor.file == file, anchor.line == number,
                anchor.snippet == line.text
            {
                draftEditor(inset: inset)
            }
        }
    }

    private func marker(_ kind: AgentReview.DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private func markerColor(_ kind: AgentReview.DiffLine.Kind?) -> Color {
        switch kind {
        case .added: return t.success
        case .removed: return t.error
        case .context, nil: return t.textTertiary
        }
    }

    private func lineBackground(_ kind: AgentReview.DiffLine.Kind) -> Color {
        switch kind {
        // Deliberate raw alpha: diff tints sit between subtle and hover bands.
        case .added: return t.success.opacity(0.12)
        case .removed: return t.error.opacity(0.12)
        case .context: return .clear
        }
    }

    private func commentBubble(_ comment: AgentReview.Comment, inset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").foregroundStyle(t.accent)
            Text(comment.text).font(.system(size: 12)).foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.removeComment(comment.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(t.textTertiary)
        }
        .padding(8)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
        .padding(.leading, inset + 4).padding(.vertical, 3)
    }

    private func draftEditor(inset: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            DraftField(draft: model.draft) { model.commitDraft() }
            HStack {
                Button("Cancel") { model.draftAnchor = nil }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button("Add Comment") { model.commitDraft() }
                    .buttonStyle(.themedProminent)
            }
        }
        .padding(8)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
        .padding(.leading, inset + 4).padding(.vertical, 3)
    }

    /// Only this field observes the draft text.
    private struct DraftField: View {
        @ObservedObject var draft: AgentReviewModel.TextBox
        let submit: () -> Void

        var body: some View {
            TextField("Comment for the agent", text: $draft.text, axis: .vertical)
                .themedTextField()
                .lineLimit(2...6)
                .onSubmit(submit)
        }
    }
}
