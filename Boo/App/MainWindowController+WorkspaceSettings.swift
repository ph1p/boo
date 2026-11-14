import Cocoa
import SwiftUI

/// Per-workspace settings: applying the active workspace's overrides to the
/// window, and the sheet that edits them.
extension MainWindowController {
    /// Brings the window's layout in line with `effectiveSettings`. Called when
    /// the active workspace or a layout setting changes.
    func refreshWorkspaceOverrides() {
        let effective = effectiveSettings
        if effective.sidebarPosition != currentSidebarPosition {
            currentSidebarPosition = effective.sidebarPosition
            rebuildSidebarLayout()
        }
        if effective.tabOverflowMode != currentTabOverflowMode {
            currentTabOverflowMode = effective.tabOverflowMode
            for (_, paneView) in paneViews {
                paneView.needsLayout = true
                paneView.needsDisplay = true
            }
        }
        let settings = activeWorkspace?.settings
        statusBar.sidebarPositionOverride = settings?.sidebarPosition == nil ? nil : effective.sidebarPosition
        statusBar.hiddenSegmentsOverride = effective.statusBarHiddenSegments
        statusBar.onWorkspaceSegmentToggle = { [weak self] id, hidden in
            guard let self, let workspace = self.activeWorkspace else { return }
            self.updateWorkspaceSettings(workspace.id) { settings in
                var list = (settings.statusBarHiddenSegments ?? []).filter { $0 != id }
                if hidden { list.append(id) }
                settings.statusBarHiddenSegments = list
            }
        }
        statusBar.needsDisplay = true
        if effectiveTheme.name != appliedChromeThemeName { applyChromeTheme() }
    }

    /// Restyles the window chrome with `effectiveTheme`: colours, pane
    /// backgrounds, sidebar and status bar.
    func applyChromeTheme() {
        let theme = effectiveTheme
        appliedChromeThemeName = theme.name
        window?.backgroundColor = theme.windowBackdrop
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.contentView?.layer?.backgroundColor = theme.windowBackdrop.cgColor
        sidebarContainer.layer?.backgroundColor = theme.sidebarBg.cgColor
        // splitContainer stays clear — panes are the islands (see SplitContainerView.init)
        mainSplitView.needsDisplay = true
        // A refresh, not just a redraw: workspace colours resolve
        // against the theme palette.
        refreshToolbar()
        statusBar.needsDisplay = true
        // Island borders are layer strokes, not drawn in `draw(_:)`,
        // so they need an explicit refresh on theme change.
        // Toolbar, status bar and the side workspace bar carry no
        // border — they are bare strips.
        IslandMetrics.refreshBorder(sidebarContainer, color: theme.sidebarBorder)
        sideWorkspaceBar?.needsDisplay = true
        for (_, pv) in paneViews { pv.applyTheme() }
        // Rebuild plugin sidebar to pick up new theme
        if let ctx = pluginRegistry.lastContext {
            cachedDetailViews.removeAll()
            for case let panel as SidebarPanelView in pluginPanelViews.values { panel.invalidateContent() }
            rebuildSidebarTabs(context: ctx)
        }
    }

    /// Changes one workspace's settings, applies them and saves the session.
    func updateWorkspaceSettings(_ workspaceID: UUID, _ change: (inout WorkspaceSettings) -> Void) {
        guard let workspace = appState.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let old = workspace.settings
        change(&workspace.settings)
        guard workspace.settings != old else { return }
        if workspace.settings.defaultProfile != old.defaultProfile || !workspace.settings.sameSurfaceLook(as: old) {
            RuleEngine.shared.reevaluateAll()
        }
        if workspace === activeWorkspace { refreshWorkspaceOverrides() }
        saveSession()
    }

    func workspaceSettingsMenuItems(forWorkspaceAt index: Int) -> [NSMenuItem] {
        guard index >= 0, index < appState.workspaces.count else { return [] }
        let workspace = appState.workspaces[index]
        // A tmux workspace isn't saved, so its settings would not survive.
        guard workspace.tmuxWindowID == nil else { return [] }
        let id = workspace.id
        return [
            .separator(),
            ClosureMenuItem(title: "Workspace Settings\u{2026}") { [weak self] in
                self?.showWorkspaceSettings(forWorkspace: id)
            }
        ]
    }

    func showWorkspaceSettings(forWorkspace workspaceID: UUID) {
        guard let window, window.attachedSheet == nil,
            let workspace = appState.workspaces.first(where: { $0.id == workspaceID })
        else { return }
        let theme = effectiveTheme
        let catalog = statusBar.segmentCatalog
        let arrangement = statusBar.arrangement()
        let segments = (arrangement.left + arrangement.right).compactMap { catalog[$0] }
        let sidebarTabs =
            pluginRegistry.lastContext.map { pluginRegistry.contributedSidebarTabs(terminal: $0) } ?? []

        let sheet = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let view = WorkspaceSettingsView(
            name: workspace.displayName, settings: workspace.settings,
            profiles: ProfileStore.shared.names,
            sidebarTabs: sidebarTabs.map { .init(id: $0.id.id, label: $0.label) },
            segments: segments,
            globallyHiddenSegments: segments.map(\.id).filter { AppSettings.shared.isStatusBarSegmentHidden($0) },
            onChange: { [weak self] settings in
                self?.updateWorkspaceSettings(workspaceID) { $0 = settings }
            },
            onDone: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet)
            })
        sheet.contentViewController = NSHostingController(
            rootView: view.environment(\.tokens, Tokens(theme: theme)))
        window.beginSheet(sheet)
    }
}

extension NSView {
    /// The theme of the window this view sits in: its active workspace's
    /// theme, else the global one. A view outside a main window gets the
    /// global theme.
    var booTheme: TerminalTheme {
        (window?.windowController as? MainWindowController)?.effectiveTheme ?? AppSettings.shared.theme
    }
}
