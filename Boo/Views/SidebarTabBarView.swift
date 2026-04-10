import Cocoa

/// Tab bar shown at the top (or bottom) of the sidebar — one tab per enabled plugin.
/// Tabs are set by the controller after collecting plugin contributions.
class SidebarTabBarView: NSView {
    static let height: CGFloat = 26

    /// Width of each tab icon button.
    private let tabW: CGFloat = 32
    /// Width reserved for the overflow "···" button when tabs don't fit.
    private let overflowW: CGFloat = 32

    /// Ordered list of plugin sidebar tabs. Set by the controller after plugin collection.
    var sidebarTabs: [SidebarTab] = [] {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    var selectedTab: SidebarTabID = SidebarTabID("")
    var onTabSelected: ((SidebarTabID) -> Void)?
    /// Called when user right-clicks and chooses to disable a tab.
    var onTabDisabled: ((SidebarTabID) -> Void)?
    /// Called when user toggles a section on/off from the right-click menu.
    var onToggleSection: ((SidebarTabID, String) -> Void)?
    /// Called when tabs are reordered via drag.
    var onTabsReordered: (([SidebarTabID]) -> Void)?

    private var hoveredTab: SidebarTabID?
    private var tabRects: [SidebarTabID: NSRect] = [:]
    private var overflowRect: NSRect = .zero
    /// Tabs visible in the bar (fit within available width).
    private var visibleTabs: [SidebarTab] = []
    /// Tabs hidden behind the overflow "···" button.
    private var overflowTabs: [SidebarTab] = []

    // Drag state
    private var draggedTabID: SidebarTabID?
    private var dragStartX: CGFloat = 0
    private var dragCurrentX: CGFloat = 0
    /// True once the drag threshold has been crossed.
    private var isDragging: Bool = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                owner: self,
                userInfo: nil))
    }

    override func layout() {
        super.layout()
        rebuildTabRects()
        rebuildTooltips()
    }

    private func rebuildTabRects() {
        tabRects.removeAll()
        visibleTabs = []
        overflowTabs = []

        let needsOverflow = CGFloat(sidebarTabs.count) * tabW > bounds.width
        let available = needsOverflow ? bounds.width - overflowW : bounds.width

        var x: CGFloat = 0
        for tab in sidebarTabs {
            if x + tabW <= available {
                tabRects[tab.id] = NSRect(x: x, y: 0, width: tabW, height: bounds.height - 1)
                visibleTabs.append(tab)
                x += tabW
            } else {
                overflowTabs.append(tab)
            }
        }

        if needsOverflow {
            overflowRect = NSRect(
                x: bounds.width - overflowW, y: 0, width: overflowW, height: bounds.height - 1)
        } else {
            overflowRect = .zero
        }
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        for tab in visibleTabs {
            guard let rect = tabRects[tab.id] else { continue }
            addToolTip(rect, owner: tab.label as NSString, userData: nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = tabRects.first(where: { $0.value.contains(point) })?.key
        if hit != hoveredTab {
            hoveredTab = hit
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTab != nil {
            hoveredTab = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Overflow button click
        if !overflowRect.isEmpty && overflowRect.contains(point) {
            showOverflowMenu(event: event)
            return
        }

        if let tab = tabRects.first(where: { $0.value.contains(point) })?.key {
            if tab != selectedTab {
                selectedTab = tab
                needsDisplay = true
                onTabSelected?(tab)
            }
            draggedTabID = tab
            dragStartX = point.x
            dragCurrentX = point.x
            isDragging = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggedTabID != nil else { return }
        dragCurrentX = convert(event.locationInWindow, from: nil).x
        if !isDragging && abs(dragCurrentX - dragStartX) > 4 {
            isDragging = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let draggedID = draggedTabID else { return }
        let point = convert(event.locationInWindow, from: nil)

        if isDragging {
            let dropIndex = dropIndexFor(x: point.x)
            if let sourceIndex = sidebarTabs.firstIndex(where: { $0.id == draggedID }),
                dropIndex != sourceIndex
            {
                var reordered = sidebarTabs
                let tab = reordered.remove(at: sourceIndex)
                let target = min(dropIndex, reordered.count)
                reordered.insert(tab, at: target)
                sidebarTabs = reordered
                selectedTab = draggedID
                onTabsReordered?(reordered.map(\.id))
            }
        }

        draggedTabID = nil
        isDragging = false
        needsDisplay = true
    }

    private func dropIndexFor(x: CGFloat) -> Int {
        let index = Int((x + tabW / 2) / tabW)
        return max(0, min(index, sidebarTabs.count))
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tabID = tabRects.first(where: { $0.value.contains(point) })?.key,
            let tab = sidebarTabs.first(where: { $0.id == tabID })
        else { return }

        let menu = NSMenu()

        if tab.sections.count > 1 {
            // Count how many sections are currently visible
            let hiddenSectionIDs = tab.sections.filter { section in
                AppSettings.shared.pluginBool(tabID.id, "hiddenSection_\(section.id)", default: false)
            }.map(\.id)
            let visibleCount = tab.sections.count - hiddenSectionIDs.count

            for section in tab.sections {
                let isHidden = hiddenSectionIDs.contains(section.id)
                let isLastVisible = !isHidden && visibleCount == 1

                let item = NSMenuItem(
                    title: section.name,
                    action: isLastVisible ? nil : #selector(toggleSectionFromMenu(_:)),
                    keyEquivalent: "")
                item.state = isHidden ? .off : .on
                item.representedObject = [tabID, section.id] as [Any]
                item.target = self
                if isLastVisible {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        let disableItem = NSMenuItem(
            title: "Disable \"\(tab.label)\"",
            action: #selector(disableTabFromMenu(_:)),
            keyEquivalent: "")
        disableItem.representedObject = tabID
        disableItem.target = self
        menu.addItem(disableItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleSectionFromMenu(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any],
            let tabID = pair.first as? SidebarTabID,
            let sectionID = pair.last as? String
        else { return }
        onToggleSection?(tabID, sectionID)
    }

    @objc private func disableTabFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? SidebarTabID else { return }
        onTabDisabled?(tabID)
    }

    private func showOverflowMenu(event: NSEvent) {
        let menu = NSMenu()
        for tab in overflowTabs {
            let item = NSMenuItem(
                title: tab.label,
                action: #selector(selectOverflowTabFromMenu(_:)),
                keyEquivalent: "")
            item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            item.representedObject = tab.id
            item.target = self
            if tab.id == selectedTab {
                item.state = .on
            }
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func selectOverflowTabFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? SidebarTabID else { return }
        if tabID != selectedTab {
            selectedTab = tabID
            needsDisplay = true
            onTabSelected?(tabID)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let iconSize: CGFloat = 18

        ctx.setFillColor(theme.sidebarBg.cgColor)
        ctx.fill(bounds)

        // Bottom separator line
        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))

        // Compute drop index for indicator while dragging
        let dropIndex: Int? = isDragging ? dropIndexFor(x: dragCurrentX) : nil

        for (index, tab) in sidebarTabs.enumerated() {
            guard let tabRect = tabRects[tab.id] else { continue }
            let isSelected = tab.id == selectedTab
            let isHovered = tab.id == hoveredTab && !isSelected
            let isBeingDragged = isDragging && tab.id == draggedTabID

            if isBeingDragged {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.04).cgColor)
                let r = CGRect(
                    x: tabRect.minX + 4, y: tabRect.minY + 3,
                    width: tabRect.width - 8, height: tabRect.height - 6)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()

                if let img = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil) {
                    let config = NSImage.SymbolConfiguration(pointSize: iconSize * 0.75, weight: .regular)
                        .applying(.init(paletteColors: [theme.chromeMuted.withAlphaComponent(0.2)]))
                    if let tinted = img.withSymbolConfiguration(config) {
                        let imgSize = tinted.size
                        let iconX = tabRect.midX - imgSize.width / 2
                        let iconY = tabRect.minY + (tabRect.height - imgSize.height) / 2
                        tinted.draw(
                            in: NSRect(x: iconX, y: iconY, width: imgSize.width, height: imgSize.height))
                    }
                }
                continue
            }

            if isHovered {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.08).cgColor)
                let r = CGRect(
                    x: tabRect.minX + 4, y: tabRect.minY + 3,
                    width: tabRect.width - 8, height: tabRect.height - 6)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            }

            if isSelected {
                ctx.setFillColor(theme.accentColor.withAlphaComponent(0.15).cgColor)
                let r = CGRect(
                    x: tabRect.minX + 4, y: tabRect.minY + 3,
                    width: tabRect.width - 8, height: tabRect.height - 6)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            }

            let iconColor =
                isSelected ? theme.accentColor : theme.chromeMuted.withAlphaComponent(0.6)
            if let img = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.label) {
                let config = NSImage.SymbolConfiguration(pointSize: iconSize * 0.75, weight: .regular)
                    .applying(.init(paletteColors: [iconColor]))
                let tinted = img.withSymbolConfiguration(config) ?? img
                let imgSize = tinted.size
                let iconX = tabRect.midX - imgSize.width / 2
                let iconY = tabRect.minY + (tabRect.height - imgSize.height) / 2
                tinted.draw(in: NSRect(x: iconX, y: iconY, width: imgSize.width, height: imgSize.height))
            }

            if let di = dropIndex, di == index {
                drawDropIndicator(at: tabRect.minX, ctx: ctx, theme: theme)
            }
        }

        // Drop indicator at the end of visible tabs
        if let di = dropIndex, di == visibleTabs.count {
            let endX = CGFloat(visibleTabs.count) * tabW
            drawDropIndicator(at: endX, ctx: ctx, theme: theme)
        }

        // Overflow "···" button
        if !overflowRect.isEmpty {
            let hasSelectedOverflow = overflowTabs.contains(where: { $0.id == selectedTab })
            let overflowColor: NSColor =
                hasSelectedOverflow ? theme.accentColor : theme.chromeMuted.withAlphaComponent(0.6)

            if let img = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More tabs") {
                let config = NSImage.SymbolConfiguration(pointSize: iconSize * 0.75, weight: .regular)
                    .applying(.init(paletteColors: [overflowColor]))
                if let tinted = img.withSymbolConfiguration(config) {
                    let imgSize = tinted.size
                    let iconX = overflowRect.midX - imgSize.width / 2
                    let iconY = overflowRect.minY + (overflowRect.height - imgSize.height) / 2
                    tinted.draw(
                        in: NSRect(x: iconX, y: iconY, width: imgSize.width, height: imgSize.height))
                }
            }

            // Accent background when active tab is in overflow
            if hasSelectedOverflow {
                ctx.setFillColor(theme.accentColor.withAlphaComponent(0.15).cgColor)
                let r = CGRect(
                    x: overflowRect.minX + 4, y: overflowRect.minY + 3,
                    width: overflowRect.width - 8, height: overflowRect.height - 6)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            }
        }

        // Ghost icon: floating tab icon that follows the cursor
        if isDragging, let draggedID = draggedTabID,
            let tab = sidebarTabs.first(where: { $0.id == draggedID })
        {
            let ghostSize: CGFloat = 28
            let ghostX = dragCurrentX - ghostSize / 2
            let ghostY = (bounds.height - ghostSize) / 2 - 2

            ctx.setFillColor(theme.chromeBg.withAlphaComponent(0.88).cgColor)
            let ghostRect = CGRect(x: ghostX, y: ghostY, width: ghostSize, height: ghostSize)
            ctx.addPath(
                CGPath(
                    roundedRect: ghostRect.insetBy(dx: -1, dy: -1),
                    cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()

            ctx.setStrokeColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(
                CGPath(
                    roundedRect: ghostRect.insetBy(dx: -1, dy: -1),
                    cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.strokePath()

            if let img = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(
                    pointSize: iconSize * 0.75, weight: .regular
                ).applying(.init(paletteColors: [theme.accentColor]))
                if let tinted = img.withSymbolConfiguration(config) {
                    let imgSize = tinted.size
                    let iconX = ghostX + ghostSize / 2 - imgSize.width / 2
                    let iconY = ghostY + ghostSize / 2 - imgSize.height / 2
                    ctx.saveGState()
                    ctx.setAlpha(0.9)
                    tinted.draw(
                        in: NSRect(x: iconX, y: iconY, width: imgSize.width, height: imgSize.height))
                    ctx.restoreGState()
                }
            }
        }
    }

    private func drawDropIndicator(at x: CGFloat, ctx: CGContext, theme: TerminalTheme) {
        let indicatorH = bounds.height - 8
        let indicatorY = (bounds.height - indicatorH) / 2
        ctx.setFillColor(theme.accentColor.cgColor)
        ctx.fill(CGRect(x: x - 1, y: indicatorY, width: 2, height: indicatorH))
    }
}
