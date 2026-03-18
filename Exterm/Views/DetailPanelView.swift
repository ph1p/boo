import SwiftUI
import Cocoa

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
            for (i, section) in sections.enumerated() {
                let wasExpanded = sectionStates[i].isExpanded
                let isNowExpanded = expandedIDs.contains(section.id)
                sectionStates[i].name = section.name
                sectionStates[i].icon = section.icon
                sectionStates[i].isExpanded = isNowExpanded
                sectionStates[i].headerView.update(
                    name: section.name, icon: section.icon, isExpanded: isNowExpanded)

                if isNowExpanded {
                    if !wasExpanded {
                        sectionStates[i].contentHeight = defaultExpandHeight()
                    }
                    removeContentView(at: i)
                    addContentView(
                        at: i,
                        content: section.content,
                        prefersOuterScrollView: section.prefersOuterScrollView)
                } else {
                    if wasExpanded { sectionStates[i].contentHeight = 0 }
                    removeContentView(at: i)
                }
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

            sectionStates.append(SectionState(
                id: section.id, name: section.name, icon: section.icon,
                isExpanded: isExpanded,
                contentHeight: isExpanded ? defaultExpandHeight() : 0,
                headerView: header, contentContainer: nil))

            if isExpanded {
                addContentView(
                    at: sectionStates.count - 1,
                    content: section.content,
                    prefersOuterScrollView: section.prefersOuterScrollView)
            }
        }
        distributeEqualExpanded()
        layoutAllSections()
    }

    /// Add a content view for a section, optionally wrapped in an outer NSScrollView.
    private func addContentView(at index: Int, content: AnyView, prefersOuterScrollView: Bool) {
        let hosting = NSHostingView(rootView: content)

        if !prefersOuterScrollView {
            addSubview(hosting)
            sectionStates[index].contentContainer = hosting
            return
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Give the hosting view an initial width so it can compute intrinsic height
        hosting.frame.size.width = bounds.width
        let fittingHeight = hosting.fittingSize.height
        hosting.frame.size.height = max(fittingHeight, bounds.height)
        scrollView.documentView = hosting

        addSubview(scrollView)
        sectionStates[index].contentContainer = scrollView
    }

    /// Remove the content view for a section.
    private func removeContentView(at index: Int) {
        sectionStates[index].contentContainer?.removeFromSuperview()
        sectionStates[index].contentContainer = nil
    }

    /// Default height for a newly expanded section.
    private func defaultExpandHeight() -> CGFloat {
        return max(SidebarLayout.minSectionHeight, 150)
    }

    /// Give all expanded sections equal content height, fitting the available space.
    private func distributeEqualExpanded() {
        let expandedCount = sectionStates.filter(\.isExpanded).count
        guard expandedCount > 0 else { return }
        let available = availableContentHeight()
        let each = max(SidebarLayout.minSectionHeight, available / CGFloat(expandedCount))
        for i in 0..<sectionStates.count where sectionStates[i].isExpanded {
            sectionStates[i].contentHeight = each
        }
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

        clampHeightsToFit()

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
            if state.isExpanded, let scrollView = state.contentContainer {
                let ch = max(0, state.contentHeight)
                scrollView.frame = NSRect(x: 0, y: y, width: w, height: ch)
                // Size documentView to scroll view width; set height so content is visible
                if let docView = (scrollView as? NSScrollView)?.documentView {
                    docView.frame.size.width = w
                    let fitting = docView.fittingSize.height
                    docView.frame.size.height = max(ch, fitting)
                }
                scrollView.isHidden = false
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

    /// Called by a drag handle during drag.
    func handleDrag(aboveIndex: Int, belowIndex: Int, delta: CGFloat, startHeights: (CGFloat, CGFloat)) {
        let newAbove = max(SidebarLayout.minSectionHeight, startHeights.0 + delta)
        let newBelow = max(SidebarLayout.minSectionHeight, startHeights.1 - (newAbove - startHeights.0))

        if newAbove >= SidebarLayout.minSectionHeight && newBelow >= SidebarLayout.minSectionHeight {
            sectionStates[aboveIndex].contentHeight = newAbove
            sectionStates[belowIndex].contentHeight = newBelow
            layoutAllSections()
        }
    }

    /// Ensure expanded content heights sum to available space.
    private func clampHeightsToFit() {
        let available = availableContentHeight()
        let expandedIndices = sectionStates.indices.filter { sectionStates[$0].isExpanded }
        guard !expandedIndices.isEmpty else { return }

        let currentSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
        if currentSum <= 0 || abs(currentSum - available) < 1 { return }

        let scale = available / currentSum
        for i in expandedIndices {
            sectionStates[i].contentHeight = max(SidebarLayout.minSectionHeight, sectionStates[i].contentHeight * scale)
        }
        let newSum = expandedIndices.reduce(CGFloat(0)) { $0 + sectionStates[$1].contentHeight }
        let correction = available - newSum
        if let last = expandedIndices.last, abs(correction) > 0.5 {
            sectionStates[last].contentHeight = max(SidebarLayout.minSectionHeight, sectionStates[last].contentHeight + correction)
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
            .foregroundColor: theme.chromeMuted,
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
