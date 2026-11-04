import Cocoa

// MARK: - Find Bar

extension PaneView {
    func showFindBar() {
        let browser = activeContentView as? BrowserContentView
        guard pane.activeTab?.contentType == .terminal || browser != nil else { return }
        guard findBar == nil else {
            findBar?.focusField()
            return
        }
        searchMatchTotal = -1
        let bar = FindBarView()
        if let browser {
            findBrowser = browser
            bar.onSearch = { [weak browser] needle in browser?.find(needle) }
            bar.onNavigate = { [weak browser] next in browser?.findNext(next) }
            browser.onFindMatches = { [weak self] selected, total in
                self?.findBar?.updateMatches(selected: selected, total: total)
            }
        } else {
            bar.onSearch = { [weak self] needle in
                self?.ghosttyView?.updateSearch(needle: needle)
            }
            bar.onNavigate = { [weak self] next in
                self?.ghosttyView?.navigateSearch(next: next)
            }
        }
        bar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        findBar = bar
        addSubview(bar)
        layoutTerminalView()
        bar.focusField()
    }

    func hideFindBar() {
        guard findBar != nil else { return }
        tearDownFindBar()
        layoutTerminalView()
        focusActiveView()
    }

    private func tearDownFindBar() {
        endActiveSearch()
        findBar?.removeFromSuperview()
        findBar = nil
        searchMatchTotal = -1
    }

    /// End whichever search the find bar is driving: page find in a browser
    /// tab, or the Ghostty search otherwise.
    private func endActiveSearch() {
        if let browser = findBrowser {
            browser.endFind()
            browser.onFindMatches = nil
            findBrowser = nil
        } else {
            ghosttyView?.endSearch()
        }
    }

    func dismissFindBarIfNeeded(forTabAt index: Int) {
        guard isFindBarVisible else { return }
        let targetType = index < pane.tabs.count ? pane.tabs[index].contentType : nil
        if targetType != .terminal || findBrowser != nil {
            tearDownFindBar()
        }
    }
}
