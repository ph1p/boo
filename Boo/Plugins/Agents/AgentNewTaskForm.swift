import AppKit
import SwiftUI

/// The form that starts an agent: which agent, where (a new tab or its own
/// worktree), and the prompt. Shown in a popover from the Agents section
/// header's "+", or in place in the crew list when no header can anchor it.
/// Return starts, Escape cancels; the agent and place picked last are kept.
struct AgentNewTaskForm: View {
    /// The agents installed on this Mac, in picker order.
    let agents: [AgentKind]
    /// The workspace a new agent starts in, for the line under the title.
    var workspaceName: String?
    /// Starts an agent in a new terminal tab, with the prompt when one was typed.
    let onStartHere: (AgentKind, String) -> Void
    /// Starts a task on its own worktree; calls back with an error, or nil once it runs.
    let onStartTask: (String, AgentKind, @escaping @MainActor (String?) -> Void) -> Void
    /// Closes the form: the popover, or the inline field.
    let onDone: () -> Void

    @ObservedObject private var state = AgentCrewUIState.shared
    @Environment(\.tokens) private var t
    @FocusState private var focused: Bool

    /// The picked agent, or the first installed one when it is gone.
    static func startAgent(_ agents: [AgentKind], picked: AgentKind) -> AgentKind {
        agents.contains(picked) ? picked : agents.first ?? .claudeCode
    }

    private var agent: AgentKind { Self.startAgent(agents, picked: state.taskAgent) }

    /// Where the agent will run, in words: "New tab in boo".
    static func placeLine(_ place: AgentCrewUIState.Place, workspace: String?) -> String {
        let name = workspace.flatMap { $0.isEmpty ? nil : $0 }
        switch place {
        case .tab: return name.map { "New tab in \($0)" } ?? "New tab in the active workspace"
        case .worktree:
            return name.map { "Own worktree and branch of \($0)" } ?? "Own worktree of the active repository"
        }
    }

    var body: some View {
        let isTab = state.taskPlace == .tab
        let prompt = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let canStart = (isTab || !prompt.isEmpty) && !state.isBusy
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.text)
                Text(Self.placeLine(state.taskPlace, workspace: workspaceName))
                    .font(.system(size: 11))
                    .foregroundStyle(t.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                if agents.count > 1 {
                    labeled("Agent") {
                        segmented(
                            agents.map { ($0, $0.shortName, nil) }, selection: agent,
                            set: { state.taskAgent = $0 })
                    }
                    .help("The agent to start")
                }
                labeled("Start in") {
                    segmented(
                        [
                            (AgentCrewUIState.Place.tab, "New Tab", "plus.rectangle"),
                            (.worktree, "Worktree", "arrow.triangle.branch")
                        ], selection: state.taskPlace, set: { state.taskPlace = $0 })
                }
                .help("New tab: starts in the active folder. Worktree: its own branch of the active repository.")
            }

            TextField(
                isTab ? "What should \(agent.shortName) do? (optional)" : "What should \(agent.shortName) do?",
                text: $state.text, axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(t.text)
            .lineLimit(3...6)
            .padding(.vertical, 6)
            .themedFieldChrome(focused: focused)
            .focused($focused)
            .disabled(state.isBusy)
            .onSubmit { if canStart { start(prompt) } }
            .onKeyPress(.escape) {
                onDone()
                return .handled
            }
            .onAppear { focused = true }

            if let note = state.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(state.noteIsWarning ? t.error : t.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("↩ start · esc cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(t.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if state.isBusy { ProgressView().controlSize(.mini) }
                Button(action: { start(prompt) }) {
                    Text("Start")
                }
                .buttonStyle(.themed(.primary))
                .disabled(!canStart)
            }
        }
        .padding(14)
    }

    private func start(_ prompt: String) {
        let agent = self.agent
        if state.taskPlace == .tab {
            onStartHere(agent, prompt)
            onDone()
            return
        }
        state.isBusy = true
        state.note = nil
        onStartTask(prompt, agent) { error in
            state.isBusy = false
            if let error {
                state.note = error
                state.noteIsWarning = true
            } else {
                onDone()
            }
        }
    }

    private func labeled(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(t.textSecondary)
                .frame(width: 50, alignment: .leading)
            content()
        }
    }

    /// A segmented control drawn in theme colors: the stock one paints the
    /// system accent and a grey bezel whatever the theme.
    private func segmented<V: Hashable>(
        _ options: [(value: V, title: String, symbol: String?)], selection: V, set: @escaping (V) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button(action: { set(option.value) }) {
                    HStack(spacing: 4) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 10)) }
                        Text(option.title).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? t.text : t.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? t.cardBg : .clear)
                            .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.controlFill))
    }
}

/// Shows `AgentNewTaskForm` in a transient popover, like the workspace editor.
@MainActor
enum AgentNewTaskPopover {
    private static weak var current: NSPopover?
    private static let delegate = Delegate()

    /// Opens the form under `rect` of `view` (the section header's "+").
    /// Sets the crew state's `.newTask` composer while it shows.
    static func present(
        relativeTo rect: NSRect, of view: NSView, agents: [AgentKind], workspaceName: String?,
        onStartHere: @escaping (AgentKind, String) -> Void,
        onStartTask: @escaping (String, AgentKind, @escaping @MainActor (String?) -> Void) -> Void
    ) {
        guard view.window != nil, !agents.isEmpty else { return }
        current?.close()
        let state = AgentCrewUIState.shared
        weak var popoverRef: NSPopover?
        let form = AgentNewTaskForm(
            agents: agents, workspaceName: workspaceName, onStartHere: onStartHere, onStartTask: onStartTask,
            onDone: { popoverRef?.close() })
        let popover = makeInlineEditorPopover(form.frame(width: 288))
        popover.delegate = delegate
        popoverRef = popover
        current = popover
        state.newTaskInPopover = true
        state.open(.newTask)
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    private final class Delegate: NSObject, NSPopoverDelegate {
        func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                let state = AgentCrewUIState.shared
                state.newTaskInPopover = false
                if state.composer == .newTask { state.close() }
            }
        }
    }
}

/// Marks the "New Agent" button in the crew list: the popover opens under it,
/// also when `perform(.newTask)` asks for the form.
final class AgentNewTaskAnchorView: NSView {
    var present: (@MainActor (NSView) -> Void)?

    /// Opens the popover under the visible anchor of the key window; false when none shows.
    @MainActor static func present(in window: NSWindow? = nil) -> Bool {
        guard let root = (window ?? NSApp.keyWindow ?? NSApp.mainWindow)?.contentView,
            let anchor = find(in: root), let present = anchor.present
        else { return false }
        present(anchor)
        return true
    }

    private static func find(in view: NSView) -> AgentNewTaskAnchorView? {
        if let anchor = view as? AgentNewTaskAnchorView, !anchor.isHiddenOrHasHiddenAncestor { return anchor }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }
}

/// Puts an `AgentNewTaskAnchorView` behind a SwiftUI button.
struct AgentNewTaskAnchor: NSViewRepresentable {
    let present: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> AgentNewTaskAnchorView {
        let view = AgentNewTaskAnchorView()
        view.present = present
        return view
    }

    func updateNSView(_ view: AgentNewTaskAnchorView, context: Context) { view.present = present }
}
