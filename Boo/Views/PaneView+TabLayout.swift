import Cocoa

// MARK: - Tab Measurement & Layout

extension PaneView {
    private static let tabMeasureFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let tabSubtitleMeasureFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// Whether the tab draws a leading icon (content-type icon or process icon)
    /// before its title — `drawSingleTab` gates on the same predicate, so the
    /// measured slot and the drawn content can't disagree.
    func tabHasLeadingIcon(_ tab: Pane.Tab) -> Bool {
        if tab.contentType != .terminal { return true }
        let process = tab.state.foregroundProcess
        return !process.isEmpty && !ProcessIcon.isShell(process) && ProcessIcon.icon(for: process) != nil
    }

    /// Measure the natural width of a single tab slot based on its content:
    /// lead-in + optional icon + title + close/dot zone + pill insets.
    func measuredTabWidth(for tab: Pane.Tab) -> CGFloat {
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        var textW = ceil(title.size(withAttributes: [.font: Self.tabMeasureFont]).width)
        if let subtitle = Self.tabDisplaySubtitle(tab: tab) {
            textW += ceil(
                ("  " + subtitle as NSString).size(withAttributes: [.font: Self.tabSubtitleMeasureFont]).width)
        }
        var natural = textW + Self.tabTextLeadIn + Self.tabCloseHitZone + Self.tabPillInsetX * 2
        if tabHasLeadingIcon(tab) { natural += Self.tabIconAdvance }
        return min(tabMaxWidth, max(tabMinWidth, natural))
    }

    /// Compute all tab widths at once (memoized until tab content changes).
    /// Slot width per tab. The first tab of a group also holds the group's
    /// chip; tabs of a collapsed group get 0 (the first keeps the chip).
    func allTabWidths() -> [CGFloat] {
        let key = pane.tabs.indices.map { i -> String in
            let tab = pane.tabs[i]
            var k =
                "\(Self.tabDisplayTitle(tab: tab))|\(Self.tabDisplaySubtitle(tab: tab) ?? "")|\(tabHasLeadingIcon(tab))"
            if let group = pane.group(id: tab.groupID) {
                k += "|\(group.id)|\(group.isCollapsed)|\(pane.isFirstTabOfGroup(at: i) ? group.name : "")"
            }
            return k
        }
        if let cached = _tabWidthsCache, cached.key == key { return cached.widths }
        let widths = pane.tabs.indices.map { i -> CGFloat in
            let chip = groupChipWidth(at: i)
            if pane.isTabHidden(at: i) { return chip }
            return chip + measuredTabWidth(for: pane.tabs[i])
        }
        _tabWidthsCache = (key, widths)
        return widths
    }

    /// Slot start x of tab `index` in scroll mode, before scroll offset.
    func tabStartX(_ index: Int, widths: [CGFloat]) -> CGFloat {
        Self.tabBarSideInset + widths.prefix(index).reduce(0, +)
    }

    /// Computed tab bar height — row stride per row plus the vertical bar
    /// insets, so the outermost pills keep the same margin to the pane edge
    /// as they keep between each other.
    var tabBarHeight: CGFloat {
        let mode = AppSettings.shared.tabOverflowMode
        if mode == .vertical { return 0 }
        let rows = mode == .wrap ? wrapRowCount() : 1
        return singleRowTabHeight * CGFloat(rows) + Self.tabBarSideInset * 2
    }

    struct TabLayout {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    /// Compute wrap-mode layout: pills keep their natural width and flow onto
    /// the next row when the current one is full — no stretching.
    func wrapLayout() -> [TabLayout] {
        wrapLayout(widths: allTabWidths())
    }

    func wrapLayout(widths: [CGFloat]) -> [TabLayout] {
        let inset = Self.tabBarSideInset
        let availW = bounds.width - inset * 2
        guard !widths.isEmpty, availW > 0 else { return [] }

        if let c = _wrapLayoutCache, c.widths == widths, c.boundsWidth == bounds.width {
            return c.layouts
        }

        var layouts: [TabLayout] = []
        var cx: CGFloat = inset
        var row = 0
        for w in widths {
            if cx - inset + w > availW && cx > inset {
                row += 1
                cx = inset
            }
            layouts.append(TabLayout(x: cx, y: inset + CGFloat(row) * singleRowTabHeight, width: w))
            cx += w
        }
        _wrapLayoutCache = (widths, bounds.width, layouts)
        return layouts
    }

    /// Whether the `+` button fits after the last tab of the given layout, or
    /// has to drop onto a row of its own. Shared by draw, hit-test, and row count.
    func plusFitsOnLastRow(_ layouts: [TabLayout]) -> Bool {
        guard let last = layouts.last else { return true }
        return last.x + last.width + tabBarButtonsWidth <= bounds.width - Self.tabBarSideInset
    }

    /// Number of rows needed in wrap mode.
    private func wrapRowCount() -> Int {
        let layouts = wrapLayout()
        guard let last = layouts.last else { return 1 }
        var rows = Int((last.y - Self.tabBarSideInset) / singleRowTabHeight) + 1
        if !plusFitsOnLastRow(layouts) { rows += 1 }
        return rows
    }
}
