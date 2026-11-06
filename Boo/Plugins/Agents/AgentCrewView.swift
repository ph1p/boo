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
    /// The agent's working folder, for the line under the name.
    var folder: String?
    /// The workspace whose tab runs the agent; nil outside Boo's windows.
    var workspace: CrewWorkspace?
    /// Reports through Boo's hooks. False for an agent found only by its
    /// process: no handle, no messages, its state a guess.
    var hasHooks = true

    var key: String {
        "\(id)|\(handle)|\(name)|\(state.rawValue)|\(detail ?? "")|\(parent ?? "")|\(queued)|\(needsAttention)|\(isTask)|\(isReachable)|\(isStopped)|\(asksQuestion)|\(updatedAt)|\(taskStatus?.text ?? "")|\(folder ?? "")|\(workspace?.key ?? "")|\(hasHooks)"
    }
}

/// The workspace a crew row runs in: the crew list groups rows by it.
struct CrewWorkspace: Equatable, Hashable {
    let id: UUID
    let name: String
    /// A task worktree's workspace, not one the user opened.
    var isTask = false
    /// Its position across windows and their workspace bars, for the group order.
    var order = 0
    var color: NSColor?

    var key: String { "\(id)|\(name)|\(isTask)|\(order)|\(color?.description ?? "")" }
}

/// What the crew list is doing besides listing: the selected row, the
/// collapsed workspace groups and the inline field or confirmation that is
/// open. Shared by every window's crew list (the crew is app-wide) and kept
/// outside the view, so a sidebar refresh while the user types doesn't lose the text.
@MainActor
final class AgentCrewUIState: ObservableObject {
    static let shared = AgentCrewUIState()

    enum Composer: Hashable {
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
    /// Unsent text of fields that closed without sending, by field. A click
    /// elsewhere closes the field but keeps what was typed for the next open.
    private(set) var drafts: [Composer: String] = [:]
    /// Shown under the open field: why a start failed, or what a discard loses.
    @Published var note: String?
    /// The discard loses commits or uncommitted changes.
    @Published var noteIsWarning = false
    /// A new task is starting: the field waits for the reply.
    @Published var isBusy = false
    /// Workspace groups the user folded (`CrewGroup.id`), for this run of Boo.
    @Published var collapsedGroups: Set<String> = []
    /// The new-agent form shows in the header's popover, not in the list.
    @Published var newTaskInPopover = false
    /// The agent a new task starts with: the last one picked, app-wide.
    @Published var taskAgent: AgentKind =
        UserDefaults.standard.string(forKey: "crewTaskAgent").flatMap(AgentKind.init(rawValue:)) ?? .claudeCode
    {
        didSet { UserDefaults.standard.set(taskAgent.rawValue, forKey: "crewTaskAgent") }
    }

    /// Where a new agent starts.
    enum Place: String {
        /// A new terminal tab in the active workspace; the prompt is optional.
        case tab
        /// Its own worktree and branch of the active repository.
        case worktree
    }

    /// Where the next new agent starts: the last one picked, app-wide.
    @Published var taskPlace: Place =
        UserDefaults.standard.string(forKey: "crewTaskPlace").flatMap(Place.init(rawValue:)) ?? .tab
    {
        didSet { UserDefaults.standard.set(taskPlace.rawValue, forKey: "crewTaskPlace") }
    }

    /// Opens the new-agent popover under the crew list's "New Agent" button in
    /// the key window; false when none shows (the form then opens in the list).
    static var presentNewTask: @MainActor () -> Bool = { AgentNewTaskAnchorView.present() }

    func open(_ composer: Composer) {
        if case .message(let id) = composer { selection = id }
        if case .discard(let id) = composer { selection = id }
        stashDraft()
        self.composer = composer
        text = drafts.removeValue(forKey: composer) ?? ""
        note = nil
        noteIsWarning = false
        isBusy = false
        // `perform(.newTask)` and the "New Agent" button land here: show the
        // popover under the button.
        if composer == .newTask, !newTaskInPopover, self === Self.shared { _ = Self.presentNewTask() }
    }

    /// Closes the open field and keeps its unsent text as a draft.
    func close() {
        stashDraft()
        composer = nil
        text = ""
        note = nil
        isBusy = false
        // Closing from elsewhere (a keypress, another composer) takes the popover too.
        if newTaskInPopover, self === Self.shared { AgentNewTaskPopover.dismiss() }
    }

    /// Closes the open field and drops its text: the user cancelled it, or it was sent.
    func cancel() {
        if let composer { drafts[composer] = nil }
        text = ""
        close()
    }

    /// Drops a closed field's draft (a new task that started after its form closed).
    func dropDraft(_ composer: Composer) {
        if self.composer == composer { text = "" }
        drafts[composer] = nil
    }

    /// Keeps the open field's text for the next time it opens; empty text drops the draft.
    private func stashDraft() {
        guard let composer, composer.takesText else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[composer] = trimmed.isEmpty ? nil : text
    }

    /// Folds or unfolds a workspace group; a folded group drops the selection
    /// it hides, so the keys never act on a row that isn't shown.
    func setCollapsed(_ group: CrewGroup, _ collapsed: Bool) {
        if collapsed {
            collapsedGroups.insert(group.id)
            if group.rows.contains(where: { $0.id == selection }) { selection = nil }
        } else {
            collapsedGroups.remove(group.id)
        }
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

/// The agents of one workspace in the crew list.
struct CrewGroup: Identifiable {
    /// The workspace's ID, or `CrewGroup.outsideID` for agents outside Boo's windows.
    let id: String
    let workspace: CrewWorkspace?
    /// The window's active workspace: listed first.
    let isActive: Bool
    /// Live agents as a tree, then stopped tasks.
    let entries: [(row: AgentCrewRow, depth: Int)]

    static let outsideID = "outside"

    var title: String { workspace?.name ?? "Outside Boo" }
    var rows: [AgentCrewRow] { entries.map(\.row) }
    /// Some live agent waits on the user: shown on a folded header.
    var needsYou: Bool { rows.contains(where: AgentCrewView.needsYou) }
}

/// Every agent in every window, grouped by workspace in workspace-bar order,
/// then agents outside Boo. In a group,
/// each helper sits under the agent that started it, stopped tasks last.
/// Behaves like a sidebar: a click selects and shows the agent, ↑/↓ selects, Return shows it,
/// Space writes it a message, Delete offers to discard a task, Escape closes
/// the open field. Messages and discards are typed or confirmed in place; a new
/// agent starts from the list header's "+" popover (`AgentNewTaskPopover`).
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
    /// Starts an agent in a new terminal tab, with the prompt when one was typed.
    var onStartHere: (AgentKind, String) -> Void = { _, _ in }
    /// Allow (Return) or Deny (Escape) a permission prompt without opening the tab.
    var onRespond: (AgentCrewRow, AgentInbox.Response) -> Void = { _, _ in }
    /// Restarts a stopped task's agent on its last conversation (`claude --continue`).
    var onResume: (AgentCrewRow) -> Void = { _ in }
    /// Agent sessions by tab, for the Timeline, Transcript and Session ID menu items.
    var sessions: [UUID: AgentSession] = [:]
    var onShowTimeline: (AgentCrewRow, AgentSession) -> Void = { _, _ in }
    var onOpenTranscript: (String) -> Void = { _ in }
    /// This window's active workspace: its group comes first.
    var activeWorkspaceID: UUID?
    /// Its name, for where a new agent starts and the empty state.
    var activeWorkspaceName: String?
    /// Lists only the active workspace's agents; a footer counts the rest.
    /// `rows` still holds every agent.
    var activeOnly = false
    /// Lists every workspace again (the footer and a group's menu).
    var onShowAll: () -> Void = {}
    /// Lists only the active workspace (a group's menu).
    var onShowActiveOnly: () -> Void = {}

    @ObservedObject private var state = AgentCrewUIState.shared
    @State private var hoveredID: UUID?
    @State private var hoveredGroup: String?
    @FocusState private var listFocused: Bool
    @FocusState private var fieldFocused: Bool

    // MARK: Grouping

    /// Waits on the user: a prompt, a question or an error. An agent without
    /// hooks is left out: its state is a guess from its process.
    nonisolated static func needsYou(_ row: AgentCrewRow) -> Bool {
        !row.isStopped && row.hasHooks && (row.state == .needsInput || row.state == .error)
    }

    /// Rows by workspace in workspace-bar `order`, then agents outside Boo; the
    /// active workspace keeps its place. Each group lists its live agents as a tree, then stopped ones.
    static func groups(_ rows: [AgentCrewRow], activeWorkspaceID: UUID?) -> [CrewGroup] {
        var byID: [String: [AgentCrewRow]] = [:]
        var workspaces: [String: CrewWorkspace] = [:]
        var firstSeen: [String] = []
        for row in rows {
            let id = row.workspace?.id.uuidString ?? CrewGroup.outsideID
            if byID[id] == nil { firstSeen.append(id) }
            byID[id, default: []].append(row)
            if let workspace = row.workspace { workspaces[id] = workspace }
        }
        // Workspace-bar order only: switching workspaces must not reshuffle the list.
        // Ties break on the ID, not on `rows`' order, which follows dictionaries.
        func rank(_ id: String) -> (Int, Int, String) {
            guard let workspace = workspaces[id] else { return (1, 0, id) }
            return (0, workspace.order, id)
        }
        return firstSeen.sorted { rank($0) < rank($1) }.map { id in
            let rows = byID[id] ?? []
            return CrewGroup(
                id: id, workspace: workspaces[id], isActive: workspaces[id].map { $0.id == activeWorkspaceID } ?? false,
                entries: tree(rows.filter { !$0.isStopped })
                    + rows.filter(\.isStopped).sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
                    .map { (row: $0, depth: 0) })
        }
    }

    /// Rows in the order they show, for the arrow keys: folded groups are skipped.
    static func navigationOrder(_ groups: [CrewGroup], collapsed: Set<String>) -> [UUID] {
        groups.filter { !collapsed.contains($0.id) }.flatMap { $0.rows.map(\.id) }
    }

    /// Orders rows depth-first: roots by handle, each followed by the helpers it
    /// started. A helper whose parent isn't listed is a root.
    static func tree(_ rows: [AgentCrewRow]) -> [(row: AgentCrewRow, depth: Int)] {
        // Rows without a handle (found by process) tie on it: name and tab ID
        // keep them in place, since `rows` arrives in dictionary order.
        func before(_ lhs: AgentCrewRow, _ rhs: AgentCrewRow) -> Bool {
            func number(_ handle: String) -> Int { Int(handle.dropFirst()) ?? .max }
            return (number(lhs.handle), lhs.name, lhs.id.uuidString) < (number(rhs.handle), rhs.name, rhs.id.uuidString)
        }
        let handles = Set(rows.map(\.handle))
        let children = Dictionary(grouping: rows.filter { $0.parent.map(handles.contains) == true }) { $0.parent! }
        var out: [(row: AgentCrewRow, depth: Int)] = []
        var seen = Set<UUID>()
        func visit(_ row: AgentCrewRow, _ depth: Int) {
            // A parent loop (t1 from t2, t2 from t1) must not recurse forever.
            guard seen.insert(row.id).inserted else { return }
            out.append((row, depth))
            for child in (children[row.handle] ?? []).sorted(by: before) {
                visit(child, depth + 1)
            }
        }
        let roots = rows.filter { $0.parent.map(handles.contains) != true }
        for root in roots.sorted(by: before) { visit(root, 0) }
        // Rows only reachable through a loop still show, as roots.
        for row in rows.sorted(by: before) where !seen.contains(row.id) { out.append((row, 0)) }
        return out
    }

    private var allGroups: [CrewGroup] { Self.groups(rows, activeWorkspaceID: activeWorkspaceID) }

    /// Strict mode lists the active workspace alone; without one it can't filter.
    private var filters: Bool { activeOnly && activeWorkspaceID != nil }

    private var visibleGroups: [CrewGroup] { filters ? allGroups.filter(\.isActive) : allGroups }

    /// Agents strict mode hides: those of the other workspaces.
    private var hiddenRows: [AgentCrewRow] {
        filters ? rows.filter { $0.workspace?.id != activeWorkspaceID } : []
    }

    private var selectedRow: AgentCrewRow? { rows.first { $0.id == state.selection } }

    // MARK: Body

    var body: some View {
        let groups = visibleGroups
        let hidden = hiddenRows
        VStack(alignment: .leading, spacing: 0) {
            let formInList = state.composer == .newTask && !state.newTaskInPopover && !agents.isEmpty
            if !groups.isEmpty { crewHeader(groups.flatMap(\.rows)) }
            if formInList { inlineNewTask }
            if groups.isEmpty && !formInList {
                emptyState(othersRunning: !hidden.isEmpty)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                groupHeader(group, first: index == 0)
                if !state.collapsedGroups.contains(group.id) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(group.entries, id: \.row.id) { entry in
                            let row = entry.row
                            crewRow(row, depth: entry.depth)
                            if state.composer == .message(row.id) {
                                composerField(
                                    placeholder: "Message \(row.handle)", hint: "↩ send · esc cancel",
                                    button: "Send"
                                ) { text in
                                    onSend(row, text)
                                    state.cancel()
                                }
                            }
                            if state.composer == .discard(row.id) { discardConfirm(row) }
                        }
                    }
                }
            }
            if !hidden.isEmpty { otherWorkspacesFooter(hidden) }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // A click on empty space drops the selection, like any sidebar list.
        .background(
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    state.selection = nil
                    if state.composer?.takesText == false { state.close() }
                }
        )
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let ids = Self.navigationOrder(visibleGroups, collapsed: state.collapsedGroups)
            switch direction {
            case .up: state.selection = AgentCrewUIState.adjacent(to: state.selection, offset: -1, in: ids)
            case .down: state.selection = AgentCrewUIState.adjacent(to: state.selection, offset: 1, in: ids)
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
            } else if row.hasHooks {
                state.open(.message(row.id))
            } else {
                return .ignored
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
            state.cancel()
            return .handled
        }
        .onChange(of: state.composer) { _, composer in
            // The open field takes the keyboard; closing it hands it back to the list.
            if composer?.takesText != true || composer == .newTask && state.newTaskInPopover {
                fieldFocused = false
                listFocused = composer != nil || state.selection != nil
            } else {
                fieldFocused = true
            }
        }
        .onChange(of: listFocused) { _, focused in
            // Like a sidebar: the selection belongs to the focused list. A click
            // into the terminal (or a row that shows its agent) clears it, unless
            // the row's field or confirmation is open.
            if !focused && !fieldFocused && state.composer == nil { state.selection = nil }
        }
    }

    // MARK: Group header, footer, empty state

    /// The workspace's mark: its color, a branch for a task worktree, a window
    /// for agents outside Boo.
    @ViewBuilder private func groupIcon(_ group: CrewGroup) -> some View {
        let color = group.workspace?.color.map { Color(nsColor: $0) }
        if group.workspace == nil {
            Image(systemName: "macwindow")
                .font(.system(size: fontScale.size(.xs), weight: .medium))
                .foregroundStyle(mutedColor)
        } else if group.workspace?.isTask == true {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: fontScale.size(.xs), weight: .semibold))
                .foregroundStyle(color ?? mutedColor)
        } else if let color {
            Circle().fill(color).frame(width: 7, height: 7)
        } else {
            Circle().strokeBorder(mutedColor.opacity(0.7), lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }

    private func groupHeader(_ group: CrewGroup, first: Bool) -> some View {
        let collapsed = state.collapsedGroups.contains(group.id)
        let hovered = hoveredGroup == group.id
        return Button(action: { state.setCollapsed(group, !collapsed) }) {
            HStack(spacing: 8) {
                groupIcon(group).frame(width: badgeSide)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.title)
                        .font(fontScale.font(.sm).weight(.semibold))
                        .foregroundStyle(group.isActive ? textColor : mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.rows.count)")
                        .font(fontScale.font(.xs).monospacedDigit())
                        .foregroundStyle(mutedColor.opacity(0.8))
                }
                Spacer(minLength: 4)
                if collapsed && group.needsYou {
                    Circle().fill(Tokens.current.warning).frame(width: 6, height: 6)
                        .help("An agent here needs you")
                }
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: fontScale.size(.xs) - 2, weight: .bold))
                    .foregroundStyle(mutedColor)
                    .frame(width: 12)
                    .opacity(collapsed || hovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, first ? 2 : 10)
        .padding(.bottom, 1)
        .onHover { hoveredGroup = $0 ? group.id : (hoveredGroup == group.id ? nil : hoveredGroup) }
        .help(collapsed ? "Show \(group.title)'s agents" : "Hide \(group.title)'s agents")
        .accessibilityLabel("\(group.title), \(group.rows.count) agents, \(collapsed ? "collapsed" : "expanded")")
        .contextMenu {
            Button(collapsed ? "Expand" : "Collapse") { state.setCollapsed(group, !collapsed) }
            Divider()
            if activeOnly {
                Button("Show All Workspaces", action: onShowAll)
            } else {
                Button("Only Show This Workspace", action: onShowActiveOnly)
                    .disabled(activeWorkspaceID == nil)
            }
        }
    }

    /// Strict mode: how many agents run elsewhere, and whether one needs you.
    private func otherWorkspacesFooter(_ hidden: [AgentCrewRow]) -> some View {
        let waiting = hidden.filter(Self.needsYou).count
        let count = "\(hidden.count) \(hidden.count == 1 ? "agent" : "agents") in other workspaces"
        return Button(action: onShowAll) {
            HStack(spacing: 6) {
                if waiting > 0 {
                    Circle().fill(Tokens.current.warning).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(count)
                        .foregroundStyle(waiting > 0 ? textColor : mutedColor)
                    if waiting > 0 {
                        Text("\(waiting) \(waiting == 1 ? "needs" : "need") you")
                            .fontWeight(.medium)
                            .foregroundStyle(Tokens.current.warning)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("Show All")
                    .fontWeight(.medium)
                    .foregroundStyle(accentColor)
            }
            .font(fontScale.font(.xs))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(waiting > 0 ? Tokens.current.warning.opacity(0.1) : textColor.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .help("List the agents of every workspace")
    }

    /// No agents (here): what the list is for, and the way to start one.
    private func emptyState(othersRunning: Bool) -> some View {
        let agent = AgentNewTaskForm.startAgent(agents, picked: state.taskAgent).shortName
        let place = activeWorkspaceName.flatMap { $0.isEmpty ? nil : $0 }
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(textColor.opacity(0.06))
                Image(systemName: "sparkles")
                    .font(.system(size: fontScale.size(.lg), weight: .medium))
                    .foregroundStyle(mutedColor)
            }
            .frame(width: 38, height: 38)
            .padding(.bottom, 4)
            Text(othersRunning ? "No agents in \(place ?? "this workspace")" : "No agents running")
                .font(fontScale.font(.sm).weight(.semibold))
                .foregroundStyle(textColor)
            Text(
                agents.isEmpty
                    ? "Agents you start in a terminal show up here."
                    : "Start \(agent) in a new tab or on its own worktree\(place.map { " of \($0)" } ?? "")."
            )
            .font(fontScale.font(.xs))
            .foregroundStyle(mutedColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if !agents.isEmpty {
                Button(action: { state.open(.newTask) }) {
                    Label("New Agent", systemImage: "plus")
                }
                .buttonStyle(.themed(.primary, size: .large))
                .font(fontScale.font(.sm).weight(.medium))
                .background(newTaskAnchor)
                .padding(.top, 8)
                .help("Start an agent in a new tab or on its own worktree")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// Bar over the list, like the file explorer's: what the crew is doing on
    /// the left, "+" (New Agent) on the right. Only shows while agents are
    /// listed; with none, the empty state carries the large button instead.
    private func crewHeader(_ rows: [AgentCrewRow]) -> some View {
        let live = rows.filter { !$0.isStopped }
        let working = live.filter { $0.state == .working }.count
        let waiting = rows.filter(Self.needsYou).count
        let stopped = rows.count - live.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) running") }
        if stopped > 0 { parts.append("\(stopped) stopped") }
        if parts.isEmpty { parts.append("\(rows.count) \(rows.count == 1 ? "agent" : "agents")") }
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(parts.joined(separator: " · "))
                    .foregroundStyle(mutedColor)
                if waiting > 0 {
                    Text("·").foregroundStyle(mutedColor.opacity(0.6))
                    Text("\(waiting) \(waiting == 1 ? "needs" : "need") you")
                        .fontWeight(.medium)
                        .foregroundStyle(Tokens.current.warning)
                }
            }
            .font(fontScale.font(.xs))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            if !agents.isEmpty {
                SidebarIconButton(
                    systemName: "plus", help: "New Agent: start one in a new tab or on its own worktree",
                    tint: textColor, size: 12, weight: .semibold
                ) { state.open(.newTask) }
                .background(newTaskAnchor)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private var newTaskAnchor: some View {
        AgentNewTaskAnchor { view in
            AgentNewTaskPopover.present(
                relativeTo: view.bounds, of: view, agents: agents, workspaceName: activeWorkspaceName,
                onStartHere: onStartHere, onStartTask: onStartTask)
        }
    }

    /// The new-agent form in the list, when no popover could show it.
    private var inlineNewTask: some View {
        AgentNewTaskForm(
            agents: agents, workspaceName: activeWorkspaceName, onStartHere: onStartHere, onStartTask: onStartTask,
            // A worktree start finishes later: close only the form it came from.
            onDone: { if state.composer == .newTask { state.close() } }
        )
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(textColor.opacity(0.05)))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: State

    private func taskStatusColor(_ tone: AgentTaskStatus.Summary.Tone) -> Color {
        switch tone {
        case .ready: return Tokens.current.success
        case .blocked: return Tokens.current.warning
        case .neutral: return mutedColor
        }
    }

    /// The state's tint: neutral while working, so only rows that want
    /// something from the user carry color.
    private func stateTint(_ row: AgentCrewRow) -> Color {
        if row.isStopped { return mutedColor }
        switch row.state {
        case .working: return textColor
        case .needsInput: return Tokens.current.warning
        case .error: return Tokens.current.error
        case .done: return Tokens.current.success
        }
    }

    /// The state badge's diameter; the group headers' icons and helper rows line up on it.
    private var badgeSide: CGFloat { fontScale.size(.base) + 5 }

    /// A round badge in the state's tint, one shape per state so it reads
    /// without color: a spinner while working, a symbol otherwise.
    private func stateIcon(_ row: AgentCrewRow) -> some View {
        let tint = stateTint(row)
        let side = badgeSide
        return ZStack {
            Circle().fill(tint.opacity(row.state == .working && !row.isStopped ? 0.08 : 0.16))
            if row.isStopped {
                Image(systemName: "pause.fill").foregroundStyle(tint)
            } else {
                switch row.state {
                case .working: ProgressView().controlSize(.small).scaleEffect(0.5)
                case .needsInput: Image(systemName: "hand.raised.fill").foregroundStyle(tint)
                case .error: Image(systemName: "exclamationmark").foregroundStyle(tint)
                case .done: Image(systemName: "checkmark").foregroundStyle(tint)
                }
            }
        }
        .font(.system(size: fontScale.size(.xs) - 1, weight: .bold))
        .frame(width: side, height: side)
        .opacity(row.isReachable ? 1 : 0.6)
        .help(row.isStopped ? "Stopped" : Self.stateLabel(row.state))
    }

    static func stateLabel(_ state: AgentInbox.State) -> String {
        switch state {
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .error: return "Error"
        case .done: return "Done"
        }
    }

    // MARK: Inline fields

    /// A text field in place of a dialog: Return submits, Escape cancels.
    private func composerField(
        placeholder: String, hint: String, button: String, allowsEmpty: Bool = false,
        submit: @escaping (String) -> Void
    ) -> some View {
        let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = (allowsEmpty || !text.isEmpty) && !state.isBusy
        let send = { if canSend { submit(text) } }
        return VStack(alignment: .leading, spacing: 6) {
            // A plain field in its own box, like the file filter: the bezeled
            // style draws a square system border that clashes with the sidebar.
            TextField(placeholder, text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(fontScale.font(.sm))
                .foregroundStyle(textColor)
                .lineLimit(2...8)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(textColor.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            fieldFocused ? accentColor.opacity(0.7) : mutedColor.opacity(0.2), lineWidth: 1)
                )
                .focused($fieldFocused)
                .disabled(state.isBusy)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    state.cancel()
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
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                if state.isBusy { ProgressView().controlSize(.mini) }
                Button("Cancel") { state.cancel() }
                    .buttonStyle(.themed(.secondary))
                Button(button, action: send)
                    .buttonStyle(.themed(.primary))
                    .disabled(!canSend)
            }
            .font(fontScale.font(.sm))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 14 + badgeSide + 8)
        .padding(.trailing, 14)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func discardConfirm(_ row: AgentCrewRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.note ?? "Checking the worktree…")
                .font(fontScale.font(.xs))
                .foregroundStyle(state.noteIsWarning ? Tokens.current.error : mutedColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { state.close() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.themed(.secondary))
                Button("Discard", role: .destructive) {
                    state.close()
                    onDiscard(row)
                }
                .buttonStyle(.themed(.destructive))
                .disabled(state.note == nil)
            }
            .font(fontScale.font(.sm))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((state.noteIsWarning ? Tokens.current.error : textColor).opacity(0.06))
        )
        .padding(.leading, 6 + badgeSide + 8)
        .padding(.trailing, 6)
        .padding(.bottom, 6)
        .onAppear {
            onDiscardSummary(row) { text, losesWork in
                guard state.composer == .discard(row.id) else { return }
                state.note = text
                state.noteIsWarning = losesWork
            }
        }
    }

    // MARK: Row

    /// A row action that shows on hover and on the focused list's selection.
    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontScale.size(.xs), weight: .semibold))
                .foregroundStyle(mutedColor.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: BooStyle.Radius.control, style: .continuous)
                        .fill(mutedColor.opacity(0.1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The line under the name: where the agent is and what it does.
    /// A nested helper skips "from tX": the tree already shows its parent.
    static func subtitle(_ row: AgentCrewRow, nested: Bool) -> String? {
        var parts: [String] = []
        if !row.isReachable { parts.append("not in a Boo window") }
        if let parent = row.parent, !nested { parts.append("from \(parent)") }
        if let detail = row.detail, !detail.isEmpty { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Shown when nothing else is: the state and the folder, so every row has
    /// two lines and the name never sits alone.
    static func fallbackSubtitle(_ row: AgentCrewRow) -> String {
        let state = row.isStopped ? "Stopped" : stateLabel(row.state)
        guard let folder = row.folder, !folder.isEmpty else { return state }
        return "\(state) · \((folder as NSString).lastPathComponent)"
    }

    static func rowHelp(_ row: AgentCrewRow) -> String {
        if !row.isReachable {
            return "Runs in a tab outside Boo's windows, so Boo can't show it. Messages still reach it."
        }
        if row.isStopped {
            return "The agent no longer runs. Resume it, or right-click to review, merge or discard its worktree."
        }
        if !row.hasHooks {
            return "Found by its process. With Boo's hooks installed, it reports its status here and takes messages."
        }
        guard row.state == .needsInput else { return "" }
        return row.asksQuestion
            ? "Click to answer its question in its tab." : "Click to see the prompt in its tab."
    }

    private func crewRow(_ row: AgentCrewRow, depth: Int = 0) -> some View {
        let isHovered = hoveredID == row.id
        // The highlight follows focus, like a sidebar list: once the keyboard
        // moves on (a click into the terminal), the row looks like any other.
        let isSelected = state.selection == row.id && (listFocused || state.composer != nil)
        let showsActions = isHovered || isSelected
        let card = RoundedRectangle(cornerRadius: BooStyle.Radius.large, style: .continuous)
        let badge = badgeSide
        // A helper sits one step in, its guide line under the parent's badge.
        let indent = badge + 8
        // A click selects the row and shows the agent with the keyboard in its
        // terminal; a stopped task has no terminal, so it opens the review.
        // Focusing the list here would take the keyboard back from the terminal.
        return Button(action: {
            state.selection = row.id
            if row.isStopped && row.isTask && row.isReachable {
                onReview(row)
            } else if row.isReachable {
                onJump(row)
            } else {
                listFocused = true
            }
        }) {
            HStack(alignment: .top, spacing: 8) {
                stateIcon(row)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.name.isEmpty ? row.agent : row.name)
                            .font(fontScale.font(.base).weight(row.needsAttention ? .semibold : .medium))
                            .foregroundStyle(row.isReachable ? textColor : mutedColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            if row.queued > 0 {
                                Text("\(row.queued) queued")
                                    .font(fontScale.font(.xs).weight(.medium))
                                    .foregroundStyle(accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(accentColor.opacity(0.15)))
                                    .help("Messages delivered when this agent finishes its turn")
                            }
                            if !row.handle.isEmpty {
                                Text(row.handle)
                                    .font(fontScale.font(.xs, design: .monospaced))
                                    .foregroundStyle(mutedColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(mutedColor.opacity(0.1)))
                            }
                        }
                        // The actions take this spot on hover; both are always laid out,
                        // so nothing shifts under the pointer.
                        .opacity(showsActions ? 0 : 1)
                    }
                    Text(Self.subtitle(row, nested: depth > 0) ?? Self.fallbackSubtitle(row))
                        .font(fontScale.font(.sm))
                        .foregroundStyle(mutedColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if let status = row.taskStatus, !status.text.isEmpty {
                        Label(status.text, systemImage: "arrow.triangle.branch")
                            .font(fontScale.font(.xs))
                            .foregroundStyle(taskStatusColor(status.tone))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(status.branch.map { "Branch \($0)" } ?? "")
                    }
                    if row.state == .needsInput && row.isReachable && !row.asksQuestion && !row.isStopped {
                        HStack(spacing: 6) {
                            Button("Allow") { onRespond(row, .approve) }
                                .buttonStyle(.themed(.primary))
                                .help("Answer the prompt with its default (Return), without opening the tab")
                            Button("Deny") { onRespond(row, .deny) }
                                .buttonStyle(.themed(.secondary))
                                .help("Decline the prompt (Escape); the agent waits for new instructions")
                        }
                        .font(fontScale.font(.sm))
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                card.fill(
                    isSelected
                        ? accentColor.opacity(0.15)
                        : isHovered ? mutedColor.opacity(0.1) : Color.clear)
            )
            .overlay(alignment: .topTrailing) {
                // Messaging is on Space and the context menu, not a hover button.
                HStack(spacing: 4) {
                    if row.isStopped && row.isReachable {
                        rowButton("play.fill", help: "Resume the agent on its last conversation (Space)") {
                            onResume(row)
                        }
                    }
                    if row.isTask {
                        rowButton("plus.forwardslash.minus", help: "Review its changes") { onReview(row) }
                    }
                }
                .padding(4)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
            }
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * indent)
        .overlay(alignment: .leading) {
            // A guide line ties a helper to the agent that started it.
            if depth > 0 {
                Rectangle().fill(mutedColor.opacity(0.2)).frame(width: 1)
                    .padding(.vertical, 2)
                    .offset(x: CGFloat(depth - 1) * indent + 8 + badge / 2)
            }
        }
        .padding(.horizontal, 6)
        .help(Self.rowHelp(row))
        .onHover { hoveredID = $0 ? row.id : (hoveredID == row.id ? nil : hoveredID) }
        .accessibilityLabel(
            "\(row.handle) \(row.name), \(row.isStopped ? "stopped" : row.state.rawValue)"
                .trimmingCharacters(in: .whitespaces)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Show") { onJump(row) }.disabled(!row.isReachable)
            if row.isStopped {
                Button("Resume Agent") { onResume(row) }.disabled(!row.isReachable)
            } else if row.hasHooks {
                Button("Send Message") { state.open(.message(row.id)) }
            }
            if row.isTask {
                Divider()
                Button("Review Changes") { onReview(row) }
                Button("Merge Worktree…") { onMerge(row) }
                Button("Discard Worktree…") { state.open(.discard(row.id)) }
            }
            if let session = sessions[row.id] {
                Divider()
                if session.sessionID != nil {
                    Button("Show Timeline") { onShowTimeline(row, session) }
                }
                if let transcript = session.transcriptPath {
                    Button("Open Transcript") { onOpenTranscript(transcript) }
                }
            }
            if !row.isStopped && (!row.handle.isEmpty || sessions[row.id]?.sessionID != nil) {
                Divider()
                if !row.handle.isEmpty {
                    Button("Copy Handle") { Self.copy(row.handle) }
                }
                if let id = sessions[row.id]?.sessionID {
                    Button("Copy Session ID") { Self.copy(id) }
                }
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
