import SwiftUI

/// State behind a review tab: the workspace's changes and the comments being
/// collected for the agent.
@MainActor
final class AgentReviewModel: ObservableObject {
    let workspaceID: UUID
    let folder: String
    private weak var controller: MainWindowController?

    @Published private(set) var changes: AgentReview.Changes?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published var selectedPath: String?
    @Published var comments: [AgentReview.Comment] = []
    @Published var note = ""
    /// Line being commented on: file + line number, plus the draft text.
    @Published var draftAnchor: Anchor?
    @Published var draftText = ""
    @Published private(set) var status: String?

    struct Anchor: Equatable {
        let file: String
        let line: Int
        let snippet: String
    }

    init(workspaceID: UUID, folder: String, controller: MainWindowController?) {
        self.workspaceID = workspaceID
        self.folder = folder
        self.controller = controller
    }

    var isWorktree: Bool { changes?.branch != nil && AgentWorktree.looksLikeWorktree(folder) }

    var selectedFile: AgentReview.FileDiff? {
        changes?.files.first { $0.path == selectedPath } ?? changes?.files.first
    }

    func reload() {
        isLoading = true
        let folder = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AgentReview.changes(in: folder) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let changes):
                    self.changes = changes
                    self.error = nil
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
        draftText = ""
    }

    func commitDraft() {
        guard let anchor = draftAnchor else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            comments.append(.init(file: anchor.file, line: anchor.line, snippet: anchor.snippet, text: text))
        }
        draftAnchor = nil
        draftText = ""
    }

    func comments(file: String, line: Int) -> [AgentReview.Comment] {
        comments.filter { $0.file == file && $0.line == line }
    }

    var canSend: Bool {
        !comments.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        commitDraft()
        guard canSend, let controller else { return }
        let text = AgentReview.compose(comments, note: note)
        if controller.sendToAgent(workspaceID: workspaceID, text: text) {
            comments = []
            note = ""
            status = nil
        } else {
            status = "No terminal tab in this workspace to send to."
        }
    }

    func merge() { controller?.mergeAgentTask(workspaceID: workspaceID) }
    func discard() { controller?.discardAgentTask(workspaceID: workspaceID) }
}

/// Review tab: changed files on the left, the selected file's diff on the right.
/// Click a line to comment; "Send to Agent" pastes every comment into the
/// agent's prompt.
struct AgentReviewView: View {
    @ObservedObject var model: AgentReviewModel

    private var t: Tokens { Tokens(theme: AppSettings.shared.theme) }
    private var mono: Font {
        .custom(AppSettings.shared.editorFontName, size: max(10, CGFloat(AppSettings.shared.editorFontSize) - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.separator).frame(height: 1)
            if let error = model.error {
                placeholder(error)
            } else if let changes = model.changes, changes.files.isEmpty {
                placeholder("No changes against \(changes.base).")
            } else if model.changes == nil {
                placeholder("Loading changes…")
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 240)
                    Rectangle().fill(t.separator).frame(width: 1)
                    diffPane
                }
            }
            Rectangle().fill(t.separator).frame(height: 1)
            footer
        }
        .background(t.chromeBg)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.changes?.branch ?? (model.folder as NSString).lastPathComponent)
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
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Refresh") { model.reload() }
            if model.isWorktree {
                Button("Merge…") { model.merge() }
                Button("Discard…") { model.discard() }
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
            TextField("Overall note for the agent (optional)", text: $model.note)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.send() }
            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(t.color(\.error))
            }
            Button("Send to Agent") { model.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend && model.draftAnchor == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(t.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: File list

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.changes?.files ?? []) { file in
                    fileRow(file)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func fileRow(_ file: AgentReview.FileDiff) -> some View {
        let selected = model.selectedFile?.path == file.path
        let commentCount = model.comments.filter { $0.file == file.path }.count
        return Button {
            model.selectedPath = file.path
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
                if !file.isBinary {
                    Text("+\(file.additions)").foregroundStyle(t.color(\.success))
                    Text("−\(file.deletions)").foregroundStyle(t.color(\.error))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? t.color(\.accentSelectionFill) : .clear)
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
        case .modified, .renamed: return t.color(\.warning)
        case .added: return t.color(\.success)
        case .deleted: return t.color(\.error)
        }
    }

    // MARK: Diff

    private var diffPane: some View {
        Group {
            if let file = model.selectedFile {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let old = file.oldPath {
                            Text("Renamed from \(old)").font(.system(size: 11)).foregroundStyle(t.textSecondary)
                                .padding(8)
                        }
                        if file.isBinary {
                            Text("Binary file").font(.system(size: 11)).foregroundStyle(t.textSecondary).padding(8)
                        }
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header)
                                .font(mono).foregroundStyle(t.textTertiary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(t.subtleFill)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                lineRow(line, file: file.path)
                            }
                        }
                    }
                    .frame(minWidth: 600, alignment: .leading)
                }
                .id(file.path)
            } else {
                placeholder("Select a file")
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: AgentReview.DiffLine, file: String) -> some View {
        let number = line.newLine ?? line.oldLine ?? 0
        HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(line.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(marker(line.kind)).frame(width: 18)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(t.text)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(mono)
        .foregroundStyle(t.textTertiary)
        .padding(.vertical, 0.5)
        .background(lineBackground(line.kind))
        .contentShape(Rectangle())
        .onTapGesture { model.beginComment(file: file, line: line) }
        .help("Click to comment on this line")

        ForEach(model.comments(file: file, line: number)) { comment in
            commentBubble(comment)
        }
        if let anchor = model.draftAnchor, anchor.file == file, anchor.line == number,
            anchor.snippet == line.text
        {
            draftEditor
        }
    }

    private func marker(_ kind: AgentReview.DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private func lineBackground(_ kind: AgentReview.DiffLine.Kind) -> Color {
        switch kind {
        // Deliberate raw alpha: diff tints sit between subtle and hover bands.
        case .added: return t.color(\.success).opacity(0.12)
        case .removed: return t.color(\.error).opacity(0.12)
        case .context: return .clear
        }
    }

    private func commentBubble(_ comment: AgentReview.Comment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").foregroundStyle(t.accent)
            Text(comment.text).font(.system(size: 12)).foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.comments.removeAll { $0.id == comment.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(t.textTertiary)
        }
        .padding(8)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
        .padding(.leading, 98).padding(.vertical, 3)
    }

    private var draftEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Comment for the agent", text: $model.draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .onSubmit { model.commitDraft() }
            HStack {
                Button("Cancel") { model.draftAnchor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add Comment") { model.commitDraft() }
            }
        }
        .padding(8)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
        .padding(.leading, 98).padding(.vertical, 3)
    }
}
