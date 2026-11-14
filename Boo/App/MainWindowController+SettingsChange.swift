import Cocoa

// MARK: - Settings Changes

extension MainWindowController {
    /// Apply a `.settingsChanged` notification to this window; nil topic means everything changed.
    func applySettingsChange(_ topic: SettingsTopic?) {
        // Socket broadcasts and AppStore theme are app-wide: WindowManager
        // handles them once, not per window.

        // Theme changes: refresh chrome colors, pane backgrounds, sidebar, status bar
        if topic == nil || topic == .theme {
            let theme = AppSettings.shared.theme
            self.window?.backgroundColor = theme.windowBackdrop
            self.window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            self.window?.contentView?.layer?.backgroundColor = theme.windowBackdrop.cgColor
            self.sidebarContainer.layer?.backgroundColor = theme.sidebarBg.cgColor
            // splitContainer stays clear — panes are the islands (see SplitContainerView.init)
            self.mainSplitView.needsDisplay = true
            // A refresh, not just a redraw: workspace colours resolve
            // against the theme palette.
            self.refreshToolbar()
            self.statusBar.needsDisplay = true
            // Island borders are layer strokes, not drawn in `draw(_:)`,
            // so they need an explicit refresh on theme change.
            // Toolbar, status bar and the side workspace bar carry no
            // border — they are bare strips.
            IslandMetrics.refreshBorder(self.sidebarContainer, color: theme.sidebarBorder)
            self.sideWorkspaceBar?.needsDisplay = true
            for (_, pv) in self.paneViews {
                pv.layer?.backgroundColor = theme.background.nsColor.cgColor
                // Pane island stroke is restyled inside updateOverlayColors()
                // (via syncIslandStroke), which also honours the accent tint
                // while an activity frame is showing.
                pv.updateOverlayColors()
                pv.updateFindBarTheme()
                pv.needsLayout = true
                pv.needsDisplay = true
            }
            // Rebuild plugin sidebar to pick up new theme
            if let ctx = self.pluginRegistry.lastContext {
                self.cachedDetailViews.removeAll()
                self.rebuildSidebarTabs(context: ctx)
            }
        }

        // Group changes reorder this window via the refresh's clustering pass.
        if topic == .workspaceGroups {
            self.refreshToolbar()
        }

        // Status bar changes
        if topic == nil || topic == .statusBar {
            self.statusBar.needsDisplay = true
        }

        // Layout changes: sidebar/workspace bar position, density
        if topic == nil || topic == .layout {
            self.statusBarHeightConstraint?.constant = DensityMetrics.current.statusBarHeight
            self.statusBar.needsDisplay = true
            let newWsBarPos = AppSettings.shared.workspaceBarPosition
            if newWsBarPos != self.currentWorkspaceBarPosition {
                self.currentWorkspaceBarPosition = newWsBarPos
                self.rebuildWorkspaceBarLayout()
                let headerHeight = IslandMetrics.toolbarHeight(for: newWsBarPos)
                self.toolbarHeightConstraint?.constant = headerHeight
                if let w = self.window {
                    w.contentView?.layoutSubtreeIfNeeded()
                    TrafficLightPositioner.setHeaderHeight(headerHeight, for: w)
                }
                self.toolbar.needsDisplay = true
            }
            self.refreshWorkspaceOverrides()
            // Tab bar position changed — swap constraints and re-install content views
            self.applySidebarTabBarPositionConstraints()
            if let ctx = self.pluginRegistry.lastContext {
                self.cachedDetailViews.removeAll()
                self.removeAllPluginContent()
                self.rebuildSidebarTabs(context: ctx)
            }
            self.sidebarController.persistLiveState(rememberAsDefault: false)
            self.sidebarController.applyRestoredState(self.sidebarController.resolveEffectiveSidebarState())
        }

        // Plugin changes: deactivate any now-disabled plugins and run a fresh cycle.
        if topic == .plugins {
            let disabled = AppSettings.shared.disabledPluginIDsSet
            // Deactivate plugins that just got disabled
            for plugin in self.pluginRegistry.plugins where disabled.contains(plugin.pluginID) {
                self.pluginRegistry.deactivatePlugin(plugin.pluginID)
                self.cachedDetailViews.removeValue(forKey: plugin.pluginID)
            }
            self.pluginRegistry.clearChangeDetection()
        }

        // Explorer/plugin/font changes: refresh sidebar
        if topic == nil || topic == .explorer || topic == .sidebarFont || topic == .plugins {
            if topic == .sidebarFont, let ctx = self.pluginRegistry.lastContext {
                if self.sidebarVisible {
                    self.cachedDetailViews.removeAll()
                    self.rebuildSidebarTabs(context: ctx)
                }
            } else {
                self.runPluginCycle(reason: .focusChanged)
            }
        }
    }
}
