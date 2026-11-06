import Cocoa

// MARK: - Pane Controls

/// Buttons after the last tab: `+`, the ⋯ pane menu, and unzoom while zoomed.
enum TabBarButton: Equatable {
    case plus, more, unzoom
}

extension PaneView {

    /// When the tab bar's ⋯ button shows, per `AppSettings.paneControlsVisibility`.
    static func paneControlsExpanded(
        _ visibility: PaneControlsVisibility, pointerInside: Bool, isFocused: Bool
    ) -> Bool {
        switch visibility {
        case .hover: return pointerInside
        case .focused: return pointerInside || isFocused
        case .never: return false
        }
    }

    /// Re-derives the ⋯ button and the recording frame from the front tab,
    /// focus, hover and settings. Push-driven from each of those sites.
    func updatePaneControls() {
        let settings = AppSettings.shared
        let isRecording = pane.activeTab?.state.isRecording == true
        recordingBorder.isHidden = !isRecording || !settings.highlightRecordingPane
        syncIslandStroke()

        let shown = Self.paneControlsExpanded(
            settings.paneControlsVisibility, pointerInside: isPointerInPane, isFocused: isFocused)
        guard shown != isMoreButtonShown else { return }
        isMoreButtonShown = shown
        if !shown, hoveredBarButton == .more { hoveredBarButton = nil }
        needsDisplay = true
    }

    /// The buttons after the tabs, in order. ⋯ keeps its place while hidden
    /// so the `+` doesn't shift when the pointer enters the pane.
    var tabBarButtons: [TabBarButton] {
        var buttons: [TabBarButton] = [.plus]
        if AppSettings.shared.paneControlsVisibility != .never { buttons.append(.more) }
        if isZoomed { buttons.append(.unzoom) }
        return buttons
    }

    /// The buttons that draw and take clicks; a hidden ⋯ keeps only its slot.
    var visibleTabBarButtons: [TabBarButton] {
        tabBarButtons.filter { $0 != .more || isMoreButtonShown }
    }

    /// Width the buttons take after the tabs of a horizontal bar.
    var tabBarButtonsWidth: CGFloat { CGFloat(tabBarButtons.count) * plusButtonWidth }

    /// Where `button` sits, nil when it isn't in the bar. In a horizontal bar
    /// the buttons line up in equal slots; in the vertical footer the `+`
    /// fills what the square buttons on its right leave.
    func tabBarButtonSlot(_ button: TabBarButton, in cluster: CGRect? = nil) -> CGRect? {
        let buttons = tabBarButtons
        guard let i = buttons.firstIndex(of: button) else { return nil }
        let cluster = cluster ?? tabBarButtonsSlot()
        guard isVerticalTabs else {
            return CGRect(
                x: cluster.minX + CGFloat(i) * plusButtonWidth, y: cluster.minY, width: plusButtonWidth,
                height: cluster.height)
        }
        let side = plusButtonWidth
        let plusW = max(side, cluster.width - CGFloat(buttons.count - 1) * side)
        if i == 0 { return CGRect(x: cluster.minX, y: cluster.minY, width: plusW, height: cluster.height) }
        return CGRect(
            x: cluster.minX + plusW + CGFloat(i - 1) * side, y: cluster.minY, width: side, height: cluster.height)
    }

    /// The visible bar button under `point`.
    func tabBarButton(at point: NSPoint) -> TabBarButton? {
        let cluster = tabBarButtonsSlot()
        guard cluster.contains(point) else { return nil }
        return visibleTabBarButtons.first { tabBarButtonSlot($0, in: cluster)?.contains(point) == true }
    }

    /// A click (`event`) or an accessibility press (nil event: `+` opens a
    /// terminal tab directly instead of the new-tab menu).
    func pressTabBarButton(_ button: TabBarButton, event: NSEvent?) {
        switch button {
        case .plus:
            if let event {
                showNewTabMenu(event: event)
            } else {
                addNewTab(
                    contentType: .terminal, workingDirectory: pane.activeTab?.workingDirectory ?? "~",
                    group: activeGroupID)
            }
        case .more:
            showPaneMenu()
        case .unzoom:
            onUnzoomRequested?()
        }
    }

    /// The pane menu, dropping down from the ⋯ button's left edge.
    func showPaneMenu() {
        guard let menu = paneMenuProvider?(), let slot = tabBarButtonSlot(.more) else { return }
        let pill = Self.tabPillRect(inSlot: slot)
        menu.popUp(positioning: nil, at: NSPoint(x: pill.minX, y: pill.maxY + 4), in: self)
    }

    func drawTabBarButtons(ctx: CGContext, theme: TerminalTheme, cluster: CGRect) {
        for button in visibleTabBarButtons {
            guard let slot = tabBarButtonSlot(button, in: cluster) else { continue }
            let pill = Self.tabPillRect(inSlot: slot)
            let hovered = hoveredBarButton == button
            // Transparent at rest so they read as part of the bar, not as tabs;
            // the pill only appears under the pointer.
            if hovered {
                WorkspacePillStyle.fill(
                    ctx, rect: pill, active: false, hovered: true, wsColor: nil, neutral: theme.chromeMuted)
            }
            let color = theme.chromeMuted.withAlphaComponent(hovered ? 0.9 : 0.65)
            switch button {
            case .plus where isVerticalTabs:
                drawNewTabRow(ctx: ctx, pill: pill, color: color)
            case .plus:
                WorkspacePillStyle.drawPlusGlyph(ctx, in: pill, halfSpan: 4.5, color: color)
            case .more:
                ctx.setFillColor(color.cgColor)
                let dot: CGFloat = 2.5
                for k in -1...1 {
                    ctx.fillEllipse(
                        in: CGRect(
                            x: pill.midX + CGFloat(k) * 4.5 - dot / 2, y: pill.midY - dot / 2, width: dot,
                            height: dot))
                }
            case .unzoom:
                let icon = Self.drawTabIcon(
                    symbolName: "arrow.down.right.and.arrow.up.left", color: color, x: pill.midX - 7,
                    midY: pill.midY, isActive: true)
                icon?.draw()
            }
        }
    }
}

/// Owns the pane-wide hover tracking area. A separate owner keeps these
/// enter/exit events away from `PaneView`'s own tab-bar tracking handlers.
final class PaneHoverTracker: NSResponder {
    var onChange: ((Bool) -> Void)?

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }

}
