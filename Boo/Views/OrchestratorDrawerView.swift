import Cocoa
import SwiftUI

/// The orchestrator drawer: a right-edge overlay with the agent strip, the
/// approval cards and the orchestrator's terminal. `OrchestratorController`
/// installs it in one window at a time and moves the terminal into
/// `terminalContainer`.
///
/// Keys while focus is in the drawer: ⌘↩ allows the first card; ⎋ denies it
/// when focus is outside the terminal (in the terminal, ⎋ belongs to Claude).
@MainActor
final class OrchestratorDrawerView: NSView {
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 900

    let terminalContainer = NSView()
    let model = OrchestratorDrawerModel()
    /// Width while dragging the left edge; `onWidthCommitted` fires on release.
    var onWidthChanged: ((CGFloat) -> Void)?
    var onWidthCommitted: ((CGFloat) -> Void)?

    private let panel: OrchestratorPanelHost
    private let emptyState: NSHostingView<OrchestratorEmptyState>
    private let handle = OrchestratorResizeHandle()

    override init(frame: NSRect) {
        panel = OrchestratorPanelHost(rootView: OrchestratorPanel(model: model))
        emptyState = NSHostingView(rootView: OrchestratorEmptyState(model: model))
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    private func setup() {
        wantsLayer = true
        panel.drawer = self
        panel.sizingOptions = [.intrinsicContentSize]
        for view in [panel, terminalContainer, emptyState, handle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        terminalContainer.wantsLayer = true
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onWidthChanged?(self.clampedWidth(self.frame.width - delta))
        }
        handle.onDragEnded = { [weak self] in
            guard let self else { return }
            self.onWidthCommitted?(self.frame.width)
        }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),

            terminalContainer.topAnchor.constraint(equalTo: panel.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            emptyState.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5)
        ])
        model.onReload = { [weak self] in self?.applyModel() }
        model.reload()
    }

    private func applyModel() {
        let theme = model.theme
        layer?.backgroundColor = theme.sidebarBg.cgColor
        IslandMetrics.round(self, borderColor: theme.sidebarBorder)
        emptyState.isHidden = model.running
        terminalContainer.isHidden = !model.running
    }

    func clampedWidth(_ width: CGFloat) -> CGFloat {
        let windowLimit = (window?.contentView?.bounds.width ?? Self.maxWidth) - 200
        return max(Self.minWidth, min(width, Self.maxWidth, max(Self.minWidth, windowLimit)))
    }

    // MARK: - Keys

    private var hasFocusInside: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76, hasFocusInside,
            let first = ApprovalCenter.shared.pending.first
        {
            ApprovalCenter.shared.resolve(first.id, allow: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let first = ApprovalCenter.shared.pending.first {
            ApprovalCenter.shared.resolve(first.id, allow: false)
        } else {
            OrchestratorController.shared.closeDrawer()
        }
    }
}

/// Hosts the panel; a click on it focuses the drawer so ⎋ and ⌘↩ reach the cards.
final class OrchestratorPanelHost: NSHostingView<OrchestratorPanel> {
    weak var drawer: OrchestratorDrawerView?

    override func mouseDown(with event: NSEvent) {
        if let drawer { window?.makeFirstResponder(drawer) }
        super.mouseDown(with: event)
    }
}

/// The drawer's left edge, dragged to resize.
final class OrchestratorResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

// MARK: - Model

/// What the drawer shows, rebuilt whenever an agent, a card or the orchestrator changes.
@MainActor
final class OrchestratorDrawerModel: ObservableObject {
    struct AgentRow: Identifiable {
        let id: UUID
        let summary: String
        let workspace: String
        let color: NSColor
        let owned: Bool
    }

    struct Card: Identifiable {
        let id: UUID
        let action: String
        let target: String
        let targetTab: UUID?
        let payload: String
        let allowsTabGrant: Bool
    }

    @Published private(set) var agents: [AgentRow] = []
    @Published private(set) var cards: [Card] = []
    @Published private(set) var running = false
    @Published private(set) var canResume = false
    @Published private(set) var claudeMissing = false
    @Published private(set) var launchError: String?
    @Published private(set) var stateColor = NSColor.secondaryLabelColor
    @Published private(set) var theme = AppSettings.shared.theme
    var onReload: (() -> Void)?

    nonisolated(unsafe) private var observers: [Any] = []

    init() {
        let names: [Notification.Name] = [
            .agentInboxChanged, .approvalsChanged, .orchestratorChanged, .settingsChanged
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        let inbox = AgentInbox.shared
        let orchestrator = OrchestratorController.shared
        let caller = orchestrator.tabID
        theme = AppSettings.shared.theme
        agents = inbox.sortedItems.map { item in
            AgentRow(
                id: item.tabID, summary: AgentInbox.summary(of: item),
                workspace: inbox.locate(item.tabID)?.workspace.displayName ?? "",
                color: AgentInboxSegment.color(for: item, theme: theme),
                owned: caller.map { CapabilityTokens.shared.owns($0, item.tabID) } ?? false)
        }
        cards = ApprovalCenter.shared.pending.map { request in
            Card(
                id: request.id, action: request.action,
                target: OrchestratorController.targetLabel(request.targetTabIDs),
                targetTab: request.targetTabIDs.first, payload: request.payload,
                allowsTabGrant: request.allowsTabGrant)
        }
        stateColor = inbox.orchestrator.map { AgentInboxSegment.color(for: $0, theme: theme) } ?? theme.textTertiary
        running = orchestrator.isRunning
        canResume = orchestrator.canResume
        claudeMissing = orchestrator.claudeInstalled == false
        launchError = orchestrator.launchError
        onReload?()
    }
}

// MARK: - SwiftUI

struct OrchestratorPanel: View {
    @ObservedObject var model: OrchestratorDrawerModel

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: model.stateColor)).frame(width: 7, height: 7)
                Text("Orchestrator").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                Spacer()
                if model.running {
                    iconButton("stop.circle", help: "Stop the orchestrator") { OrchestratorController.shared.stop() }
                }
                iconButton("xmark", help: "Close (⌥⌘O)") { OrchestratorController.shared.closeDrawer() }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            if !model.agents.isEmpty {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.agents) { row in agentRow(row, theme: theme) }
                    }
                }
                .frame(maxHeight: min(CGFloat(model.agents.count) * 24, 120))
                .padding(.bottom, 4)
            }

            if !model.cards.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                            ApprovalCardView(card: card, theme: theme, isFirst: index == 0)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 280)
                .padding(.bottom, 6)
            }
            Rectangle().fill(Color(nsColor: theme.separator)).frame(height: 1)
        }
    }

    private func agentRow(_ row: OrchestratorDrawerModel.AgentRow, theme: TerminalTheme) -> some View {
        Button {
            AgentInbox.shared.jump(to: row.id)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: row.color)).frame(width: 6, height: 6)
                Text(row.summary).lineLimit(1).truncationMode(.tail)
                    .foregroundColor(Color(nsColor: theme.chromeText))
                Spacer(minLength: 4)
                if row.owned {
                    Text("owned").font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(nsColor: theme.subtleFill)).cornerRadius(3)
                        .foregroundColor(Color(nsColor: theme.textSecondary))
                }
                Text(row.workspace).lineLimit(1).foregroundColor(Color(nsColor: theme.textTertiary))
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to this agent")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(nsColor: model.theme.textSecondary))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ApprovalCardView: View {
    let card: OrchestratorDrawerModel.Card
    let theme: TerminalTheme
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10))
                    .foregroundColor(Color(nsColor: theme.warning))
                Text(card.action).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                Spacer()
            }
            if !card.target.isEmpty {
                Button {
                    if let tab = card.targetTab { AgentInbox.shared.jump(to: tab) }
                } label: {
                    Text(card.target).font(.system(size: 10)).lineLimit(1)
                        .foregroundColor(Color(nsColor: theme.accentColor))
                }
                .buttonStyle(.plain)
                .help("Jump to the target")
            }
            if !card.payload.isEmpty {
                Text(card.payload).font(.system(size: 11, design: .monospaced)).lineLimit(8)
                    .textSelection(.enabled)
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: theme.subtleFill)).cornerRadius(4)
            }
            HStack(spacing: 6) {
                Button(isFirst ? "Allow ⌘↩" : "Allow") { ApprovalCenter.shared.resolve(card.id, allow: true) }
                if card.allowsTabGrant {
                    Button("Allow for this pane") {
                        ApprovalCenter.shared.resolve(card.id, allow: true, forTab: true)
                    }
                }
                Spacer()
                Button(isFirst ? "Deny ⎋" : "Deny") { ApprovalCenter.shared.resolve(card.id, allow: false) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: theme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 1))
        .cornerRadius(6)
    }
}

struct OrchestratorEmptyState: View {
    @ObservedObject var model: OrchestratorDrawerModel

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    var body: some View {
        let theme = model.theme
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26))
                .foregroundColor(Color(nsColor: theme.textTertiary))
            if model.claudeMissing {
                Text("Claude Code is not installed. Install it, then check again:")
                    .font(.system(size: 11)).multilineTextAlignment(.center)
                    .foregroundColor(Color(nsColor: theme.textSecondary))
                    .frame(maxWidth: 280)
                Text(Self.installCommand)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: theme.textTertiary).opacity(0.12)))
                Button("Check Again") { OrchestratorController.shared.checkClaudeInstalled(force: true) }
                    .controlSize(.regular)
            } else {
                Text(
                    model.canResume
                        ? "The orchestrator stopped. Resume picks up the same conversation."
                        : "One Claude Code session that sees every window and agent: it unblocks waiting agents, splits work into worktree tasks and merges them when they're done."
                )
                .font(.system(size: 11)).multilineTextAlignment(.center)
                .foregroundColor(Color(nsColor: theme.textSecondary))
                .frame(maxWidth: 280)
                if model.canResume {
                    HStack(spacing: 8) {
                        Button("Resume") { OrchestratorController.shared.launch() }
                            .keyboardShortcut(.defaultAction)
                        Button("New Conversation") { OrchestratorController.shared.newConversation() }
                    }
                    .controlSize(.regular)
                } else {
                    Button("Start Orchestrator") { OrchestratorController.shared.launch() }
                        .controlSize(.regular)
                }
            }
            if let error = model.launchError {
                Text(error).font(.system(size: 11)).multilineTextAlignment(.center)
                    .foregroundColor(Color(nsColor: theme.error))
                    .frame(maxWidth: 280)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
