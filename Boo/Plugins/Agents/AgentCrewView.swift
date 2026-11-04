import AppKit
import SwiftUI

/// One agent in the app-wide crew list.
struct AgentCrewRow: Identifiable, Equatable {
    let id: UUID
    let handle: String
    let name: String
    let agent: String
    let state: AgentInbox.State
    /// The question, error or last answer, shortened to one line.
    let detail: String?
    let parent: String?
    let queued: Int
    let needsAttention: Bool
    /// Runs on its own worktree: Review, Merge and Discard apply.
    let isTask: Bool
    /// False for a tab in no window of this Boo (another Boo instance, or
    /// a terminal app sharing the socket): it is listed but can't be shown.
    var isReachable = true
    /// A task workspace whose agent no longer runs (Boo restarted, or the agent
    /// quit): the worktree waits for Review, Merge or Discard.
    var isStopped = false
    /// Waits on a question rather than a permission prompt: no Allow / Deny.
    var asksQuestion = false
    /// When the agent last changed state; an answer is only sent for this prompt.
    var updatedAt: Double = 0
    /// A task's commits, changed files and whether it merges.
    var taskStatus: AgentTaskStatus.Summary?

    var key: String {
        "\(id)|\(handle)|\(name)|\(state.rawValue)|\(detail ?? "")|\(parent ?? "")|\(queued)|\(needsAttention)|\(isTask)|\(isReachable)|\(isStopped)|\(asksQuestion)|\(updatedAt)|\(taskStatus?.text ?? "")"
    }
}

/// What the crew list is doing besides listing: the selected row and the
/// inline field or confirmation that is open. Shared by every window's crew
/// list (the crew is app-wide) and kept outside the view, so a sidebar refresh
/// while the user types doesn't lose the text.
@MainActor
final class AgentCrewUIState: ObservableObject {
    static let shared = AgentCrewUIState()

    enum Composer: Equatable {
        /// A message to this agent.
        case message(UUID)
        /// The prompt for a new agent task.
        case newTask
        /// Confirming that this task's worktree is thrown away.
        case discard(UUID)

        /// A text field the keyboard goes to (a discard has only buttons).
        var takesText: Bool { if case .discard = self { false } else { true } }
    }

    @Published var selection: UUID?
    @Published var composer: Composer?
    @Published var text = ""
    /// Shown under the open field: why a start failed, or what a discard loses.
    @Published var note: String?
    /// The discard loses commits or uncommitted changes.
    @Published var noteIsWarning = false
    /// A new task is starting: the field waits for the reply.
    @Published var isBusy = false
    /// The agent a new task starts with: the last one picked, app-wide.
    @Published var taskAgent: AgentKind =
        UserDefaults.standard.string(forKey: "crewTaskAgent").flatMap(AgentKind.init(rawValue:)) ?? .claudeCode
    {
        didSet { UserDefaults.standard.set(taskAgent.rawValue, forKey: "crewTaskAgent") }
    }

    func open(_ composer: Composer) {
        if case .message(let id) = composer { selection = id }
        if case .discard(let id) = composer { selection = id }
        self.composer = composer
        text = ""
        note = nil
        noteIsWarning = false
        isBusy = false
    }

    func close() {
        composer = nil
        text = ""
        note = nil
        isBusy = false
    }

    /// The row after (or before) the selected one, wrapping at neither end.
    static func adjacent(to selection: UUID?, offset: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            return offset >= 0 ? ids.first : ids.last
        }
        return ids[min(ids.count - 1, max(0, index + offset))]
    }
}

/// Every agent in every window, grouped by what it needs from the user:
/// a question or error first, then the ones at work, then finished turns.
/// Behaves like a source list: click or ↑/↓ selects, double-click or Return shows the agent,
/// Space writes it a message, Delete offers to discard a task, Escape closes
/// the open field. Messages, new tasks and discards are typed or confirmed in place,
/// not in dialogs.
struct AgentCrewView: View {
    let rows: [AgentCrewRow]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onJump: (AgentCrewRow) -> Void
    /// Queues a message for the agent (sent when it finishes its turn).
    var onSend: (AgentCrewRow, String) -> Void = { _, _ in }
    let onReview: (AgentCrewRow) -> Void
    let onMerge: (AgentCrewRow) -> Void
    /// Asks what a discard loses; calls back with the text and whether work is lost.
    var onDiscardSummary: (AgentCrewRow, @escaping @MainActor (String, Bool) -> Void) -> Void = { _, _ in }
    /// Discards the task's worktree: the user already confirmed.
    let onDiscard: (AgentCrewRow) -> Void
    /// Starts a task with the prompt and agent; calls back with an error, or nil once it runs.
    var onStartTask: (String, AgentKind, @escaping @MainActor (String?) -> Void) -> Void = { _, _, _ in }
    /// The agents installed on this Mac, in picker order: a new task can start any of them.
    var agents: [AgentKind] = [.claudeCode]
    /// Starts an agent in the active terminal tab (the list is empty).
    var onStartHere: (AgentKind) -> Void = { _ in }
    /// Allow (Return) or Deny (Escape) a permission prompt without opening the tab.
    var onRespond: (AgentCrewRow, AgentInbox.Response) -> Void = { _, _ in }
    /// Restarts a stopped task's agent on its last conversation (`claude --continue`).
    var onResume: (AgentCrewRow) -> Void = { _ in }

    @ObservedObject private var state = AgentCrewUIState.shared
    @State private var hoveredID: UUID?
    @FocusState private var listFocused: Bool
    @FocusState private var fieldFocused: Bool

    private var groups: [(title: String, rows: [AgentCrewRow])] {
        let live = rows.filter { !$0.isStopped }
        let needsYou = live.filter { $0.state == .needsInput || $0.state == .error }
        let working = live.filter { $0.state == .working }
        let done = live.filter { $0.state == .done }
        let stopped = rows.filter(\.isStopped)
        return [("Needs you", needsYou), ("Working", working), ("Done", done), ("Stopped", stopped)]
            .filter { !$0.1.isEmpty }
    }

    /// Rows in the order they show, for the arrow keys.
    private var orderedIDs: [UUID] { groups.flatMap { $0.rows.map(\.id) } }

    private var selectedRow: AgentCrewRow? { rows.first { $0.id == state.selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.title) { group in
                Text("\(group.title) (\(group.rows.count))")
                    .font(fontScale.font(.xs).weight(.semibold))
                    .foregroundStyle(mutedColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(group.rows) { row in
                    crewRow(row)
                    if state.composer == .message(row.id) {
                        composerField(
                            placeholder: "Message \(row.handle)", hint: "↩ send · esc cancel",
                            button: "Send"
                        ) { text in
                            onSend(row, text)
                            state.close()
                        }
                    }
                    if state.composer == .discard(row.id) { discardConfirm(row) }
                }
            }
            if rows.isEmpty && !agents.isEmpty { startHere }
            newTask
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: state.selection = AgentCrewUIState.adjacent(to: state.selection, offset: -1, in: orderedIDs)
            case .down: state.selection = AgentCrewUIState.adjacent(to: state.selection, offset: 1, in: orderedIDs)
            default: break
            }
        }
        .onKeyPress(.return) {
            guard let row = selectedRow, row.isReachable else { return .ignored }
            onJump(row)
            return .handled
        }
        .onKeyPress(.space) {
            guard let row = selectedRow else { return .ignored }
            if row.isStopped {
                if row.isReachable { onResume(row) }
            } else {
                state.open(.message(row.id))
            }
            return .handled
        }
        .onKeyPress(.delete) {
            guard let row = selectedRow, row.isTask, state.composer == nil else { return .ignored }
            state.open(.discard(row.id))
            return .handled
        }
        .onKeyPress(.escape) {
            guard state.composer != nil else { return .ignored }
            state.close()
            return .handled
        }
        .onChange(of: state.composer) { _, composer in
            // The open field takes the keyboard; closing it hands it back to the list.
            if composer?.takesText != true {
                fieldFocused = false
                listFocused = true
            } else {
                fieldFocused = true
            }
        }
    }

    private func taskStatusColor(_ tone: AgentTaskStatus.Summary.Tone) -> Color {
        switch tone {
        case .ready: return Tokens.current.success
        case .blocked: return Tokens.current.warning
        case .neutral: return mutedColor
        }
    }

    private func stateColor(_ state: AgentInbox.State) -> Color {
        switch state {
        case .needsInput: return Tokens.current.warning
        case .error: return Tokens.current.error
        case .working: return accentColor
        case .done: return Tokens.current.success
        }
    }

    /// No agent runs anywhere: start one in this tab, or a task below.
    private var startHere: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No agents running")
                .font(fontScale.font(.sm))
                .foregroundStyle(mutedColor)
            HStack(spacing: 6) {
                ForEach(agents, id: \.self) { kind in
                    Button("Start \(kind.shortName)") { onStartHere(kind) }
                        .help("Start \(kind.displayName) in the active terminal tab")
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Inline fields

    private var newTask: some View {
        Group {
            if state.composer == .newTask {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("New agent task")
                            .font(fontScale.font(.xs).weight(.semibold))
                            .foregroundStyle(mutedColor)
                        Spacer(minLength: 4)
                        if agents.count > 1 { agentPicker }
                    }
                    .padding(.leading, 25)
                    .padding(.trailing, 12)
                    .padding(.top, 8)
                    composerField(
                        placeholder: "What should \(startAgent.shortName) do?",
                        hint: "Own worktree and branch of the active repository · ↩ start",
                        button: "Start"
                    ) { prompt in
                        state.isBusy = true
                        state.note = nil
                        onStartTask(prompt, startAgent) { error in
                            state.isBusy = false
                            if let error {
                                state.note = error
                                state.noteIsWarning = true
                            } else {
                                state.close()
                            }
                        }
                    }
                }
            } else {
                Button(action: { state.open(.newTask) }) {
                    Label("New agent task…", systemImage: "plus")
                        .font(fontScale.font(.sm))
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help("Start an agent on its own worktree of the active workspace's repository")
            }
        }
    }

    /// The picked agent, or the first installed one when it is gone.
    private var startAgent: AgentKind {
        agents.contains(state.taskAgent) ? state.taskAgent : agents.first ?? .claudeCode
    }

    /// Which agent a new task runs, like a terminal's "new tab with…" menu.
    private var agentPicker: some View {
        Picker("Agent", selection: Binding(get: { startAgent }, set: { state.taskAgent = $0 })) {
            ForEach(agents, id: \.self) { Text($0.shortName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .help("The agent this task starts")
    }

    /// A text field in place of a dialog: Return submits, Escape cancels.
    private func composerField(
        placeholder: String, hint: String, button: String, submit: @escaping (String) -> Void
    ) -> some View {
        let send = {
            let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !state.isBusy { submit(text) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            // A plain field in its own box, like the file filter: the bezeled
            // style draws a square system border that clashes with the sidebar.
            TextField(placeholder, text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(fontScale.font(.sm))
                .foregroundStyle(textColor)
                .lineLimit(3...8)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(textColor.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            fieldFocused ? accentColor.opacity(0.7) : mutedColor.opacity(0.25), lineWidth: 1)
                )
                .focused($fieldFocused)
                .disabled(state.isBusy)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    state.close()
                    return .handled
                }
                .onAppear { fieldFocused = true }
            if let note = state.note {
                Text(note)
                    .font(fontScale.font(.xs))
                    .foregroundStyle(state.noteIsWarning ? Tokens.current.error : mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(hint)
                    .font(fontScale.font(.xs))
                    .foregroundStyle(mutedColor.opacity(0.8))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if state.isBusy { ProgressView().controlSize(.mini) }
                Button("Cancel") { state.close() }
                Button(button, action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBusy)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.leading, 13)
        .padding(.vertical, 4)
    }

    private func discardConfirm(_ row: AgentCrewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.note ?? "Checking the worktree…")
                .font(fontScale.font(.xs))
                .foregroundStyle(state.noteIsWarning ? Tokens.current.error : mutedColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { state.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Discard", role: .destructive) {
                    state.close()
                    onDiscard(row)
                }
                .disabled(state.note == nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.leading, 13)
        .padding(.vertical, 4)
        .onAppear {
            onDiscardSummary(row) { text, losesWork in
                guard state.composer == .discard(row.id) else { return }
                state.note = text
                state.noteIsWarning = losesWork
            }
        }
    }

    // MARK: Row

    /// A row action that stays visible on the selected row, not only on hover.
    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(fontScale.font(.sm))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private static func rowHelp(_ row: AgentCrewRow) -> String {
        if !row.isReachable {
            return "Runs in a tab outside Boo's windows, so Boo can't show it. Messages still reach it."
        }
        if row.isStopped {
            return "The agent no longer runs. Resume it, or right-click to review, merge or discard its worktree."
        }
        guard row.state == .needsInput else { return "" }
        return row.asksQuestion
            ? "Double-click to answer its question in its tab." : "Double-click to see the prompt in its tab."
    }

    private func crewRow(_ row: AgentCrewRow) -> some View {
        let isHovered = hoveredID == row.id
        let isSelected = state.selection == row.id
        let showsActions = isHovered || isSelected
        // Click selects (row actions show, arrows and ↩ work); double-click or ↩ jumps,
        // like a Finder or Mail list.
        return Button(action: {
            state.selection = row.id
            listFocused = true
        }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            row.isStopped
                                ? mutedColor.opacity(0.5)
                                : stateColor(row.state).opacity(row.needsAttention || row.state == .working ? 1 : 0.5)
                        )
                        .frame(width: 7, height: 7)
                    Text(row.handle)
                        .font(fontScale.font(.sm).monospaced().weight(.semibold))
                        .foregroundStyle(mutedColor)
                    Text(row.name.isEmpty ? row.agent : row.name)
                        .font(fontScale.font(.base).weight(row.needsAttention ? .semibold : .regular))
                        .foregroundStyle(row.isReachable ? textColor : mutedColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if row.queued > 0 {
                        Text("\(row.queued) queued")
                            .font(fontScale.font(.xs))
                            .foregroundStyle(mutedColor)
                            .help("Messages delivered when this agent finishes its turn")
                    }
                    // Always laid out, only faded in: buttons that appear on hover
                    // would shift the name and the row height under the pointer.
                    Group {
                        if !row.isStopped {
                            rowButton("text.bubble", help: "Message \(row.handle) (Space)") {
                                state.open(.message(row.id))
                            }
                        }
                        if row.isStopped && row.isReachable {
                            rowButton("play.circle", help: "Resume the agent on its last conversation (Space)") {
                                onResume(row)
                            }
                        }
                        if row.isTask {
                            rowButton("plus.forwardslash.minus", help: "Review its changes") { onReview(row) }
                        }
                    }
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                    .accessibilityHidden(!showsActions)
                }
                HStack(spacing: 4) {
                    if !row.isReachable {
                        Text("not in a Boo window ·")
                            .font(fontScale.font(.xs))
                            .foregroundStyle(mutedColor.opacity(0.8))
                    }
                    if let parent = row.parent {
                        Text(row.detail?.isEmpty == false ? "from \(parent) ·" : "from \(parent)")
                            .font(fontScale.font(.xs))
                            .foregroundStyle(mutedColor.opacity(0.8))
                    }
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail)
                            .font(fontScale.font(.xs))
                            .foregroundStyle(mutedColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, 13)
                if let status = row.taskStatus, !status.text.isEmpty {
                    Text(status.text)
                        .font(fontScale.font(.xs))
                        .foregroundStyle(taskStatusColor(status.tone))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 13)
                        .help(status.branch.map { "Branch \($0)" } ?? "")
                }
                if row.state == .needsInput && row.isReachable && !row.asksQuestion {
                    HStack(spacing: 6) {
                        Button("Allow") { onRespond(row, .approve) }
                            .help("Answer the prompt with its default (Return), without opening the tab")
                        Button("Deny") { onRespond(row, .deny) }
                            .help("Decline the prompt (Escape); the agent waits for new instructions")
                    }
                    .controlSize(.small)
                    .padding(.leading, 13)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? accentColor.opacity(listFocused ? 0.28 : 0.16)
                            : isHovered ? accentColor.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.rowHelp(row))
        .simultaneousGesture(TapGesture(count: 2).onEnded { if row.isReachable { onJump(row) } })
        .onHover { hoveredID = $0 ? row.id : (hoveredID == row.id ? nil : hoveredID) }
        .accessibilityLabel("\(row.handle) \(row.name), \(row.isStopped ? "stopped" : row.state.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Show") { onJump(row) }.disabled(!row.isReachable)
            if row.isStopped {
                Button("Resume Agent") { onResume(row) }.disabled(!row.isReachable)
            } else {
                Button("Send Message") { state.open(.message(row.id)) }
            }
            if row.isTask {
                Divider()
                Button("Review Changes") { onReview(row) }
                Button("Merge Worktree…") { onMerge(row) }
                Button("Discard Worktree…") { state.open(.discard(row.id)) }
            }
            if !row.isStopped {
                Divider()
                Button("Copy Handle") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.handle, forType: .string)
                }
            }
        }
    }
}
