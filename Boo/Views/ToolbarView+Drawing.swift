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
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // No background fill: the toolbar island is an outlined frame over the
        // window backdrop. Its border comes from the layer (see IslandMetrics).
        // No bottom separator either — the island gap below does that job now.

        if !hideWorkspaces {
            drawWorkspaces(ctx)
        } else {
            // With the pills moved to a side bar the toolbar is otherwise empty, so
            // the active workspace's name goes in the middle of the header — the one
            // place it stays visible without reintroducing the strip.
            drawCenteredWorkspaceTitle(ctx)
        }
    }

    /// The active workspace's name, centred in the header. Only drawn in the
    /// left/right workspace layouts, where the pill strip has vacated the toolbar.
    /// Test seam: the box `drawCenteredWorkspaceTitle` lays the title out in.
    func centeredWorkspaceTitleRectForTesting() -> CGRect {
        centeredWorkspaceTitleRect(for: "workspace" as NSString, attrs: [:]) ?? .zero
    }

    private func drawCenteredWorkspaceTitle(_ ctx: CGContext) {
        guard let active = workspaces.first(where: { $0.isActive }) else { return }
        let theme = AppSettings.shared.theme

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ToolbarView.Fonts.headerTitle,
            .foregroundColor: active.resolvedColor ?? theme.chromeText,
            .paragraphStyle: para
        ]

        let title = active.name as NSString
        guard let box = centeredWorkspaceTitleRect(for: title, attrs: attrs) else { return }
        title.draw(in: box, withAttributes: attrs)
    }

    /// Box the header title is laid out in, or nil when there is no room for it.
    private func centeredWorkspaceTitleRect(
        for title: NSString, attrs: [NSAttributedString.Key: Any]
    ) -> CGRect? {
        // Centre on the *window*, not on this view: the toolbar island is inset by
        // the side workspace bar, so centring in local bounds would push the title
        // off-centre by half that inset.
        let windowMid: CGFloat
        if let container = superview {
            windowMid = convert(NSPoint(x: container.bounds.midX, y: 0), from: container).x
        } else {
            windowMid = bounds.midX
        }

        // Kept clear of the traffic lights and the sidebar button. Each side is
        // measured independently, then the box is sized by whichever side runs out
        // of room first so the text stays centred on `windowMid`.
        let leftLimit = trafficLightWidth + zoneGap
        let rightLimit = bounds.width - IslandMetrics.contentInset - zoneGap
        let halfW = min(windowMid - leftLimit, rightLimit - windowMid)
        guard halfW > 0 else { return nil }

        // Centre on the glyphs, not on the line box: the shared cap-band correction
        // puts the capitals on the bar's midline, level with the traffic lights.
        let font = (attrs[.font] as? NSFont) ?? ToolbarView.Fonts.headerTitle
        let h = title.size(withAttributes: attrs).height
        let y = IslandMetrics.capCenteredTitleY(font: font, barHeight: barHeight)
        return CGRect(x: windowMid - halfW, y: y, width: halfW * 2, height: h)
    }

    // Cached pin icon — allocated once, shared across all draw calls.
    private static let pinIcon: NSImage? = {
        guard let img = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        let sized = img.withSymbolConfiguration(cfg) ?? img
        sized.isTemplate = true
        return sized
    }()

    internal func drawWorkspaces(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme
        let zoneStart = trafficLightWidth
        let zoneEnd = workspaceZoneEnd
        let totalW = totalWorkspaceContentWidth  // hits cache
        let isScrollable = totalW > workspaceZoneWidth

        if isScrollable {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: zoneStart, y: 0, width: zoneEnd - zoneStart, height: barHeight))
        }

        var x = zoneStart - workspaceScrollOffset

        for (wsIndex, ws) in workspaces.enumerated() {
            let w = measureWorkspace(at: wsIndex)  // cached
            let pillH = Self.workspacePillHeight
            let pillY = (barHeight - pillH) / 2
            let isWSHovered = hoveredWorkspaceIndex == wsIndex

            let wsColor = ws.resolvedColor

            let rect = CGRect(x: x, y: pillY, width: w, height: pillH)
            WorkspacePillStyle.fill(
                ctx, rect: rect, active: ws.isActive, hovered: isWSHovered,
                wsColor: wsColor, neutral: theme.chromeMuted)

            // Accent-color border on the active workspace pill
            if ws.isActive {
                WorkspacePillStyle.strokeBorder(ctx, rect: rect, accent: theme.accentColor)
            }

            var contentX = x + 10

            if ws.isPinned, let pinImg = Self.pinIcon {
                let pinColor =
                    ws.isActive ? theme.chromeText.withAlphaComponent(0.5) : theme.chromeMuted.withAlphaComponent(0.5)
                let iconSize: CGFloat = 8
                let iconY = (barHeight - iconSize) / 2
                let iconRect = NSRect(x: contentX, y: iconY, width: iconSize, height: iconSize)
                let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
                    pinColor.set()
                    pinImg.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                    NSRect(origin: .zero, size: drawRect.size).fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: iconRect)
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

            // Keep the name fully readable on hover — the close button draws its
            // own opaque circle over the right edge, so no global text fade is needed.
            let nameFont = ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: textColor]
            let nameSize = (ws.name as NSString).size(withAttributes: nameAttrs)
            (ws.name as NSString).draw(
                at: NSPoint(x: contentX, y: (barHeight - nameSize.height) / 2),
                withAttributes: nameAttrs
            )

            // Close button — overlays text on hover, no extra pill space reserved
            if !ws.isPinned && isWSHovered {
                WorkspacePillStyle.drawCloseButton(
                    ctx, in: workspaceCloseButtonRect(in: rect),
                    tint: wsColor ?? theme.chromeMuted, bg: theme.chromeBg)
            }

            // Activity dot — top-right corner inside the pill
            if ws.hasActivity {
                let dotSize: CGFloat = 5
                ctx.setFillColor(theme.accentColor.cgColor)
                ctx.fillEllipse(
                    in: CGRect(
                        x: rect.maxX - dotSize - 3,
                        y: rect.minY + 3,
                        width: dotSize, height: dotSize))
            }

            x += w + Self.workspaceGap
        }

        // Draw drop insertion indicator (vertical line between workspace pills)
        if let dropIdx = dropTargetIndex {
            var indicatorX = zoneStart - workspaceScrollOffset
            for i in 0..<min(dropIdx, workspaces.count) {
                indicatorX += measureWorkspace(at: i) + Self.workspaceGap
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
                // Wide enough that the clipped pill has fully dissolved into the
                // backdrop by the time it reaches the pinned `+`, rather than a
                // half-faded label butting up against the button.
                let fadeW: CGFloat = 32
                drawFadeEdge(ctx, at: zoneEnd - fadeW, width: fadeW, leftToRight: false)
            }
        }

        // Workspace plus button (drawn outside scroll clip)
        let plusRect = workspacePlusButtonRect
        let plusBgAlpha: CGFloat = isWorkspacePlusButtonHovered ? 0.12 : 0.06
        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(plusBgAlpha).cgColor)
        WorkspacePillStyle.fillRoundedRect(ctx, rect: plusRect)
        let wsPlusAlpha: CGFloat = isWorkspacePlusButtonHovered ? 0.9 : 0.45
        let wsPlusAttrs: [NSAttributedString.Key: Any] = [
            .font: Fonts.plus15Light,
            .foregroundColor: theme.chromeMuted.withAlphaComponent(wsPlusAlpha)
        ]
        let wsPlusStr = "+" as NSString
        let wsPlusSize = wsPlusStr.size(withAttributes: wsPlusAttrs)
        wsPlusStr.draw(
            at: NSPoint(x: plusRect.midX - wsPlusSize.width / 2, y: plusRect.midY - 1 - wsPlusSize.height / 2),
            withAttributes: wsPlusAttrs)
    }

    internal func drawFadeEdge(_ ctx: CGContext, at x: CGFloat, width: CGFloat, leftToRight: Bool) {
        // The toolbar paints no fill of its own in the island style — it is a
        // transparent strip over the window backdrop, so the scroll fade must
        // dissolve into the backdrop, not into the (now unused) chrome fill.
        // Full height: the -1 inset used to spare the old bottom separator, which
        // the island gap replaced.
        WorkspacePillStyle.drawBackdropFade(
            ctx, in: CGRect(x: x, y: 0, width: width, height: barHeight),
            from: CGPoint(x: leftToRight ? x : x + width, y: 0),
            to: CGPoint(x: leftToRight ? x + width : x, y: 0))
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

        window?.performDrag(with: event)
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
                    let w = measureWorkspace(at: idx)
                    var pillX = trafficLightWidth - workspaceScrollOffset
                    for i in 0..<idx { pillX += measureWorkspace(at: i) + Self.workspaceGap }
                    let pillH = Self.workspacePillHeight
                    let pillY = (barHeight - pillH) / 2
                    let pillRect = CGRect(x: pillX, y: pillY, width: w, height: pillH)
                    let closeRect = workspaceCloseButtonRect(in: pillRect)
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
        let ghostWidth = min(measureWorkspace(at: index) + 8, 140)
        let ghostHeight = Self.workspacePillHeight

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
        for i in workspaces.indices {
            let w = measureWorkspace(at: i)
            if point.x < x + (w + Self.workspaceGap) / 2 {
                rawIdx = i
                break
            }
            x += w + Self.workspaceGap
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
        // Only the pill band itself is clickable — the strips above and below
        // stay free so the window can be dragged from there.
        let pillY = (barHeight - Self.workspacePillHeight) / 2
        guard point.y >= pillY && point.y < pillY + Self.workspacePillHeight else { return nil }
        var x = trafficLightWidth - workspaceScrollOffset
        for i in workspaces.indices {
            let w = measureWorkspace(at: i)
            if point.x >= x && point.x < x + w + Self.workspaceGap { return i }
            x += w + Self.workspaceGap
        }
        return nil
    }

    // MARK: - Right Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Only show context menu in workspace zone
        guard !hideWorkspaces, point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else { return }

        var x = trafficLightWidth - workspaceScrollOffset
        for i in workspaces.indices {
            let w = measureWorkspace(at: i)
            if point.x >= x && point.x < x + w + Self.workspaceGap {
                showWorkspaceContextMenu(at: i, event: event)
                return
            }
            x += w + Self.workspaceGap
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
            guard let self else { return }
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
