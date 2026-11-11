import Cocoa

// MARK: - Find Bar

extension PaneView {
    func showFindBar() {
        let page = activeContentView as? PageFindable
        guard pane.activeTab?.contentType == .terminal || page != nil else { return }
        guard findBar == nil else {
            findBar?.focusField()
            return
        }
        searchMatchTotal = -1
        let bar = FindBarView()
        if let page {
            findPage = page
            bar.onSearch = { [weak page] needle in page?.find(needle) }
            bar.onNavigate = { [weak page] next in page?.findNext(next) }
            page.onFindMatches = { [weak self] selected, total in
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

    /// End whichever search the find bar is driving: page find in a browser or
    /// markdown tab, or the Ghostty search otherwise.
    private func endActiveSearch() {
        if let page = findPage {
            page.endFind()
            page.onFindMatches = nil
            findPage = nil
        } else {
            ghosttyView?.endSearch()
        }
    }

    func dismissFindBarIfNeeded(forTabAt index: Int) {
        guard isFindBarVisible else { return }
        let targetType = index < pane.tabs.count ? pane.tabs[index].contentType : nil
        if targetType != .terminal || findPage != nil {
            tearDownFindBar()
        }
    }
}
