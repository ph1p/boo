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

    private(set) var sectionStates: [SectionState] = []
    var onToggleExpand: ((String) -> Void)?

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
                    removeContentView(at: i)
                    addContentView(
                        at: i,
                        content: section.content,
                        prefersOuterScrollView: section.prefersOuterScrollView)
                    if !wasExpanded {
                        // Use measured intrinsic height from addContentView
                        sectionStates[i].contentHeight = max(
                            SidebarLayout.minSectionHeight,
                            sectionStates[i].intrinsicHeight)
                        hadCollapseOrExpand = true
                    }
                } else {
                    if wasExpanded {
                        sectionStates[i].contentHeight = 0
                        hadCollapseOrExpand = true
                    }
                    removeContentView(at: i)
                }
            }
            if hadCollapseOrExpand {
                redistributeAfterCollapseOrExpand()
            }
            layoutAllSections()
            return
        }

        // Full rebuild
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
            addSubview(header)

            let idx = sectionStates.count
            sectionStates.append(
                SectionState(
                    id: section.id, name: section.name, icon: section.icon,
                    isExpanded: isExpanded,
                    contentHeight: 0,
                    headerView: header, contentContainer: nil))

            if isExpanded {
                addContentView(
                    at: idx,
                    content: section.content,
                    prefersOuterScrollView: section.prefersOuterScrollView)
                // Use measured intrinsic height
                sectionStates[idx].contentHeight = max(
                    SidebarLayout.minSectionHeight,
                    sectionStates[idx].intrinsicHeight)
            }
        }
        distributeEqualExpanded()
        layoutAllSections()
    }

    /// Add a content view for a section, optionally wrapped in an outer NSScrollView.
    private func addContentView(at index: Int, content: AnyView, prefersOuterScrollView: Bool) {
        // Wrap content in a top-leading aligned container to prevent centering
        let aligned =
            content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let hosting = NSHostingView(rootView: aligned)

        // Measure intrinsic content height
        hosting.frame.size.width = max(1, bounds.width)
        let intrinsic = hosting.fittingSize.height
        sectionStates[index].intrinsicHeight = intrinsic
        sectionStates[index].canGrow = !prefersOuterScrollView

        if !prefersOuterScrollView {
            addSubview(hosting)
            sectionStates[index].contentContainer = hosting
            return
        }

        let scrollView = TopAlignedScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        hosting.frame.size.height = intrinsic
        scrollView.documentView = hosting

        addSubview(scrollView)
        sectionStates[index].contentContainer = scrollView
    }

    /// Remove the content view for a section.
    private func removeContentView(at index: Int) {
        sectionStates[index].contentContainer?.removeFromSuperview()
        sectionStates[index].contentContainer = nil
    }

    /// Default height for a newly expanded section — uses intrinsic height if known.
    private func defaultExpandHeight() -> CGFloat {
        SidebarLayout.minSectionHeight
    }

    /// Distribute available space among expanded sections.
    /// Sections with measured intrinsic height get that height.
    /// Growable sections (prefersOuterScrollView=false, e.g. file tree) share remaining space.
    private func distributeEqualExpanded() {
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
                let extra = remaining / CGFloat(growable.count)
                for i in growable {
                    sectionStates[i].contentHeight += extra
                }
            }
            // If no growable sections but there's leftover space, leave it —
            // sections stay at their intrinsic size, empty space at the bottom.
        }
    }

    /// After a collapse or expand, redistribute space so expanded sections
    /// fill the available area. Growable sections absorb extra space first.
    private func redistributeAfterCollapseOrExpand() {
        let expandedIndices = sectionStates.indices.filter { sectionStates[$0].isExpanded }
        guard !expandedIndices.isEmpty else { return }
        let available = availableContentHeight()
        let currentSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
        let diff = available - currentSum
        guard abs(diff) > 1 else { return }

        if diff > 0 {
            // Space freed (collapse) — distribute to growable, or all expanded
            let targets = expandedIndices.filter { sectionStates[$0].canGrow }
            let recipients = targets.isEmpty ? expandedIndices : targets
            let extra = diff / CGFloat(recipients.count)
            for i in recipients {
                sectionStates[i].contentHeight += extra
            }
        }
        // If diff < 0 (new section expanded, overflow), clampHeightsToFit handles it
    }

    /// Total height available for content (total - all headers - separators).
    private func availableContentHeight() -> CGFloat {
        let headers = CGFloat(sectionStates.count) * SidebarLayout.headerHeight
        let seps = CGFloat(max(0, sectionStates.count - 1)) * SidebarLayout.separatorHeight
        return max(0, bounds.height - headers - seps)
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

            // Content
            if state.isExpanded, let container = state.contentContainer {
                let ch = max(0, state.contentHeight)
                container.frame = NSRect(x: 0, y: y, width: w, height: ch)
                // Size documentView to scroll view width; height = intrinsic content
                if let scrollView = container as? NSScrollView,
                    let docView = scrollView.documentView
                {
                    docView.frame.size.width = w
                    let fitting = docView.fittingSize.height
                    docView.frame.size.height = fitting
                } else {
                    // Direct hosting view (no scroll wrapper)
                    container.frame = NSRect(x: 0, y: y, width: w, height: ch)
                }
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

        isDragging = true
        layoutAllSections()
        isDragging = false
    }

    /// Ensure expanded content heights don't exceed available space.
    /// Only shrinks when content overflows — does NOT stretch to fill.
    private func clampHeightsToFit() {
        let available = availableContentHeight()
        let expandedIndices = sectionStates.indices.filter { sectionStates[$0].isExpanded }
        guard !expandedIndices.isEmpty else { return }

        let currentSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
        // Only clamp if overflowing
        guard currentSum > available + 1 else { return }

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
    }

    // MARK: - Drawing (separators)

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

// MARK: - Drag Handle View

/// Invisible view placed at the border between two expanded sections.
/// Handles mouse drag to resize the sections above and below.
class SidebarDragHandleView: NSView {
    var aboveIndex: Int = 0
    var belowIndex: Int = 0
    weak var panelView: SidebarPanelView?

    private var dragStartY: CGFloat = 0
    private var startHeights: (CGFloat, CGFloat) = (0, 0)

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = panelView else { return }
        dragStartY = convert(event.locationInWindow, from: nil).y
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
        onToggle?(sectionID)
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
