import Cocoa
import SwiftUI

// MARK: - Tab Management

extension PaneView {
    /// Activate a tab unconditionally — used after insertTab which already
    /// sets activeTabIndex, making the normal guard in activateTab skip.
    func forceActivateTab(_ index: Int) {
        dismissFindBarIfNeeded(forTabAt: index)
        storeCurrentView()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        focusActiveView()
        if pane.activeTab != nil {
            paneDelegate?.paneView(self, didFocus: paneID)
        }
    }

    func activateTab(_ index: Int) {
        guard index != pane.activeTabIndex else { return }
        dismissFindBarIfNeeded(forTabAt: index)
        storeCurrentView()
        pane.setActivity(false, at: index)
        updateActivityBorder()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        focusActiveView()
        if let tab = pane.activeTab {
            debugLog(
                "[TabSwitch] activateTab(\(index)) pane=\(paneID.uuidString.prefix(8)) title=\(tab.title) process=\(tab.state.foregroundProcess)"
            )
            // Notify delegate of the tab switch so it can restore the bridge
            // state from the tab model. We do NOT fire didChangeDirectory here
            // because the bridge would misinterpret the stale local CWD (set
            // before SSH started) as evidence the remote session ended.
            paneDelegate?.paneView(self, didFocus: paneID)
        }
    }

    /// Focus the appropriate view based on the active tab's content type.
    func focusActiveView() {
        guard let tab = pane.activeTab else { return }
        if tab.contentType == .terminal {
            window?.makeFirstResponder(ghosttyView)
        } else {
            window?.makeFirstResponder(activeContentView)
        }
    }

    @discardableResult
    func addNewTab(
        workingDirectory: String, launch: LaunchSpec? = nil, group: UUID? = nil, focus: Bool = true
    ) -> UUID? {
        addNewTab(
            contentType: .terminal, workingDirectory: workingDirectory, launch: launch, group: group, focus: focus)
    }

    /// Add a new tab with a specific content type. With `group`, it joins
    /// that group at its end instead of opening at the end of the bar.
    @discardableResult
    func addNewTab(
        contentType: ContentType, workingDirectory: String = "~", url: URL? = nil, launch: LaunchSpec? = nil,
        group: UUID? = nil, focus: Bool = true
    ) -> UUID? {
        if pane.tmuxOwned, let paneDelegate {
            return paneDelegate.paneView(
                self, redirectNewTab: contentType, workingDirectory: workingDirectory, url: url, launch: launch)
        }
        storeCurrentView()
        lastAutoScrolledTabIndex = -1

        switch contentType {
        case .terminal:
            _ = pane.addTab(contentType: .terminal, workingDirectory: workingDirectory)
            if let launch, let tab = pane.tabs.last { GhosttyView.pendingLaunch[tab.id] = launch }
        case .browser:
            _ = pane.addTab(contentType: .browser, workingDirectory: workingDirectory, title: url?.host ?? "New Tab")
        case .editor:
            _ = pane.addTab(contentType: .editor, workingDirectory: workingDirectory)
        case .imageViewer:
            _ = pane.addTab(contentType: .imageViewer, workingDirectory: workingDirectory)
        case .markdownPreview:
            _ = pane.addTab(contentType: .markdownPreview, workingDirectory: workingDirectory)
        case .castPlayer:
            _ = pane.addTab(contentType: .castPlayer, workingDirectory: workingDirectory)
        case .pluginView:
            _ = pane.addTab(contentType: .pluginView, workingDirectory: workingDirectory, title: "Panel")
        }
        if let group, pane.group(id: group) != nil {
            pane.addTab(at: pane.tabs.count - 1, toGroup: group)
            WindowManager.shared.saveSessionSoon()
        }

        startActiveSession()
        // Trigger single layout + display pass, not redundant calls
        needsLayout = true

        // For browser tabs, navigate to the URL before focus
        if contentType == .browser, let url = url, let browserView = activeContentView as? BrowserContentView {
            browserView.navigate(to: url)
        }
        // `focus: false` shows the tab in this pane but leaves keyboard focus
        // (and the workspace's active pane) where it is.
        guard focus else { return pane.activeTab?.id }
        DispatchQueue.main.async { [weak self] in
            self?.focusActiveView()
        }

        paneDelegate?.paneView(self, didFocus: paneID)
        return pane.activeTab?.id
    }

    /// Group of the active tab: where a tab the user opens from it goes.
    var activeGroupID: UUID? {
        AppSettings.shared.newTabsJoinActiveGroup ? pane.activeTab?.groupID : nil
    }

    /// Add a plugin-owned SwiftUI view in a new tab.
    @discardableResult
    func addPluginViewTab(view: AnyView, title: String, icon: String, workingDirectory: String = "~") -> UUID? {
        if pane.tmuxOwned, let paneDelegate {
            return paneDelegate.paneView(self, redirectPluginView: view, title: title, icon: icon)
        }
        storeCurrentView()
        lastAutoScrolledTabIndex = -1

        // A tab about a folder (review, diff) keeps it as its cwd, so the
        // sidebar's Git and Files panels stay on that repository.
        _ = pane.addTab(contentType: .pluginView, workingDirectory: workingDirectory, title: title)
        pane.updateContentState(
            at: pane.tabs.count - 1, .pluginView(PluginViewContentState(title: title, iconSymbol: icon)))

        startActiveSession()
        needsLayout = true

        // Replace the placeholder content view with the real plugin view.
        // The factory created a placeholder; swap it out before layout.
        activeContentView?.cleanup()
        activeContentView?.removeFromSuperview()
        let pluginView = PluginTabContentView(view: view, title: title, icon: icon)
        // This path assigns activeContentView directly rather than going through
        // startContentSession, so stamp the owning tab here or the view would be
        // unidentifiable when the pane later caches or retires it.
        pluginView.tabID = pane.tabs.last?.id
        activeContentView = pluginView
        addSubview(pluginView)
        needsLayout = true

        window?.makeFirstResponder(pluginView)
        paneDelegate?.paneView(self, didFocus: paneID)
        return pane.tabs.last?.id
    }

    func closeTab(at index: Int) {
        lastAutoScrolledTabIndex = -1
        guard index >= 0, index < pane.tabs.count else { return }
        let tabID = pane.tabs[index].id
        let tab = pane.tabs[index]
        cancelPendingDebounces(for: tabID)
        CommandLog.shared.tabClosed(tabID)

        // Clean up the appropriate view type
        if tab.contentType == .terminal {
            if let cached = tabViews.removeValue(forKey: tabID) {
                cached.discard()
            }
            if pane.activeTabIndex == index {
                ghosttyView?.destroy()
                scrollWrapper?.removeFromSuperview()
                scrollWrapper = nil
                ghosttyView = nil
            }
        } else {
            if let cv = contentViews.removeValue(forKey: tabID) { cv.cleanup() }
            if pane.activeTabIndex == index {
                activeContentView?.cleanup()
                activeContentView?.removeFromSuperview()
                activeContentView = nil
            }
        }

        let wasActive = index == pane.activeTabIndex
        pane.removeTab(at: index)
        if pane.tabs.isEmpty { return }
        if wasActive {
            startActiveSession()
            layoutTerminalView()
            // Focus the appropriate view
            if let newTab = pane.activeTab {
                if newTab.contentType == .terminal {
                    window?.makeFirstResponder(ghosttyView)
                } else {
                    window?.makeFirstResponder(activeContentView)
                }
            }
            if pane.activeTab != nil {
                // Restore bridge state from the newly active tab, same as activateTab.
                paneDelegate?.paneView(self, didFocus: paneID)
            }
        } else {
            layoutTerminalView()
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Drop pending debounced title/CWD updates for one tab (on close).
    /// Updates are keyed per tab, so a tab *switch* needs no cancellation —
    /// each pending item resolves against its own tab.
    private func cancelPendingDebounces(for tabID: UUID) {
        titleDebounces.removeValue(forKey: tabID)?.cancel()
        pendingTitles.removeValue(forKey: tabID)
        cwdDebounces.removeValue(forKey: tabID)?.cancel()
        pendingCwds.removeValue(forKey: tabID)
    }

    private func storeCurrentView() {
        // Each view is cached under the tab it belongs to (`tabID`), never `pane.activeTab` —
        // mid-drop those disagree and the just-transferred view would be overwritten.
        retireDisplayedTerminal()

        if let cv = activeContentView {
            activeContentView = nil
            retire(cv)
        }
    }

    func persistContentStateToModel() {
        for (index, tab) in pane.tabs.enumerated() where tab.contentType != .terminal {
            // The view's own tab, not `pane.activeTab` — a session save right after a
            // cross-pane drop would otherwise persist the displayed view's state under
            // the incoming tab's index.
            if let activeContentView, activeContentView.tabID == tab.id {
                pane.updateContentState(at: index, activeContentView.saveState())
            } else if let contentView = contentViews[tab.id] {
                pane.updateContentState(at: index, contentView.saveState())
            }
        }
    }

    var tabCount: Int { pane.tabs.count }
}
