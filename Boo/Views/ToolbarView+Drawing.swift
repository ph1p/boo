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

        drawWorkspaceGroups(ctx, theme: theme)

        for (wsIndex, ws) in workspaces.enumerated() {
            // Hidden members of a collapsed group have no pill.
            guard let rect = workspacePillRect(at: wsIndex) else { continue }
            let x = rect.minX
            let isWSHovered = hoveredWorkspaceIndex == wsIndex

            let wsColor = ws.resolvedColor

            // The dragged pill stays as a faint placeholder; the ghost carries it.
            let isLifted =
                isDragging && (dragSourceIndex == wsIndex || (ws.groupID != nil && ws.groupID == draggedGroupID))
            if isLifted {
                ctx.saveGState()
                ctx.setAlpha(0.3)
            }
            defer { if isLifted { ctx.restoreGState() } }
            // Inside a group the tray is the surface: members take the group's
            // colour unless they carry their own, and only fill when active or hovered,
            // so member tints never stack on top of the tray tint.
            let groupColor = ws.groupID != nil ? ws.groupColor : nil
            let labelTint = wsColor ?? groupColor
            if ws.groupID == nil {
                WorkspacePillStyle.fill(
                    ctx, rect: rect, active: ws.isActive, hovered: isWSHovered,
                    wsColor: wsColor, neutral: theme.chromeMuted)
            } else if ws.isActive || isWSHovered {
                WorkspacePillStyle.fill(
                    ctx, rect: rect, active: ws.isActive, hovered: true,
                    wsColor: labelTint, neutral: theme.chromeMuted)
            }

            // Accent-color border on the active workspace pill
            if ws.isActive {
                WorkspacePillStyle.strokeBorder(ctx, rect: rect, theme: theme, color: labelTint)
            }

            // Centre the content: short names in a min-width pill otherwise leave
            // a ragged hole on the right that reads as uneven spacing.
            let pinWidth: CGFloat = ws.isPinned && Self.pinIcon != nil ? 13 : 0
            let measuredName = (ws.name as NSString).size(withAttributes: [
                .font: ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular
            ]).width
            let contentWidth = pinWidth + ceil(measuredName)
            let closeRect = workspaceCloseButtonRect(in: rect)
            // Active unpinned pill: label leads, ✕ trails right after it. Otherwise
            // centre the label across the same total padding (pill width stays put).
            let contentStart = x + Self.workspaceLeadIn
            let contentEnd = rect.maxX - (ws.isPinned ? Self.workspaceLeadIn : Self.workspaceCloseSlot)
            var contentX: CGFloat
            if !ws.isPinned && ws.isActive {
                contentX = contentStart
            } else {
                contentX = max(contentStart, (rect.midX - contentWidth / 2).rounded())
            }

            if ws.isPinned, let pinImg = Self.pinIcon {
                let pinColor =
                    ws.isActive ? theme.chromeText.withAlphaComponent(0.5) : theme.chromeMuted.withAlphaComponent(0.5)
                let iconSize: CGFloat = 9
                let iconY = (barHeight - iconSize) / 2
                let iconRect = NSRect(x: contentX, y: iconY, width: iconSize, height: iconSize)
                pinImg.tinted(with: pinColor, size: iconRect.size).draw(in: iconRect)
                contentX += 13
            }

            let textColor = WorkspacePillStyle.labelColor(
                wsColor: labelTint, active: ws.isActive, text: theme.chromeText, muted: theme.chromeMuted)

            let showClose = !ws.isPinned && ws.isActive
            // Inactive labels are centred, so they may use the slot's spare width.
            let textEnd = showClose ? contentEnd : rect.maxX - Self.workspaceLeadIn
            let nameFont = ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: nameFont, .foregroundColor: textColor, .paragraphStyle: para
            ]
            let nameHeight = (ws.name as NSString).size(withAttributes: nameAttrs).height
            (ws.name as NSString).draw(
                in: CGRect(
                    x: contentX, y: IslandMetrics.capCenteredTitleY(font: nameFont, barHeight: barHeight),
                    width: max(0, textEnd - contentX), height: nameHeight),
                withAttributes: nameAttrs)

            if showClose {
                WorkspacePillStyle.drawCloseButton(
                    ctx, in: closeRect, tint: labelTint ?? theme.chromeMuted,
                    hovered: isWorkspaceCloseHovered && isMouseInside(closeRect))
            }

            // Furthest-along OSC 9;4 progress of the workspace's tabs, and the activity dot.
            // Activity dot sits in the corner (centred labels leave no clean slot);
            // the active pill shows its ✕ instead.
            WorkspacePillStyle.drawStatus(
                ctx, rect: rect, hasActivity: ws.hasActivity && !showClose, progress: ws.progress,
                theme: theme)
        }

        drawStackHighlight(ctx, theme: theme)

        // Draw drop insertion indicator (vertical line between workspace pills)
        if let dropIdx = dropTargetIndex {
            let indicatorX = insertionIndicatorX(for: dropIdx) - 1
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
        // Transparent at rest; the pill only appears under the pointer.
        if isWorkspacePlusButtonHovered {
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.12).cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: plusRect)
        }
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

        // Group header chip — click folds/unfolds, drag moves the whole group
        if !hideWorkspaces, let chip = hitTestGroupChip(at: startPoint) {
            handleGroupChipMouseDown(startPoint: startPoint, group: chip)
            return
        }

        // Workspace zone — use tracking loop for drag reordering
        if !hideWorkspaces, let hitIdx = hitTestWorkspaceIndex(at: startPoint) {
            if event.clickCount == 2 {
                editWorkspace(at: hitIdx)
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
                    let closeRect = workspacePillRect(at: idx).map(workspaceCloseButtonRect(in:))
                    if !ws.isPinned && ws.isActive && closeRect?.contains(startPoint) == true {
                        delegate?.toolbar(self, didCloseWorkspaceAt: idx)
                    } else {
                        delegate?.toolbar(self, didSelectWorkspaceAt: idx)
                    }
                } else if let point = WorkspaceBarView.screenPointOutsideWindow(nextEvent),
                    let src = dragSourceIndex
                {
                    delegate?.toolbar(self, dropWorkspaceAt: src, atScreenPoint: point)
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
                // A lone workspace still drags: it can move into another window.
                guard !workspaces[idx].isPinned else { break }

                dragSourceIndex = idx
                isDragging = true
                didStartDrag = true
                createWorkspaceGhostWindow(for: idx, event: nextEvent)
            }

            handleWorkspaceDragMove(nextEvent)
            delegate?.toolbar(self, workspaceDragMovedOutsideTo: WorkspaceBarView.screenPointOutsideWindow(nextEvent))
        }

        if didStartDrag {
            delegate?.toolbar(self, workspaceDragMovedOutsideTo: nil)
            cleanupWorkspaceDrag()
        }
        mouseDownLocation = nil
    }

    private func createWorkspaceGhostWindow(for index: Int, event: NSEvent) {
        guard let rect = workspacePillRect(at: index), let window else { return }
        let ws = workspaces[index]
        let ghost = WorkspaceDragGhostView(
            size: rect.size, label: ws.name, font: ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular,
            centered: false, wsColor: ws.resolvedColor, active: ws.isActive)
        ghostWindow = DragGhostWindow(
            content: ghost, sourceFrame: window.convertToScreen(convert(rect, to: nil)),
            cursor: DragGhostWindow.screenPoint(of: event), alpha: 0.95)
        // No close button or hover fill on the faded placeholder.
        hoveredWorkspaceIndex = -1
        needsDisplay = true
    }

    private func handleWorkspaceDragMove(_ event: NSEvent) {
        // Move ghost window
        ghostWindow?.move(toCenter: DragGhostWindow.screenPoint(of: event))

        // Update drop target (none while outside the window: that drop moves windows)
        if WorkspaceBarView.screenPointOutsideWindow(event) != nil {
            if dropTargetIndex != nil || dropStackIndex != nil || dropGroupID != nil {
                dropTargetIndex = nil
                dropStackIndex = nil
                dropGroupID = nil
                needsDisplay = true
            }
            return
        }
        updateWorkspaceDropTarget(at: convert(event.locationInWindow, from: nil))
    }

    private func executeWorkspaceDrop() {
        guard let sourceIdx = dragSourceIndex else { return }
        if let gid = dropGroupID {
            delegate?.toolbar(self, moveWorkspaceAt: sourceIdx, intoGroup: gid)
        } else if let target = dropStackIndex {
            delegate?.toolbar(self, stackWorkspaceAt: sourceIdx, onto: target)
        } else if let dropIdx = dropTargetIndex {
            delegate?.toolbar(self, moveWorkspaceFrom: sourceIdx, to: dropIdx)
        }
    }

    func cleanupWorkspaceDrag() {
        ghostWindow?.fadeOut()
        ghostWindow = nil
        isDragging = false
        dragSourceIndex = nil
        dropTargetIndex = nil
        dropStackIndex = nil
        dropGroupID = nil
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
        return workspaceIndex(atX: point.x)
    }

    // MARK: - Right Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Only show context menu in workspace zone
        guard !hideWorkspaces, point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else { return }

        if let chip = hitTestGroupChip(at: point) {
            let items = delegate?.toolbar(self, menuItemsForGroup: chip.id) ?? []
            guard !items.isEmpty else { return }
            let menu = NSMenu()
            items.forEach(menu.addItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }

        if let i = workspaceIndex(atX: point.x) { showWorkspaceContextMenu(at: i, event: event) }
    }

    internal func showWorkspaceContextMenu(at index: Int, event: NSEvent) {
        let ws = workspaces[index]
        let menu = WorkspaceContextMenu.make(
            index: index, isPinned: ws.isPinned, canMoveToNewWindow: workspaces.count > 1,
            extraItems: delegate?.toolbar(self, contextMenuItemsForWorkspaceAt: index) ?? [],
            target: self,
            actions: .init(
                edit: #selector(contextEditWorkspace(_:)), togglePin: #selector(contextTogglePin(_:)),
                moveToNewWindow: #selector(contextMoveToNewWindow(_:)), close: #selector(contextClose(_:))))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc internal func contextEditWorkspace(_ sender: NSMenuItem) {
        editWorkspace(at: sender.tag)
    }

    /// Ask the delegate to show the inline editor for the pill at `index`.
    func editWorkspace(at index: Int) {
        guard let rect = workspacePillRect(at: index) else { return }
        delegate?.toolbar(self, editWorkspaceAt: index, anchor: rect)
    }

    @objc internal func contextTogglePin(_ sender: NSMenuItem) {
        delegate?.toolbar(self, togglePinForWorkspaceAt: sender.tag)
    }

    @objc internal func contextMoveToNewWindow(_ sender: NSMenuItem) {
        delegate?.toolbar(self, moveWorkspaceToNewWindowAt: sender.tag)
    }

    @objc internal func contextClose(_ sender: NSMenuItem) {
        delegate?.toolbar(self, didCloseWorkspaceAt: sender.tag)
    }

    // MARK: - Testing Hooks

    /// Directly invoke the double-click edit path. For tests only.
    func triggerDoubleClickForTesting(at index: Int) {
        editWorkspace(at: index)
    }
}
