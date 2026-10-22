import Cocoa

// MARK: - Pane Controls

extension PaneView {

    /// When the corner notch shows its ⋯ button, per `AppSettings.paneControlsVisibility`.
    static func paneControlsExpanded(
        _ visibility: PaneControlsVisibility, pointerInside: Bool, isFocused: Bool
    ) -> Bool {
        switch visibility {
        case .hover: return pointerInside
        case .focused: return pointerInside || isFocused
        case .never: return false
        }
    }

    /// Re-derives the corner notch and the recording frame from the front tab,
    /// focus, zoom, hover and settings. Push-driven from each of those sites.
    func updatePaneControls() {
        let settings = AppSettings.shared
        let tab = pane.activeTab
        let recordingSince: Date? =
            tab.flatMap { $0.state.isRecording ? terminalView(forTab: $0.id)?.recorder?.startDate : nil }

        recordingBorder.isHidden = recordingSince == nil || !settings.highlightRecordingPane
        syncIslandStroke()

        let oldSize = paneControls.frame.size
        let expanded = Self.paneControlsExpanded(
            settings.paneControlsVisibility, pointerInside: isPointerInPane, isFocused: isFocused)
        // Only a profile that differs from the default earns the notch.
        let profile = tab?.state.profile.flatMap { $0 == settings.defaultProfile ? nil : $0 }
        paneControls.configure(
            expanded: expanded, recordingSince: recordingSince, isZoomed: isZoomed, profile: profile)
        // Hover and focus flips mostly keep the size; only re-anchor when it changed.
        if paneControls.frame.size != oldSize { layoutTerminalView() }

        // Drop the notch rather than let it cover a narrow pane's whole top edge.
        let room = paneControls.frame.minX - verticalTabColumnWidth
        setPaneControlsShown(!paneControls.isEmpty && room >= 24)
    }

    /// Shown and hidden at once, not faded: the island edge swaps between the
    /// layer border and the cut stroke, which can't cross-fade.
    private func setPaneControlsShown(_ shown: Bool) {
        guard shown != paneControlsShown else { return }
        paneControlsShown = shown
        paneControls.isHidden = !shown
        paneControls.alphaValue = shown ? 1 : 0
        syncIslandCut()
    }
    /// While the notch shows, the island edge runs around its cut: the layer
    /// border, which would cross the cut, hands over to `islandCutStroke`.
    func syncIslandCut() {
        guard let layer else { return }
        let cut = !paneControls.isHidden
        layer.borderWidth = cut ? 0 : IslandMetrics.borderWidth
        islandCutStroke.isHidden = !cut
        guard cut else { return }
        if islandCutStroke.frame != bounds { islandCutStroke.frame = bounds }
        if let c = layer.borderColor { islandCutStroke.color = NSColor(cgColor: c) ?? .clear }
        islandCutStroke.path = PaneControlsView.islandOutline(
            paneSize: bounds.size, notchWidth: paneControls.frame.width, radius: IslandMetrics.innerRadius)
    }
}

/// Owns the pane-wide hover tracking area. A separate owner keeps these
/// enter/exit events away from `PaneView`'s own tab-bar tracking handlers.
final class PaneHoverTracker: NSResponder {
    var onChange: ((Bool) -> Void)?

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }

}
