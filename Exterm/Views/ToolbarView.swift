import Cocoa

protocol ToolbarViewDelegate: AnyObject {
    func toolbar(_ toolbar: ToolbarView, didSelectWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didCloseWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didSelectTabAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didCloseTabAt index: Int)
    func toolbarDidRequestNewTab(_ toolbar: ToolbarView)
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView)
    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String)
    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor)
    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor)
    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int)
}

class ToolbarView: NSView {
    weak var delegate: ToolbarViewDelegate?

    struct WorkspaceItem {
        let name: String
        let isActive: Bool
        let resolvedColor: NSColor?  // nil = no color
        let isPinned: Bool
    }

    struct TabItem {
        let title: String
        let isActive: Bool
    }

    private(set) var workspaces: [WorkspaceItem] = []
    private(set) var tabs: [TabItem] = []
    private var sidebarVisible = true
    private var tabScrollOffset: CGFloat = 0
    private var workspaceScrollOffset: CGFloat = 0

    private let barHeight: CGFloat = 38
    private let tabFixedWidth: CGFloat = 140

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func update(workspaces: [WorkspaceItem], tabs: [TabItem], sidebarVisible: Bool) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.sidebarVisible = sidebarVisible
        scrollToActiveWorkspace()
        clampScrollOffset()
        needsDisplay = true
    }

    /// Ensure the active workspace pill is visible in the scroll area.
    private func scrollToActiveWorkspace() {
        guard let activeIndex = workspaces.firstIndex(where: { $0.isActive }) else { return }
        var x: CGFloat = 0
        for i in 0..<activeIndex {
            x += measureWorkspace(workspaces[i]) + 6
        }
        let activeWidth = measureWorkspace(workspaces[activeIndex]) + 6
        let visibleStart = workspaceScrollOffset
        let visibleEnd = workspaceScrollOffset + workspaceZoneWidth

        if x < visibleStart {
            workspaceScrollOffset = x
        } else if x + activeWidth > visibleEnd {
            workspaceScrollOffset = x + activeWidth - workspaceZoneWidth
        }
    }

    // MARK: - Layout constants

    private let trafficLightWidth: CGFloat = 78
    private let sidebarButtonWidth: CGFloat = 38
    private let dividerWidth: CGFloat = 1
    private let zoneGap: CGFloat = 12

    /// Total content width of all workspace pills.
    private var totalWorkspaceContentWidth: CGFloat {
        var w: CGFloat = 0
        for ws in workspaces {
            w += measureWorkspace(ws) + 6
        }
        return w
    }

    /// The workspace zone fills all space between traffic lights and the sidebar button.
    private var workspaceZoneMaxWidth: CGFloat {
        max(60, bounds.width - trafficLightWidth - sidebarButtonWidth - zoneGap)
    }

    /// Visible width of the workspace zone — shrinks to content if it fits, else fills available space.
    private var workspaceZoneWidth: CGFloat {
        min(totalWorkspaceContentWidth, workspaceZoneMaxWidth)
    }

    // Workspace zone: after traffic lights, up to sidebar button
    private var workspaceZoneEnd: CGFloat {
        trafficLightWidth + workspaceZoneWidth
    }

    private var maxWorkspaceScrollOffset: CGFloat {
        max(0, totalWorkspaceContentWidth - workspaceZoneWidth)
    }

    // Tab zone (unused when tabs are in PaneView, kept for compatibility)
    private var tabZoneStart: CGFloat {
        workspaceZoneEnd + zoneGap + dividerWidth + zoneGap
    }

    private var tabZoneEnd: CGFloat {
        bounds.width - sidebarButtonWidth - 4
    }

    private var tabZoneWidth: CGFloat {
        max(0, tabZoneEnd - tabZoneStart)
    }

    private var totalTabContentWidth: CGFloat {
        CGFloat(tabs.count) * tabFixedWidth + 28 // +28 for plus button
    }

    private var maxScrollOffset: CGFloat {
        max(0, totalTabContentWidth - tabZoneWidth)
    }

    private func measureWorkspace(_ ws: WorkspaceItem) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: ws.isActive ? .medium : .regular)
        ]
        var w = (ws.name as NSString).size(withAttributes: attrs).width + 20
        if ws.isPinned { w += 12 }
        return w
    }

    private func clampScrollOffset() {
        tabScrollOffset = min(max(0, tabScrollOffset), maxScrollOffset)
        workspaceScrollOffset = min(max(0, workspaceScrollOffset), maxWorkspaceScrollOffset)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Workspace zone scroll
        if point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap {
            workspaceScrollOffset -= event.scrollingDeltaX
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                workspaceScrollOffset += event.scrollingDeltaY
            }
            clampScrollOffset()
            needsDisplay = true
            return
        }

        // Tab zone scroll
        if point.x >= tabZoneStart && point.x <= tabZoneEnd {
            tabScrollOffset -= event.scrollingDeltaX
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                tabScrollOffset += event.scrollingDeltaY
            }
            clampScrollOffset()
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme

        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(bounds)

        // Subtle bottom separator
        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.3).cgColor)
        ctx.fill(CGRect(x: 0, y: barHeight - 0.5, width: bounds.width, height: 0.5))

        drawWorkspaces(ctx)
        drawSidebarButton(ctx)
    }

    private func drawWorkspaces(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme
        let zoneStart = trafficLightWidth
        let zoneEnd = workspaceZoneEnd
        let isScrollable = totalWorkspaceContentWidth > workspaceZoneWidth

        if isScrollable {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: zoneStart, y: 0, width: zoneEnd - zoneStart, height: barHeight))
        }

        var x = zoneStart - workspaceScrollOffset

        for ws in workspaces {
            let w = measureWorkspace(ws)
            let pillH: CGFloat = 24
            let pillY = (barHeight - pillH) / 2

            let wsColor = ws.resolvedColor

            let rect = CGRect(x: x, y: pillY, width: w, height: pillH)
            if let c = wsColor {
                ctx.setFillColor(c.withAlphaComponent(ws.isActive ? 0.25 : 0.12).cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if ws.isActive {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }

            var contentX = x + 8

            if ws.isPinned {
                let pinAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: ws.isActive ? theme.chromeText.withAlphaComponent(0.7) : theme.chromeMuted.withAlphaComponent(0.7)
                ]
                let pinStr = "\u{25C6}" as NSString
                let pinSize = pinStr.size(withAttributes: pinAttrs)
                pinStr.draw(at: NSPoint(x: contentX, y: (barHeight - pinSize.height) / 2), withAttributes: pinAttrs)
                contentX += 12
            }

            let textColor: NSColor
            if let c = wsColor, ws.isActive {
                textColor = NSColor(red: c.redComponent * 0.6 + 0.4, green: c.greenComponent * 0.6 + 0.4, blue: c.blueComponent * 0.6 + 0.4, alpha: 1)
            } else if ws.isActive {
                textColor = theme.chromeText
            } else if let c = wsColor {
                textColor = NSColor(red: c.redComponent * 0.5 + 0.2, green: c.greenComponent * 0.5 + 0.2, blue: c.blueComponent * 0.5 + 0.2, alpha: 1)
            } else {
                textColor = theme.chromeMuted
            }

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: ws.isActive ? .medium : .regular),
                .foregroundColor: textColor
            ]
            let nameSize = (ws.name as NSString).size(withAttributes: nameAttrs)
            (ws.name as NSString).draw(
                at: NSPoint(x: contentX, y: (barHeight - nameSize.height) / 2),
                withAttributes: nameAttrs
            )

            x += w + 6
        }

        if isScrollable {
            ctx.restoreGState()

            if workspaceScrollOffset > 0 {
                drawFadeEdge(ctx, at: zoneStart, width: 20, leftToRight: true)
            }
            if workspaceScrollOffset < maxWorkspaceScrollOffset {
                drawFadeEdge(ctx, at: zoneEnd - 20, width: 20, leftToRight: false)
            }
        }
    }

    private func drawDivider(_ ctx: CGContext) {
        let divX = workspaceZoneEnd + zoneGap
        ctx.setFillColor(CGColor(red: 45/255, green: 45/255, blue: 50/255, alpha: 0.6))
        ctx.fill(CGRect(x: divX, y: 10, width: dividerWidth, height: barHeight - 20))
    }

    private func drawTabs(_ ctx: CGContext) {
        guard !tabs.isEmpty else { return }

        let zoneStart = tabZoneStart
        let zoneEnd = tabZoneEnd

        // Clip to tab zone
        ctx.saveGState()
        ctx.clip(to: CGRect(x: zoneStart, y: 0, width: zoneEnd - zoneStart, height: barHeight))

        var x = zoneStart - tabScrollOffset

        for tab in tabs {
            let tabRect = CGRect(x: x + 2, y: 7, width: tabFixedWidth - 4, height: barHeight - 13)

            if tab.isActive {
                ctx.setFillColor(CGColor(red: 28/255, green: 28/255, blue: 31/255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: tabRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
                ctx.fillPath()

                // Subtle bottom accent
                let accentRect = CGRect(x: tabRect.minX + 12, y: tabRect.maxY - 2, width: tabRect.width - 24, height: 1.5)
                ctx.setFillColor(CGColor(red: 77/255, green: 143/255, blue: 232/255, alpha: 0.5))
                ctx.addPath(CGPath(roundedRect: accentRect, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
                ctx.fillPath()
            }

            // Title
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: tab.isActive ? .medium : .regular),
                .foregroundColor: tab.isActive
                    ? NSColor(red: 228/255, green: 228/255, blue: 232/255, alpha: 1)
                    : NSColor(red: 110/255, green: 110/255, blue: 118/255, alpha: 1)
            ]
            let title = tab.title as NSString
            let titleSize = title.size(withAttributes: attrs)
            let maxTitleW = tabFixedWidth - 34
            title.draw(in: CGRect(
                x: x + 12,
                y: tabRect.midY - titleSize.height / 2,
                width: min(titleSize.width, maxTitleW),
                height: titleSize.height
            ), withAttributes: attrs)

            // Close button
            if tabs.count > 1 {
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor(red: 90/255, green: 90/255, blue: 98/255, alpha: 1)
                ]
                let closeStr = "\u{2715}" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                closeStr.draw(
                    at: NSPoint(x: x + tabFixedWidth - closeSize.width - 12,
                                y: tabRect.midY - closeSize.height / 2),
                    withAttributes: closeAttrs
                )
            }

            x += tabFixedWidth
        }

        // Plus button
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .light),
            .foregroundColor: NSColor(red: 90/255, green: 90/255, blue: 98/255, alpha: 1)
        ]
        let plusSize = ("+" as NSString).size(withAttributes: plusAttrs)
        ("+" as NSString).draw(at: NSPoint(x: x + 6, y: (barHeight - plusSize.height) / 2), withAttributes: plusAttrs)

        ctx.restoreGState()

        // Fade edges if scrollable
        if tabScrollOffset > 0 {
            drawFadeEdge(ctx, at: zoneStart, width: 20, leftToRight: true)
        }
        if tabScrollOffset < maxScrollOffset {
            drawFadeEdge(ctx, at: zoneEnd - 20, width: 20, leftToRight: false)
        }
    }

    private func drawFadeEdge(_ ctx: CGContext, at x: CGFloat, width: CGFloat, leftToRight: Bool) {
        let bgColor = AppSettings.shared.theme.chromeBg.cgColor
        let components = bgColor.components ?? [0, 0, 0, 1]
        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        let colors: [CGFloat] = leftToRight
            ? [r, g, b, 1.0,  r, g, b, 0.0]
            : [r, g, b, 0.0,  r, g, b, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: colors, locations: nil, count: 2) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: 0, width: width, height: barHeight - 1))
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: x, y: 0),
                               end: CGPoint(x: x + width, y: 0),
                               options: [])
        ctx.restoreGState()
    }

    private func drawSidebarButton(_ ctx: CGContext) {
        let btnSize: CGFloat = 26
        let btnX = bounds.width - sidebarButtonWidth + (sidebarButtonWidth - btnSize) / 2 - 2
        let btnY = (barHeight - btnSize) / 2

        let theme = AppSettings.shared.theme
        let color = sidebarVisible
            ? theme.accentColor.withAlphaComponent(0.8).cgColor
            : theme.chromeMuted.cgColor

        let iconX = btnX + 5
        let iconY = btnY + 5
        let iconW: CGFloat = 16
        let iconH: CGFloat = 12

        // Outer rect
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.2)
        let iconRect = CGRect(x: iconX, y: iconY, width: iconW, height: iconH)
        ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.strokePath()

        // Vertical divider line at 2/3
        let divX = iconX + iconW * 0.65
        ctx.move(to: CGPoint(x: divX, y: iconY + 1))
        ctx.addLine(to: CGPoint(x: divX, y: iconY + iconH - 1))
        ctx.strokePath()

        // Fill right portion if sidebar visible
        if sidebarVisible {
            ctx.setFillColor(theme.accentColor.withAlphaComponent(0.2).cgColor)
            ctx.fill(CGRect(x: divX, y: iconY + 1, width: iconX + iconW - divX - 1, height: iconH - 2))
        }
    }

    // MARK: - Hit Testing

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Sidebar button
        if point.x > bounds.width - sidebarButtonWidth - 2 {
            delegate?.toolbarDidToggleSidebar(self)
            return
        }

        // Workspace zone
        if point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap {
            var x = trafficLightWidth - workspaceScrollOffset
            for (i, ws) in workspaces.enumerated() {
                let w = measureWorkspace(ws)
                if point.x >= x && point.x < x + w + 6 {
                    if workspaces.count > 1 && point.x > x + w - 4 {
                        delegate?.toolbar(self, didCloseWorkspaceAt: i)
                    } else {
                        delegate?.toolbar(self, didSelectWorkspaceAt: i)
                    }
                    return
                }
                x += w + 6
            }
            return
        }

        // Tab zone
        guard point.x >= tabZoneStart && point.x <= tabZoneEnd else { return }

        var x = tabZoneStart - tabScrollOffset
        for (i, _) in tabs.enumerated() {
            if point.x >= max(tabZoneStart, x) && point.x < min(tabZoneEnd, x + tabFixedWidth) {
                if tabs.count > 1 && point.x > x + tabFixedWidth - 22 {
                    delegate?.toolbar(self, didCloseTabAt: i)
                } else {
                    delegate?.toolbar(self, didSelectTabAt: i)
                }
                return
            }
            x += tabFixedWidth
        }

        // Plus button
        if point.x >= x && point.x < x + 28 {
            delegate?.toolbarDidRequestNewTab(self)
        }
    }

    // MARK: - Right Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Only show context menu in workspace zone
        guard point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else { return }

        var x = trafficLightWidth - workspaceScrollOffset
        for (i, ws) in workspaces.enumerated() {
            let w = measureWorkspace(ws)
            if point.x >= x && point.x < x + w + 6 {
                showWorkspaceContextMenu(at: i, event: event)
                return
            }
            x += w + 6
        }
    }

    private func showWorkspaceContextMenu(at index: Int, event: NSEvent) {
        let menu = NSMenu()
        let ws = workspaces[index]

        // Rename
        let renameItem = NSMenuItem(title: "Rename...", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.tag = index
        menu.addItem(renameItem)

        menu.addItem(.separator())

        // Pin/Unpin
        let pinTitle = ws.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(contextTogglePin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.tag = index
        menu.addItem(pinItem)

        menu.addItem(.separator())

        // Color submenu
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for color in WorkspaceColor.allCases {
            let item = NSMenuItem(title: color.label, action: #selector(contextSetColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = color
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color...", action: #selector(contextCustomColor(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.tag = index
        colorMenu.addItem(customItem)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())

        // Close
        if !ws.isPinned {
            let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.tag = index
            menu.addItem(closeItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < workspaces.count else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a new name for this workspace."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = workspaces[index].name
        alert.accessoryView = input

        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                let name = input.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    self.delegate?.toolbar(self, renameWorkspaceAt: index, to: name)
                }
            }
        }
    }

    @objc private func contextTogglePin(_ sender: NSMenuItem) {
        delegate?.toolbar(self, togglePinForWorkspaceAt: sender.tag)
    }

    @objc private func contextSetColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? WorkspaceColor else { return }
        // Clear custom color when selecting a preset
        delegate?.toolbar(self, setCustomColorForWorkspaceAt: sender.tag, color: .clear)
        delegate?.toolbar(self, setColorForWorkspaceAt: sender.tag, color: color)
    }

    private var colorPickerIndex: Int = 0

    @objc private func contextCustomColor(_ sender: NSMenuItem) {
        colorPickerIndex = sender.tag
        let picker = NSColorPanel.shared
        picker.setTarget(self)
        picker.setAction(#selector(colorPickerChanged(_:)))
        picker.orderFront(nil)
    }

    @objc private func colorPickerChanged(_ sender: NSColorPanel) {
        delegate?.toolbar(self, setCustomColorForWorkspaceAt: colorPickerIndex, color: sender.color)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        delegate?.toolbar(self, didCloseWorkspaceAt: sender.tag)
    }
}
