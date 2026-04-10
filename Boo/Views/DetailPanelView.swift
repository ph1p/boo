import Cocoa
import SwiftUI

// MARK: - Layout Constants

enum SidebarLayout {
    static let headerHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 1
    static let minSectionHeight: CGFloat = 50
}

// MARK: - Section Data

struct SidebarSection: Identifiable {
    let id: String
    let name: String
    let icon: String
    let content: AnyView
    let prefersOuterScrollView: Bool
    /// Monotonic generation counter. `updateContentView` is skipped when generation matches.
    let generation: UInt64
}

// MARK: - Sidebar Panel View

/// Custom stacked panel view (no NSSplitView). Each section has a header and optional
/// content area. Collapsed sections show header only. Drag the bottom edge of a header
/// to resize the section above. Headers push each other — they cannot overlap.
class SidebarPanelView: NSView {
    struct SectionState {
        let id: String
        var name: String
        var icon: String
        var isExpanded: Bool
        /// Content height for expanded sections (the portion below the header).
        var contentHeight: CGFloat
        /// Intrinsic content height measured from SwiftUI fittingSize.
        var intrinsicHeight: CGFloat = 0
        /// Whether this section can grow to fill remaining space (e.g. file tree, git).
        var canGrow: Bool = false
        var headerView: SidebarSectionHeaderView
        /// Container view that clips the SwiftUI content hosting view.
        var contentContainer: NSView?
    }

    private struct SectionDragState {
        let sourceIndex: Int
        let ghostWindow: NSWindow
        /// Index *before* which to insert the dragged section (nil = no valid target).
        var dropTargetIndex: Int?
        /// Pre-computed Y for the drop indicator line, in panel coordinates.
        var indicatorY: CGFloat = 0
    }

    private(set) var sectionStates: [SectionState] = []
    var onToggleExpand: ((String) -> Void)?
    /// Called when the user reorders sections via drag-and-drop. Receives the new ordered IDs.
    var onReorderSections: (([String]) -> Void)?
    /// Called when the user hides a section via right-click. Receives the sectionID.
    var onHideSection: ((String) -> Void)?

    private var sectionDragState: SectionDragState?

    /// Last known generation per section ID — skip updateContentView when unchanged.
    private var sectionGenerations: [String: UInt64] = [:]

    /// Section heights by plugin ID — shared with the window controller
    /// so heights survive panel view recreation (sidebar hide/show).
    var savedSectionHeights: [String: CGFloat] = [:]

    /// Current terminal ID — used to save/restore scroll positions per terminal.
    private(set) var currentTerminalID: UUID?
    /// Saved scroll offsets keyed by "terminalID:sectionID".
    private var savedScrollOffsets: [String: NSPoint] = [:]

    /// Drag handle views placed between two expanded sections.
    private var dragHandles: [SidebarDragHandleView] = []
    /// Reentrancy guard for layout.
    private var isLayingOut = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Terminal Switch

    /// Call before updating sections when the terminal changes.
    /// Saves scroll offsets for the old terminal, then sets the new terminal ID.
    func setTerminalID(_ newID: UUID?) {
        if let oldID = currentTerminalID, oldID != newID {
            saveScrollOffsets(for: oldID)
        }
        currentTerminalID = newID
    }

    /// Save scroll offsets for all expanded sections that use an outer NSScrollView.
    func saveScrollOffsets(for terminalID: UUID) {
        for state in sectionStates where state.isExpanded {
            if let scrollView = state.contentContainer as? NSScrollView {
                let key = "\(terminalID.uuidString):\(state.id)"
                savedScrollOffsets[key] = scrollView.contentView.bounds.origin
            }
        }
    }

    /// Restore scroll offsets for all expanded sections that use an outer NSScrollView.
    func restoreScrollOffsets(for terminalID: UUID) {
        for state in sectionStates where state.isExpanded {
            if let scrollView = state.contentContainer as? NSScrollView {
                let key = "\(terminalID.uuidString):\(state.id)"
                if let offset = savedScrollOffsets[key] {
                    scrollView.contentView.scroll(to: offset)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }

    /// Lookup a saved scroll offset (for testing).
    func scrollOffset(for terminalID: UUID, sectionID: String) -> NSPoint? {
        savedScrollOffsets["\(terminalID.uuidString):\(sectionID)"]
    }

    /// Save the currently visible sidebar UI state into the persisted dictionaries.
    /// Heights are stored per expanded section; scroll offsets are stored per terminal.
    func capturePersistentState() {
        if let terminalID = currentTerminalID {
            saveScrollOffsets(for: terminalID)
        }
        for state in sectionStates where state.isExpanded && state.contentHeight > 0 {
            savedSectionHeights[state.id] = state.contentHeight
        }
    }

    var savedScrollOffsetsSnapshot: [String: CGPoint] {
        get { savedScrollOffsets.mapValues { CGPoint(x: $0.x, y: $0.y) } }
        set { savedScrollOffsets = newValue.mapValues { NSPoint(x: $0.x, y: $0.y) } }
    }

    // MARK: - Update

    func updateSections(_ sections: [SidebarSection], expandedIDs: Set<String>) {
        let newIDs = sections.map(\.id)
        let oldIDs = sectionStates.map(\.id)

        if newIDs == oldIDs {
            var hadCollapseOrExpand = false
            for (i, section) in sections.enumerated() {
                let wasExpanded = sectionStates[i].isExpanded
                let isNowExpanded = expandedIDs.contains(section.id)
                sectionStates[i].name = section.name
                sectionStates[i].icon = section.icon
                sectionStates[i].isExpanded = isNowExpanded
                sectionStates[i].headerView.update(
                    name: section.name, icon: section.icon, isExpanded: isNowExpanded)

                if isNowExpanded {
                    if wasExpanded {
                        // Only update rootView if the content generation changed
                        if sectionGenerations[section.id] != section.generation {
                            updateContentView(at: i, content: section.content)
                            sectionGenerations[section.id] = section.generation
                        }
                    } else {
                        // Newly expanded — create content view, restore saved height
                        removeContentView(at: i)
                        addContentView(
                            at: i,
                            content: section.content,
                            prefersOuterScrollView: section.prefersOuterScrollView)
                        sectionStates[i].contentHeight = resolvedHeight(
                            for: section.id, intrinsic: sectionStates[i].intrinsicHeight)
                        hadCollapseOrExpand = true
                    }
                } else {
                    if wasExpanded {
                        // Save height before collapsing so it restores on re-expand
                        if sectionStates[i].contentHeight > 0 {
                            savedSectionHeights[sectionStates[i].id] = sectionStates[i].contentHeight
                        }
                        sectionStates[i].contentHeight = 0
                        hadCollapseOrExpand = true
                    }
                    removeContentView(at: i)
                }
            }
            if hadCollapseOrExpand {
                // Restore all expanded sections to their saved heights.
                // Don't redistribute freed space — that causes the "shrink on toggle"
                // bug. clampHeightsToFit in layoutAllSections handles overflow/underflow.
                for i in sectionStates.indices where sectionStates[i].isExpanded {
                    sectionStates[i].contentHeight = resolvedHeight(
                        for: sectionStates[i].id, intrinsic: sectionStates[i].intrinsicHeight)
                }
            }
            layoutAllSections()
            if let tid = currentTerminalID {
                restoreScrollOffsets(for: tid)
            }
            return
        }

        // Save current heights before rebuild so user resizing persists
        for state in sectionStates where state.isExpanded && state.contentHeight > 0 {
            savedSectionHeights[state.id] = state.contentHeight
        }

        // Full rebuild — reset generation tracking
        sectionGenerations.removeAll()
        for handle in dragHandles { handle.removeFromSuperview() }
        dragHandles.removeAll()
        for state in sectionStates {
            state.headerView.removeFromSuperview()
            state.contentContainer?.removeFromSuperview()
        }
        sectionStates.removeAll()

        for section in sections {
            let isExpanded = expandedIDs.contains(section.id)
            let header = SidebarSectionHeaderView(
                sectionID: section.id, name: section.name,
                icon: section.icon, isExpanded: isExpanded)
            header.onToggle = { [weak self] id in self?.onToggleExpand?(id) }
            header.onBeginDrag = { [weak self] id, event in self?.beginSectionDrag(from: id, event: event) }
            // Only allow hiding when there's more than one section (last section must stay)
            if sections.count > 1 {
                header.onHideSection = { [weak self] id in self?.onHideSection?(id) }
            }
            addSubview(header)

            let idx = sectionStates.count
            sectionStates.append(
                SectionState(
                    id: section.id, name: section.name, icon: section.icon,
                    isExpanded: isExpanded,
                    contentHeight: 0,
                    headerView: header, contentContainer: nil))

            sectionGenerations[section.id] = section.generation
            if isExpanded {
                addContentView(
                    at: idx,
                    content: section.content,
                    prefersOuterScrollView: section.prefersOuterScrollView)
                sectionStates[idx].contentHeight = resolvedHeight(
                    for: section.id, intrinsic: sectionStates[idx].intrinsicHeight)
            }
        }
        // Only distribute equally when no saved heights exist (first layout)
        let hasAnySaved = sections.contains { savedSectionHeights[$0.id] != nil }
        if !hasAnySaved {
            distributeEqualExpanded()
        } else {
            clampHeightsToFit()
        }
        layoutAllSections()
        if let tid = currentTerminalID {
            restoreScrollOffsets(for: tid)
        }
    }

    /// Add a content view for a section, optionally wrapped in an outer NSScrollView.
    private func addContentView(at index: Int, content: AnyView, prefersOuterScrollView: Bool) {
        // Wrap content in a top-leading aligned container to prevent centering
        let aligned = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))

        // Measure intrinsic content height
        sectionStates[index].canGrow = prefersOuterScrollView

        if !prefersOuterScrollView {
            let hosting = NSHostingView(rootView: aligned)
            hosting.frame.size.width = max(1, bounds.width)
            sectionStates[index].intrinsicHeight = hosting.fittingSize.height
            addSubview(hosting)
            sectionStates[index].contentContainer = hosting
            return
        }

        let hosting = NSHostingView(rootView: aligned)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.frame.size.width = max(1, bounds.width)
        let intrinsic = hosting.fittingSize.height
        sectionStates[index].intrinsicHeight = intrinsic

        let scrollView = TopAlignedScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.documentView = hosting

        // Pin the hosting view to the scroll view's content guide so
        // Auto Layout keeps the document size in sync — like CSS overflow:auto.
        // The bottom greaterThanOrEqual constraint ensures the hosting view
        // always fills the visible area (like CSS min-height: 100%).
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor)
        ])

        addSubview(scrollView)
        sectionStates[index].contentContainer = scrollView
    }

    /// Update the rootView of an existing hosting view in-place, preserving scroll position.
    private func updateContentView(at index: Int, content: AnyView) {
        let aligned = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        let container = sectionStates[index].contentContainer

        // Find the NSHostingView — either directly or inside a scroll view
        if let h = container as? NSHostingView<AnyView> {
            h.rootView = aligned
        } else if let scrollView = container as? NSScrollView,
            let h = scrollView.documentView as? NSHostingView<AnyView>
        {
            h.rootView = aligned
        }
    }

    /// Remove the content view for a section.
    private func removeContentView(at index: Int) {
        sectionStates[index].contentContainer?.removeFromSuperview()
        sectionStates[index].contentContainer = nil
    }

    /// Resolved content height for a section — saved height if available, otherwise intrinsic.
    private func resolvedHeight(for sectionID: String, intrinsic: CGFloat) -> CGFloat {
        return max(SidebarLayout.minSectionHeight, savedSectionHeights[sectionID] ?? intrinsic)
    }

    /// Distribute available space among expanded sections.
    /// Sections with measured intrinsic height get that height first.
    /// Remaining space is then distributed proportionally to growable sections
    /// so resize ratios remain stable, closer to VS Code's stacked views.
    private func distributeEqualExpanded() {
        guard bounds.height > 0 else { return }
        let expandedIndices = sectionStates.indices.filter { sectionStates[$0].isExpanded }
        guard !expandedIndices.isEmpty else { return }
        let available = availableContentHeight()

        // First pass: give each section its intrinsic height (or min)
        for i in expandedIndices {
            let intrinsic = sectionStates[i].intrinsicHeight
            sectionStates[i].contentHeight = max(SidebarLayout.minSectionHeight, intrinsic)
        }

        // Sum assigned heights
        let assignedSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
        let remaining = available - assignedSum

        // Second pass: distribute remaining space to growable sections
        if remaining > 0 {
            let growable = expandedIndices.filter { sectionStates[$0].canGrow }
            if !growable.isEmpty {
                distributeRemainingSpace(remaining, across: growable)
            }
            // If no growable sections but there's leftover space, leave it —
            // sections stay at their intrinsic size, empty space at the bottom.
        }

        // Save distributed heights so they survive collapse/expand toggles
        for i in expandedIndices {
            savedSectionHeights[sectionStates[i].id] = sectionStates[i].contentHeight
        }
    }

    /// Total height available for content (total - all headers - separators).
    private func availableContentHeight() -> CGFloat {
        let headers = CGFloat(sectionStates.count) * SidebarLayout.headerHeight
        let seps = CGFloat(max(0, sectionStates.count - 1)) * SidebarLayout.separatorHeight
        return max(0, bounds.height - headers - seps)
    }

    private func distributeRemainingSpace(_ remaining: CGFloat, across indices: [Int]) {
        guard remaining > 0, !indices.isEmpty else { return }
        let currentTotal = indices.reduce(CGFloat(0)) {
            $0 + max(SidebarLayout.minSectionHeight, sectionStates[$1].contentHeight)
        }
        if currentTotal <= 0 {
            let extra = remaining / CGFloat(indices.count)
            for i in indices {
                sectionStates[i].contentHeight += extra
            }
            return
        }
        for i in indices {
            let basis = max(SidebarLayout.minSectionHeight, sectionStates[i].contentHeight)
            sectionStates[i].contentHeight += remaining * (basis / currentTotal)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if !isLayingOut {
            layoutAllSections()
        }
    }

    /// Position all headers, content views, and drag handles from top to bottom.
    func layoutAllSections() {
        guard bounds.width > 0, !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let w = bounds.width

        // During drag, the two sections are already constrained by handleDrag.
        // Only clamp on non-drag layouts (window resize, section toggle, etc.)
        if !isDragging {
            clampHeightsToFit()
        }

        for handle in dragHandles {
            handle.isHidden = true
        }

        var y: CGFloat = 0
        for (i, state) in sectionStates.enumerated() {
            if i > 0 {
                y += SidebarLayout.separatorHeight
            }

            // Header
            state.headerView.frame = NSRect(x: 0, y: y, width: w, height: SidebarLayout.headerHeight)
            y += SidebarLayout.headerHeight

            // Content — inset 2pt top/bottom so content doesn't press against headers.
            if state.isExpanded, let container = state.contentContainer {
                let ch = max(0, state.contentHeight)
                let pad: CGFloat = 2
                container.frame = NSRect(x: 0, y: y + pad, width: w, height: max(0, ch - 2 * pad))
                container.isHidden = false
                y += ch
            } else {
                state.contentContainer?.isHidden = true
            }
        }

        // Place drag handles between adjacent expanded sections
        var handleIndex = 0
        for i in 0..<sectionStates.count {
            guard sectionStates[i].isExpanded else { continue }
            // Find the next expanded section
            var nextExpanded: Int?
            for j in (i + 1)..<sectionStates.count {
                if sectionStates[j].isExpanded {
                    nextExpanded = j
                    break
                }
            }
            guard let below = nextExpanded else { continue }

            // The drag handle sits at the bottom of section i's content
            let handleY = sectionStates[i].headerView.frame.maxY + sectionStates[i].contentHeight - 3
            let handle: SidebarDragHandleView
            if handleIndex < dragHandles.count {
                handle = dragHandles[handleIndex]
            } else {
                handle = SidebarDragHandleView(frame: .zero)
                addSubview(handle)
                dragHandles.append(handle)
            }
            handle.aboveIndex = i
            handle.belowIndex = below
            handle.panelView = self
            handle.frame = NSRect(x: 0, y: handleY, width: w, height: 8)
            handle.isHidden = false
            handleIndex += 1
        }

        needsDisplay = true
    }

    /// Whether a drag is in progress — suppresses clampHeightsToFit during layout.
    private var isDragging = false

    /// Called by a drag handle during drag.
    /// Only the two adjacent sections change — all others stay fixed.
    func handleDrag(aboveIndex: Int, belowIndex: Int, delta: CGFloat, startHeights: (CGFloat, CGFloat)) {
        let total = startHeights.0 + startHeights.1
        let minH = SidebarLayout.minSectionHeight

        // Clamp: above can grow at most until below hits min, and vice versa
        let maxAbove = total - minH
        let newAbove = min(maxAbove, max(minH, startHeights.0 + delta))
        let newBelow = total - newAbove

        sectionStates[aboveIndex].contentHeight = newAbove
        sectionStates[belowIndex].contentHeight = newBelow

        // Persist resized heights
        savedSectionHeights[sectionStates[aboveIndex].id] = newAbove
        savedSectionHeights[sectionStates[belowIndex].id] = newBelow

        isDragging = true
        layoutAllSections()
        isDragging = false
    }

    /// Ensure expanded content heights fit available space.
    /// Shrinks when content overflows, and stretches growable sections to fill unused space.
    private func clampHeightsToFit() {
        // Skip clamping before the view has real bounds — saved heights would be
        // incorrectly scaled to zero. layout() fires again once bounds are valid.
        guard bounds.height > 0 else { return }
        let available = availableContentHeight()
        let expandedIndices = sectionStates.indices.filter { sectionStates[$0].isExpanded }
        guard !expandedIndices.isEmpty else { return }

        let currentSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }

        if currentSum > available + 1 {
            // Overflow — shrink to fit
            let overflow = currentSum - available

            // First try to shrink growable sections (file tree etc.)
            let growable = expandedIndices.filter { sectionStates[$0].canGrow }
            let growableSum = growable.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
            let growableShrinkable = growableSum - CGFloat(growable.count) * SidebarLayout.minSectionHeight

            if growableShrinkable >= overflow && !growable.isEmpty {
                let scale = (growableSum - overflow) / growableSum
                for i in growable {
                    sectionStates[i].contentHeight = max(
                        SidebarLayout.minSectionHeight, sectionStates[i].contentHeight * scale)
                }
            } else {
                // Proportional shrink across all expanded sections
                let scale = available / currentSum
                for i in expandedIndices {
                    sectionStates[i].contentHeight = max(
                        SidebarLayout.minSectionHeight, sectionStates[i].contentHeight * scale)
                }
            }

            // Fix rounding
            let newSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
            let correction = available - newSum
            if let last = expandedIndices.last, correction < -0.5 {
                sectionStates[last].contentHeight = max(
                    SidebarLayout.minSectionHeight, sectionStates[last].contentHeight + correction)
            }
        } else if currentSum < available - 1 {
            // Underflow — stretch growable sections to fill remaining space
            let remaining = available - currentSum
            let growable = expandedIndices.filter { sectionStates[$0].canGrow }
            let recipients = growable.isEmpty ? expandedIndices : growable
            distributeRemainingSpace(remaining, across: recipients)
        }
    }

    // MARK: - Section Drag-and-Drop Reordering

    private func beginSectionDrag(from sectionID: String, event: NSEvent) {
        guard let sourceIndex = sectionStates.firstIndex(where: { $0.id == sectionID }) else { return }
        let sectionName = sectionStates[sourceIndex].name

        let titleWidth = (sectionName.uppercased() as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        ]).width
        let ghostWidth = min(titleWidth + 24, 160)
        let ghostHeight: CGFloat = 22

        let ghostView = NSView(frame: NSRect(x: 0, y: 0, width: ghostWidth, height: ghostHeight))
        ghostView.wantsLayer = true
        ghostView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        ghostView.layer?.cornerRadius = 6
        ghostView.layer?.borderColor = NSColor.separatorColor.cgColor
        ghostView.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: sectionName.uppercased())
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = AppSettings.shared.theme.chromeMuted
        label.frame = NSRect(x: 6, y: 2, width: ghostWidth - 12, height: ghostHeight - 4)
        ghostView.addSubview(label)

        let screenPoint = NSEvent.mouseLocation
        let win = NSWindow(
            contentRect: NSRect(
                x: screenPoint.x - ghostWidth / 2,
                y: screenPoint.y - ghostHeight / 2,
                width: ghostWidth, height: ghostHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.contentView = ghostView
        win.orderFront(nil)

        sectionDragState = SectionDragState(sourceIndex: sourceIndex, ghostWindow: win)

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) {
            [weak self] e, stop in
            guard let self, let e else {
                stop.pointee = true
                return
            }
            if e.type == .leftMouseDragged {
                self.updateSectionDrag(event: e)
            } else {
                self.finishSectionDrag()
                stop.pointee = true
            }
        }
    }

    private func updateSectionDrag(event: NSEvent) {
        guard var state = sectionDragState else { return }

        let screenPoint = NSEvent.mouseLocation
        let origin = NSPoint(
            x: screenPoint.x - state.ghostWindow.frame.width / 2,
            y: screenPoint.y - state.ghostWindow.frame.height / 2)
        state.ghostWindow.setFrameOrigin(origin)

        let localPoint = convert(event.locationInWindow, from: nil)
        var dropIndex: Int? = nil
        var y: CGFloat = 0
        for (i, st) in sectionStates.enumerated() {
            if i > 0 { y += SidebarLayout.separatorHeight }
            let headerMid = y + SidebarLayout.headerHeight / 2
            if localPoint.y < headerMid {
                dropIndex = i
                break
            }
            y += SidebarLayout.headerHeight
            if st.isExpanded { y += st.contentHeight }
        }
        let finalY = y  // y is now past the last section — used as "append" position
        if dropIndex == nil { dropIndex = sectionStates.count }

        let src = state.sourceIndex
        if let di = dropIndex, di == src || di == src + 1 {
            dropIndex = nil
        }

        state.dropTargetIndex = dropIndex
        // Compute indicator Y once here so draw() doesn't need to re-walk sectionStates
        if let di = dropIndex {
            state.indicatorY = di == sectionStates.count ? finalY : indicatorYOffset(before: di)
        }
        sectionDragState = state
        needsDisplay = true
    }

    /// Returns the Y coordinate (in panel space) of the top of section at `index`.
    private func indicatorYOffset(before index: Int) -> CGFloat {
        var y: CGFloat = 0
        for (i, st) in sectionStates.enumerated() {
            if i == index { break }
            if i > 0 { y += SidebarLayout.separatorHeight }
            y += SidebarLayout.headerHeight
            if st.isExpanded { y += st.contentHeight }
        }
        return y
    }

    private func finishSectionDrag() {
        guard let state = sectionDragState else { return }
        state.ghostWindow.orderOut(nil)

        if let dropIndex = state.dropTargetIndex {
            var ids = sectionStates.map(\.id)
            let removedID = ids.remove(at: state.sourceIndex)
            let insertAt = dropIndex > state.sourceIndex ? dropIndex - 1 : dropIndex
            ids.insert(removedID, at: min(insertAt, ids.count))
            onReorderSections?(ids)
        }

        sectionDragState = nil
        needsDisplay = true
    }

    // MARK: - Drawing (separators + drop indicator)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        ctx.setFillColor(theme.sidebarBg.cgColor)
        ctx.fill(bounds)

        let w = bounds.width
        var y: CGFloat = 0
        for (i, state) in sectionStates.enumerated() {
            if i > 0 {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.15).cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: w, height: SidebarLayout.separatorHeight))
                y += SidebarLayout.separatorHeight
            }
            y += SidebarLayout.headerHeight
            if state.isExpanded {
                y += state.contentHeight
            }
        }

        if let state = sectionDragState, state.dropTargetIndex != nil {
            let barH: CGFloat = 2
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: 4, y: state.indicatorY - barH / 2, width: w - 8, height: barH))
        }
    }
}

// MARK: - Top-Aligned Scroll View

/// NSScrollView subclass that pins content to the top instead of centering
/// when the document is shorter than the visible area.
private class TopAlignedScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        contentView = clip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }
}

// MARK: - Self-Sizing Hosting View

// MARK: - Drag Handle View

/// View placed at the border between two expanded sections.
/// Handles mouse drag to resize the sections above and below.
/// Shows an accent-colored bar on hover/drag, like VS Code section resize handles.
class SidebarDragHandleView: NSView {
    var aboveIndex: Int = 0
    var belowIndex: Int = 0
    weak var panelView: SidebarPanelView?

    private var dragStartY: CGFloat = 0
    private var startHeights: (CGFloat, CGFloat) = (0, 0)
    private var isActive = false  // true while hovered or dragging

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isActive = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isActive = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let barH: CGFloat = 2
        let r = CGRect(x: 0, y: (bounds.height - barH) / 2, width: bounds.width, height: barH)
        AppSettings.shared.theme.accentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: r).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = panelView else { return }
        let globalPoint = panel.convert(event.locationInWindow, from: nil)
        dragStartY = globalPoint.y
        startHeights = (
            panel.sectionStates[aboveIndex].contentHeight,
            panel.sectionStates[belowIndex].contentHeight
        )
        NSCursor.resizeUpDown.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = panelView else { return }
        let point = panel.convert(event.locationInWindow, from: nil)
        let delta = point.y - dragStartY
        panel.handleDrag(aboveIndex: aboveIndex, belowIndex: belowIndex, delta: delta, startHeights: startHeights)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}

// MARK: - Section Header (AppKit)

class SidebarSectionHeaderView: NSView {
    var sectionID: String
    private var name: String
    private var icon: String
    private var isExpanded: Bool
    var onToggle: ((String) -> Void)?
    /// Called when the user begins dragging this header to reorder sections.
    var onBeginDrag: ((String, NSEvent) -> Void)?
    /// Called when the user right-clicks and chooses "Hide Section".
    /// The closure receives the sectionID. Will be nil when hiding is not allowed
    /// (i.e. this is the last remaining visible section).
    var onHideSection: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init(sectionID: String, name: String, icon: String, isExpanded: Bool) {
        self.sectionID = sectionID
        self.name = name
        self.icon = icon
        self.isExpanded = isExpanded
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(name: String, icon: String, isExpanded: Bool) {
        self.name = name
        self.icon = icon
        self.isExpanded = isExpanded
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let density = AppSettings.shared.sidebarDensity
        let padH: CGFloat = density == .comfortable ? 12 : 8

        ctx.setFillColor(theme.sidebarBg.cgColor)
        ctx.fill(bounds)

        let chevronName = isExpanded ? "chevron.down" : "chevron.right"
        let chevronBox: CGFloat = 12
        if let chevronImage = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(.init(paletteColors: [theme.chromeMuted]))
            let tinted = chevronImage.withSymbolConfiguration(config) ?? chevronImage
            let imgSize = tinted.size
            let chevronX = padH + (chevronBox - imgSize.width) / 2
            let chevronY = (bounds.height - imgSize.height) / 2
            tinted.draw(in: NSRect(x: chevronX, y: chevronY, width: imgSize.width, height: imgSize.height))
        }

        let titleStr = name.uppercased() as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: theme.chromeMuted
        ]
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        let titleY = (bounds.height - titleSize.height) / 2
        titleStr.draw(at: NSPoint(x: padH + chevronBox + 5, y: titleY), withAttributes: titleAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        // Track mouse to distinguish click from drag
        var didDrag = false
        let startPoint = convert(event.locationInWindow, from: nil)

        var nextEvent = event
        while nextEvent.type != .leftMouseUp {
            guard let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            nextEvent = e
            if e.type == .leftMouseDragged {
                let current = convert(e.locationInWindow, from: nil)
                let dist = hypot(current.x - startPoint.x, current.y - startPoint.y)
                if dist > 4 {
                    didDrag = true
                    onBeginDrag?(sectionID, event)
                    break
                }
            }
        }

        if !didDrag {
            onToggle?(sectionID)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if let onHide = onHideSection {
            let item = NSMenuItem(
                title: "Hide \"\(name)\"",
                action: #selector(hideSectionFromMenu),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            _ = onHide  // captured via @objc method below
        } else {
            let item = NSMenuItem(title: "Cannot hide last section", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func hideSectionFromMenu() {
        onHideSection?(sectionID)
    }
}

// MARK: - SwiftUI Bridge

struct SidebarPluginStackView: NSViewRepresentable {
    let sections: [SidebarSection]
    let expandedIDs: Set<String>
    let onToggleExpand: (String) -> Void

    func makeNSView(context: Context) -> SidebarPanelView {
        let view = SidebarPanelView(frame: .zero)
        view.onToggleExpand = onToggleExpand
        view.updateSections(sections, expandedIDs: expandedIDs)
        return view
    }

    func updateNSView(_ nsView: SidebarPanelView, context: Context) {
        nsView.onToggleExpand = onToggleExpand
        nsView.updateSections(sections, expandedIDs: expandedIDs)
    }
}
