import Cocoa

// MARK: - Drawing & Mouse Events

extension ToolbarView {
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

        if !hideWorkspaces {
            drawWorkspaces(ctx)
        }
    }

    internal func drawWorkspaces(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme
        let zoneStart = trafficLightWidth
        let zoneEnd = workspaceZoneEnd
        let isScrollable = totalWorkspaceContentWidth > workspaceZoneWidth

        if isScrollable {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: zoneStart, y: 0, width: zoneEnd - zoneStart, height: barHeight))
        }

        var x = zoneStart - workspaceScrollOffset

        for (wsIndex, ws) in workspaces.enumerated() {
            let w = measureWorkspace(ws)
            let pillH: CGFloat = 24
            let pillY = (barHeight - pillH) / 2
            let isWSHovered = hoveredWorkspaceIndex == wsIndex

            let wsColor = ws.resolvedColor

            let rect = CGRect(x: x, y: pillY, width: w, height: pillH)
            if let c = wsColor {
                let alpha: CGFloat = ws.isActive ? 0.25 : (isWSHovered ? 0.18 : 0.12)
                ctx.setFillColor(c.withAlphaComponent(alpha).cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if ws.isActive {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if isWSHovered {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.12).cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }

            var contentX = x + 10

            if ws.isPinned {
                let pinColor =
                    ws.isActive ? theme.chromeText.withAlphaComponent(0.5) : theme.chromeMuted.withAlphaComponent(0.5)
                let iconSize: CGFloat = 8
                let iconY = (barHeight - iconSize) / 2
                if let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
                    let sized =
                        pinImage.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) ?? pinImage
                    sized.isTemplate = true
                    let iconRect = NSRect(x: contentX, y: iconY, width: iconSize, height: iconSize)
                    let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
                        pinColor.set()
                        sized.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                        NSRect(origin: .zero, size: drawRect.size).fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: iconRect)
                }
                contentX += 12
            }

            let textColor: NSColor
            if let c = wsColor, ws.isActive {
                textColor = NSColor(
                    red: c.redComponent * 0.6 + 0.4, green: c.greenComponent * 0.6 + 0.4,
                    blue: c.blueComponent * 0.6 + 0.4, alpha: 1)
            } else if ws.isActive {
                textColor = theme.chromeText
            } else if let c = wsColor {
                textColor = NSColor(
                    red: c.redComponent * 0.5 + 0.2, green: c.greenComponent * 0.5 + 0.2,
                    blue: c.blueComponent * 0.5 + 0.2, alpha: 1)
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

            // Close button — on hover, not pinned
            if !ws.isPinned && isWSHovered {
                let closeColor: NSColor = wsColor?.withAlphaComponent(0.8) ?? theme.chromeMuted.withAlphaComponent(0.8)
                let closeBgColor: NSColor =
                    wsColor?.withAlphaComponent(0.15) ?? theme.chromeMuted.withAlphaComponent(0.15)
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: closeColor
                ]
                let closeStr = "\u{2715}" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                let circleSize: CGFloat = 16
                let circleX = rect.maxX - circleSize - 2
                let circleY = rect.midY - circleSize / 2
                ctx.setFillColor(closeBgColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
                closeStr.draw(
                    at: NSPoint(x: circleX + (circleSize - closeSize.width) / 2, y: rect.midY - closeSize.height / 2),
                    withAttributes: closeAttrs
                )
            }

            x += w + 6
        }

        // Draw drop insertion indicator (vertical line between workspace pills)
        if let dropIdx = dropTargetIndex {
            var indicatorX = zoneStart - workspaceScrollOffset
            for i in 0..<min(dropIdx, workspaces.count) {
                indicatorX += measureWorkspace(workspaces[i]) + 6
            }
            indicatorX -= 3
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: indicatorX, y: 6, width: 2, height: barHeight - 12))
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

        // Workspace plus button (drawn outside scroll clip)
        let plusRect = workspacePlusButtonRect
        if isWorkspacePlusButtonHovered {
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.12).cgColor)
            ctx.addPath(CGPath(roundedRect: plusRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        let wsPlusAlpha: CGFloat = isWorkspacePlusButtonHovered ? 0.9 : 0.45
        let wsPlusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .light),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(wsPlusAlpha)
        ]
        let wsPlusStr = "+" as NSString
        let wsPlusSize = wsPlusStr.size(withAttributes: wsPlusAttrs)
        wsPlusStr.draw(
            at: NSPoint(x: plusRect.midX - wsPlusSize.width / 2, y: plusRect.midY - wsPlusSize.height / 2),
            withAttributes: wsPlusAttrs)
    }

    internal func drawDivider(_ ctx: CGContext) {
        let divX = workspaceZoneEnd + zoneGap
        ctx.setFillColor(CGColor(red: 45 / 255, green: 45 / 255, blue: 50 / 255, alpha: 0.6))
        ctx.fill(CGRect(x: divX, y: 10, width: dividerWidth, height: barHeight - 20))
    }

    internal func drawTabs(_ ctx: CGContext) {
        guard !tabs.isEmpty else { return }

        let zoneStart = tabZoneStart
        let zoneEnd = tabZoneEnd

        // Clip to tab zone
        ctx.saveGState()
        ctx.clip(to: CGRect(x: zoneStart, y: 0, width: zoneEnd - zoneStart, height: barHeight))

        var x = zoneStart - tabScrollOffset

        for (tabIndex, tab) in tabs.enumerated() {
            let tabRect = CGRect(x: x + 2, y: 7, width: tabFixedWidth - 4, height: barHeight - 13)
            let isTabHovered = hoveredTabIndex == tabIndex

            if tab.isActive {
                ctx.setFillColor(CGColor(red: 28 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: tabRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
                ctx.fillPath()

                // Subtle bottom accent
                let accentRect = CGRect(
                    x: tabRect.minX + 12, y: tabRect.maxY - 2, width: tabRect.width - 24, height: 1.5)
                ctx.setFillColor(CGColor(red: 77 / 255, green: 143 / 255, blue: 232 / 255, alpha: 0.5))
                ctx.addPath(CGPath(roundedRect: accentRect, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
                ctx.fillPath()
            } else if isTabHovered {
                ctx.setFillColor(CGColor(red: 35 / 255, green: 35 / 255, blue: 40 / 255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: tabRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
                ctx.fillPath()
            }

            // Title
            let textColor: NSColor
            if tab.isActive {
                textColor = NSColor(red: 228 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
            } else if isTabHovered {
                textColor = NSColor(red: 170 / 255, green: 170 / 255, blue: 178 / 255, alpha: 1)
            } else {
                textColor = NSColor(red: 110 / 255, green: 110 / 255, blue: 118 / 255, alpha: 1)
            }
            let showClose = tabs.count > 1 && (tab.isActive || isTabHovered)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: tab.isActive ? .medium : .regular),
                .foregroundColor: textColor
            ]
            let title = tab.title as NSString
            let titleSize = title.size(withAttributes: attrs)
            let maxTitleW = tabFixedWidth - (showClose ? 34 : 20)
            title.draw(
                in: CGRect(
                    x: x + 12,
                    y: tabRect.midY - titleSize.height / 2,
                    width: min(titleSize.width, maxTitleW),
                    height: titleSize.height
                ), withAttributes: attrs)

            // Close button — only on active or hovered tab
            if showClose {
                let closeAlpha: CGFloat = isTabHovered ? 0.8 : 0.6
                // Hover circle background
                if isTabHovered {
                    let circleSize: CGFloat = 18
                    let circleX = x + tabFixedWidth - circleSize - 6
                    let circleY = tabRect.midY - circleSize / 2
                    ctx.setFillColor(CGColor(red: 60 / 255, green: 60 / 255, blue: 68 / 255, alpha: 0.5))
                    ctx.fillEllipse(in: CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
                }
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor(red: 90 / 255, green: 90 / 255, blue: 98 / 255, alpha: closeAlpha)
                ]
                let closeStr = "\u{2715}" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                closeStr.draw(
                    at: NSPoint(
                        x: x + tabFixedWidth - closeSize.width - 12,
                        y: tabRect.midY - closeSize.height / 2),
                    withAttributes: closeAttrs
                )
            }

            x += tabFixedWidth
        }

        // Plus button
        let plusAlpha: CGFloat = isPlusButtonHovered ? 1.0 : 0.6
        if isPlusButtonHovered {
            let hoverRect = CGRect(x: x + 2, y: 10, width: 24, height: barHeight - 20)
            ctx.setFillColor(CGColor(red: 35 / 255, green: 35 / 255, blue: 40 / 255, alpha: 1))
            ctx.addPath(CGPath(roundedRect: hoverRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .light),
            .foregroundColor: NSColor(red: 90 / 255, green: 90 / 255, blue: 98 / 255, alpha: plusAlpha)
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

    internal func drawFadeEdge(_ ctx: CGContext, at x: CGFloat, width: CGFloat, leftToRight: Bool) {
        let bgColor = AppSettings.shared.theme.chromeBg.cgColor
        let components = bgColor.components ?? [0, 0, 0, 1]
        let r = !components.isEmpty ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        let colors: [CGFloat] =
            leftToRight
            ? [r, g, b, 1.0, r, g, b, 0.0]
            : [r, g, b, 0.0, r, g, b, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: colors, locations: nil, count: 2)
        else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: 0, width: width, height: barHeight - 1))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: x, y: 0),
            end: CGPoint(x: x + width, y: 0),
            options: [])
        ctx.restoreGState()
    }

    internal func drawSidebarButton(_ ctx: CGContext) {
        if sidebarButtonHidden { return }
        let btnSize: CGFloat = 26
        let btnX = bounds.width - sidebarButtonWidth + (sidebarButtonWidth - btnSize) / 2 - 2
        let btnY = (barHeight - btnSize) / 2

        let theme = AppSettings.shared.theme

        // Hover background
        if isSidebarButtonHovered {
            let hoverRect = CGRect(x: btnX, y: btnY, width: btnSize, height: btnSize)
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.15).cgColor)
            ctx.addPath(CGPath(roundedRect: hoverRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }

        let color =
            sidebarVisible
            ? theme.accentColor.withAlphaComponent(isSidebarButtonHovered ? 1.0 : 0.8).cgColor
            : (isSidebarButtonHovered ? theme.chromeMuted.withAlphaComponent(0.8).cgColor : theme.chromeMuted.cgColor)

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
        let startPoint = convert(event.locationInWindow, from: nil)
        mouseDownLocation = startPoint

        // Workspace zone — use tracking loop for drag reordering
        if !hideWorkspaces, let hitIdx = hitTestWorkspaceIndex(at: startPoint) {
            if event.clickCount == 2 {
                showRenameAlert(at: hitIdx)
                return
            }
            handleWorkspaceMouseDown(event, startPoint: startPoint, hitIndex: hitIdx)
            return
        }

        // Workspace plus button
        if !hideWorkspaces && workspacePlusButtonRect.contains(startPoint) {
            delegate?.toolbarDidRequestNewWorkspace(self)
            return
        }

        // Empty space in workspace zone
        if !hideWorkspaces && startPoint.x >= trafficLightWidth && startPoint.x < workspaceZoneEnd + zoneGap {
            window?.performDrag(with: event)
            return
        }

        // Tab zone
        guard startPoint.x >= tabZoneStart && startPoint.x <= tabZoneEnd else {
            window?.performDrag(with: event)
            return
        }

        var x = tabZoneStart - tabScrollOffset
        for (i, _) in tabs.enumerated() {
            if startPoint.x >= max(tabZoneStart, x) && startPoint.x < min(tabZoneEnd, x + tabFixedWidth) {
                if tabs.count > 1 && startPoint.x > x + tabFixedWidth - 22 {
                    delegate?.toolbar(self, didCloseTabAt: i)
                } else {
                    delegate?.toolbar(self, didSelectTabAt: i)
                }
                return
            }
            x += tabFixedWidth
        }

        // Plus button
        if startPoint.x >= x && startPoint.x < x + 28 {
            delegate?.toolbarDidRequestNewTab(self)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// Tracking loop for workspace pill click/drag — mirrors WorkspaceBarView approach.
    private func handleWorkspaceMouseDown(_ event: NSEvent, startPoint: NSPoint, hitIndex idx: Int) {
        var didStartDrag = false

        guard let eventWindow = window else { return }
        while true {
            guard let nextEvent = eventWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }

            if nextEvent.type == .leftMouseUp {
                if !didStartDrag {
                    // Plain click — close or select
                    let ws = workspaces[idx]
                    let w = measureWorkspace(ws)
                    var pillX = trafficLightWidth - workspaceScrollOffset
                    for i in 0..<idx { pillX += measureWorkspace(workspaces[i]) + 6 }
                    let pillH: CGFloat = 24
                    let circleSize: CGFloat = 16
                    let pillY = (barHeight - pillH) / 2
                    let circleY = pillY + (pillH - circleSize) / 2
                    let closeRect = CGRect(
                        x: pillX + w - circleSize - 2, y: circleY, width: circleSize, height: circleSize)
                    if !ws.isPinned && hoveredWorkspaceIndex == idx && closeRect.contains(startPoint) {
                        delegate?.toolbar(self, didCloseWorkspaceAt: idx)
                    } else {
                        delegate?.toolbar(self, didSelectWorkspaceAt: idx)
                    }
                } else {
                    executeWorkspaceDrop()
                }
                break
            }

            // leftMouseDragged
            if !didStartDrag {
                let dragPoint = convert(nextEvent.locationInWindow, from: nil)
                let distance = hypot(dragPoint.x - startPoint.x, dragPoint.y - startPoint.y)
                guard distance > 3 else { continue }
                guard !workspaces[idx].isPinned else { break }
                guard workspaces.filter({ !$0.isPinned }).count > 1 else { break }

                dragSourceIndex = idx
                isDragging = true
                didStartDrag = true
                createWorkspaceGhostWindow(for: idx, event: nextEvent)
            }

            handleWorkspaceDragMove(nextEvent)
        }

        if didStartDrag {
            cleanupWorkspaceDrag()
        }
        mouseDownLocation = nil
    }

    private func createWorkspaceGhostWindow(for index: Int, event: NSEvent) {
        let ws = workspaces[index]
        let ghostWidth = min(measureWorkspace(ws) + 8, 140)
        let ghostHeight: CGFloat = 24

        let ghostView = NSView(frame: NSRect(x: 0, y: 0, width: ghostWidth, height: ghostHeight))
        ghostView.wantsLayer = true
        ghostView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        ghostView.layer?.cornerRadius = 6
        ghostView.layer?.borderColor = NSColor.separatorColor.cgColor
        ghostView.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: ws.name)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 6, y: 2, width: ghostWidth - 12, height: ghostHeight - 4)
        ghostView.addSubview(label)

        let screenPoint: NSPoint
        if let w = event.window {
            screenPoint = w.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }

        let win = NSWindow(
            contentRect: NSRect(
                x: screenPoint.x - ghostWidth / 2,
                y: screenPoint.y - ghostHeight / 2,
                width: ghostWidth, height: ghostHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.contentView = ghostView
        win.alphaValue = 0.85
        win.orderFront(nil)

        ghostWindow = win
    }

    private func handleWorkspaceDragMove(_ event: NSEvent) {
        // Move ghost window
        if let win = ghostWindow {
            let screenPoint: NSPoint
            if let eventWindow = event.window {
                screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
            } else {
                screenPoint = NSEvent.mouseLocation
            }
            let frame = win.frame
            win.setFrameOrigin(
                NSPoint(
                    x: screenPoint.x - frame.width / 2,
                    y: screenPoint.y - frame.height / 2))
        }

        // Update drop target
        let point = convert(event.locationInWindow, from: nil)
        var x = trafficLightWidth - workspaceScrollOffset
        var rawIdx = workspaces.count
        for (i, ws) in workspaces.enumerated() {
            let w = measureWorkspace(ws)
            if point.x < x + (w + 6) / 2 {
                rawIdx = i
                break
            }
            x += w + 6
        }

        let validIdx = validWorkspaceDropIndex(raw: rawIdx)
        if validIdx != dropTargetIndex {
            dropTargetIndex = validIdx
            needsDisplay = true
        }
    }

    private func validWorkspaceDropIndex(raw: Int) -> Int? {
        guard let src = dragSourceIndex else { return nil }
        if raw == src || raw == src + 1 { return nil }
        let lo = min(src, raw)
        let hi = max(src, raw)
        for i in lo..<hi where i != src {
            if workspaces[i].isPinned { return nil }
        }
        return raw
    }

    private func executeWorkspaceDrop() {
        guard let dropIdx = dropTargetIndex, let sourceIdx = dragSourceIndex else { return }
        delegate?.toolbar(self, moveWorkspaceFrom: sourceIdx, to: dropIdx)
    }

    private func cleanupWorkspaceDrag() {
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
        isDragging = false
        dragSourceIndex = nil
        dropTargetIndex = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
    }

    /// Hit-test which workspace pill contains the given point.
    internal func hitTestWorkspaceIndex(at point: NSPoint) -> Int? {
        guard point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else { return nil }
        var x = trafficLightWidth - workspaceScrollOffset
        for (i, ws) in workspaces.enumerated() {
            let w = measureWorkspace(ws)
            if point.x >= x && point.x < x + w + 6 { return i }
            x += w + 6
        }
        return nil
    }

    // MARK: - Right Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Only show context menu in workspace zone
        guard !hideWorkspaces, point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else { return }

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

    internal func showWorkspaceContextMenu(at index: Int, event: NSEvent) {
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
            if !ws.hasCustomColor && color == ws.color {
                item.state = .on
            }
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let customItem = NSMenuItem(
            title: "Custom Color...", action: #selector(contextCustomColor(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.tag = index
        if ws.hasCustomColor {
            customItem.state = .on
        }
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

    @objc internal func contextRename(_ sender: NSMenuItem) {
        showRenameAlert(at: sender.tag)
    }

    internal func showRenameAlert(at index: Int) {
        guard index >= 0, index < workspaces.count else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a new name for this workspace."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = workspaces[index].name
        alert.accessoryView = input

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if response == .alertFirstButtonReturn {
                let name = input.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    self.delegate?.toolbar(self, renameWorkspaceAt: index, to: name)
                }
            }
        }
        alert.window.makeFirstResponder(input)
    }

    @objc internal func contextTogglePin(_ sender: NSMenuItem) {
        delegate?.toolbar(self, togglePinForWorkspaceAt: sender.tag)
    }

    @objc internal func contextSetColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? WorkspaceColor else { return }
        // Clear custom color when selecting a preset
        delegate?.toolbar(self, setCustomColorForWorkspaceAt: sender.tag, color: .clear)
        delegate?.toolbar(self, setColorForWorkspaceAt: sender.tag, color: color)
    }

    @objc internal func contextCustomColor(_ sender: NSMenuItem) {
        colorPickerIndex = sender.tag
        colorPickerActive = true
        let picker = NSColorPanel.shared
        picker.setTarget(self)
        picker.setAction(#selector(colorPickerChanged(_:)))
        picker.orderFront(nil)
    }

    @objc internal func colorPickerChanged(_ sender: NSColorPanel) {
        delegate?.toolbar(self, setCustomColorForWorkspaceAt: colorPickerIndex, color: sender.color)
    }

    @objc internal func contextClose(_ sender: NSMenuItem) {
        delegate?.toolbar(self, didCloseWorkspaceAt: sender.tag)
    }

    // MARK: - Testing Hooks

    /// Directly invoke the double-click rename path. For tests only.
    func triggerDoubleClickForTesting(at index: Int) {
        showRenameAlert(at: index)
    }
}
