import Cocoa

// MARK: - Pane Controls

extension PaneView {

    /// When the controls pill is expanded, per `AppSettings.paneControlsVisibility`.
    static func paneControlsExpanded(
        _ visibility: PaneControlsVisibility, pointerInside: Bool, isFocused: Bool
    ) -> Bool {
        switch visibility {
        case .hover: return pointerInside
        case .focused: return pointerInside || isFocused
        case .never: return false
        }
    }

    /// Re-derives the controls pill and the recording frame from the front tab,
    /// focus, zoom, hover and settings. Push-driven from each of those sites.
    func updatePaneControls() {
        let settings = AppSettings.shared
        let tab = pane.activeTab
        let recordingSince: Date? =
            tab.flatMap { $0.state.isRecording ? terminalView(forTab: $0.id)?.recorder?.startDate : nil }

        recordingBorder.isHidden = recordingSince == nil || !settings.highlightRecordingPane
        syncIslandStroke()

        let oldSize = paneControls.frame.size
        let multiPane = showCloseOnSingleTab
        let expanded = Self.paneControlsExpanded(
            settings.paneControlsVisibility, pointerInside: isPointerInPane, isFocused: isFocused)
        paneControls.configure(
            expanded: expanded,
            canRecord: tab?.contentType == .terminal,
            recordingSince: recordingSince,
            canZoom: multiPane && !isZoomed,
            canClose: multiPane)
        paneControls.setZoomed(isZoomed)
        // Hover and focus flips mostly keep the size; only re-anchor when it changed.
        if paneControls.frame.size != oldSize { layoutTerminalView() }

        // Drop the pill rather than let it cover a narrow pane's whole top edge.
        let room = paneControls.frame.minX - verticalTabColumnWidth
        setPaneControlsShown(!paneControls.isEmpty && room >= 24)
    }

    private func setPaneControlsShown(_ shown: Bool) {
        guard shown != paneControlsShown else { return }
        paneControlsShown = shown
        if shown { paneControls.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            paneControls.animator().alphaValue = shown ? 1 : 0
        }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paneControlsShown else { return }
                self.paneControls.isHidden = true
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
