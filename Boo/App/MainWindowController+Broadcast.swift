import Cocoa

// MARK: - Broadcast Input

extension MainWindowController {

    @objc func broadcastToAllPanesAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        if broadcast?.mode == .all { return stopBroadcast() }
        broadcast = BroadcastGroup(workspaceID: workspace.id, mode: .all)
        refreshBroadcast()
    }

    @objc func broadcastToSelectedPanesAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        if broadcast?.isSelecting == true { return stopBroadcast() }
        broadcast = BroadcastGroup(workspaceID: workspace.id, mode: .selected([workspace.activePaneID]))
        refreshBroadcast()
        BooAlert.showTransient("⌘-click panes to add or remove them")
    }

    @objc func stopBroadcastAction(_ sender: Any?) {
        stopBroadcast()
    }

    func stopBroadcast() {
        guard broadcast != nil else { return }
        broadcast = nil
        refreshBroadcast()
    }

    /// The panes of the active workspace that broadcast right now.
    var broadcastMembers: [UUID] {
        guard let group = broadcast, let workspace = activeWorkspace, group.workspaceID == workspace.id else {
            return []
        }
        return group.members(of: workspace.splitTree.leafIDs) { isBroadcastEligible($0, in: workspace) }
    }

    /// Only a pane showing a plain terminal: never an agent's tab, whose
    /// prompt would take every keystroke as an instruction.
    func isBroadcastEligible(_ paneID: UUID, in workspace: Workspace) -> Bool {
        guard let tab = workspace.pane(for: paneID)?.activeTab, tab.contentType == .terminal else { return false }
        return tab.state.agentSessionID == nil && AgentInbox.shared.items[tab.id] == nil
    }

    /// Re-derives the group after anything that changes it (panes, front
    /// tabs, workspace), ends it when it no longer applies, and repaints.
    func refreshBroadcast() {
        if let group = broadcast {
            let members = broadcastMembers
            if group.workspaceID != activeWorkspace?.id || group.shrankToOne(memberCount: members.count) {
                broadcast = nil
            }
        }
        let members = Set(broadcastMembers)
        for (paneID, paneView) in paneViews { paneView.isBroadcasting = members.contains(paneID) }
        let count = broadcast == nil ? nil : members.count
        if statusBar.broadcastSegment.memberCount != count {
            statusBar.broadcastSegment.memberCount = count
            statusBar.needsDisplay = true
        }
    }

    /// Called by a terminal for each key or paste it receives from the user.
    func broadcastInput(_ input: BroadcastInput, from view: GhosttyView) {
        guard broadcast != nil, let source = paneViews.first(where: { $0.value.ghosttyView === view })?.key
        else { return }
        BroadcastGroup.fanOut(input, from: source, members: broadcastMembers) { paneViews[$0]?.ghosttyView }
    }

    /// ⌘-click while picking panes; true when the click was taken.
    func toggleBroadcastMember(clickedIn view: GhosttyView) -> Bool {
        guard let group = broadcast, group.isSelecting,
            let paneID = paneViews.first(where: { $0.value.ghosttyView === view })?.key
        else { return false }
        group.toggle(paneID)
        refreshBroadcast()
        return true
    }
}

/// "Broadcasting to N panes" in orange while a broadcast group is active.
final class BroadcastSegment: StatusBarPlugin {
    let id = "broadcast"
    let position: StatusBarPosition = .left
    let priority = 1
    var hitRect: NSRect = .zero
    /// nil while not broadcasting.
    var memberCount: Int?

    static let color = NSColor.systemOrange

    var tooltipText: String? { "Typing goes to every orange pane — click to stop" }

    static func label(memberCount: Int) -> String {
        memberCount == 1 ? "Broadcasting to 1 pane" : "Broadcasting to \(memberCount) panes"
    }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool { memberCount != nil }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        guard let count = memberCount else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Self.color
        ]
        let str = Self.label(memberCount: count) as NSString
        let size = str.safeSize(withAttributes: attrs)
        let barH = DensityMetrics.current.statusBarHeight
        str.safeDraw(at: NSPoint(x: x + 4, y: y), withAttributes: attrs)
        hitRect = NSRect(x: x, y: 0, width: size.width + 8, height: barH)
        return size.width + 8
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        WindowManager.shared.controllers.first(where: { $0.window === barView.window })?.stopBroadcast()
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        memberCount.map(Self.label(memberCount:))
    }
}
