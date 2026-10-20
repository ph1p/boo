import Cocoa

/// The orchestrator drawer slides over this window's right edge, above the
/// panes and the sidebar. `OrchestratorController` decides which window has it.
extension MainWindowController {
    @objc func toggleOrchestratorAction(_ sender: Any?) {
        OrchestratorController.shared.toggleDrawer(in: self)
    }

    var hasOrchestratorDrawer: Bool { orchestratorDrawer != nil }

    @discardableResult
    func installOrchestratorDrawer(animated: Bool = true) -> OrchestratorDrawerView? {
        if let orchestratorDrawer { return orchestratorDrawer }
        guard let contentView = window?.contentView, let mainSplitView else { return nil }
        let drawer = OrchestratorDrawerView(frame: .zero)
        drawer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(drawer, positioned: .above, relativeTo: nil)

        let width = drawer.widthAnchor.constraint(
            equalToConstant: drawer.clampedWidth(AppSettings.shared.orchestratorDrawerWidth))
        NSLayoutConstraint.activate([
            drawer.topAnchor.constraint(equalTo: mainSplitView.topAnchor),
            drawer.bottomAnchor.constraint(equalTo: mainSplitView.bottomAnchor),
            drawer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -IslandMetrics.gap),
            width
        ])
        drawer.onWidthChanged = { width.constant = $0 }
        drawer.onWidthCommitted = { AppSettings.shared.orchestratorDrawerWidth = $0 }
        orchestratorDrawer = drawer

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            contentView.layoutSubtreeIfNeeded()
            drawer.alphaValue = 0
            drawer.layer?.transform = CATransform3DMakeTranslation(24, 0, 0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                drawer.animator().alphaValue = 1
                drawer.layer?.transform = CATransform3DIdentity
            }
        }
        return drawer
    }

    func removeOrchestratorDrawer() {
        guard let drawer = orchestratorDrawer else { return }
        orchestratorDrawer = nil
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: drawer) == true
        drawer.removeFromSuperview()
        if hadFocus, let paneID = activeWorkspace?.activePaneID {
            paneViews[paneID]?.focusActiveView()
        }
    }
}
