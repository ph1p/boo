import SwiftUI
import XCTest

@testable import Exterm

// MARK: - Helper

/// A non-trivial SwiftUI view for testing (like real plugin content).
private struct MockPluginContent: View {
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                    Text("\(label) item \(i)")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
    }
}

private func makeSection(id: String, name: String = "Test") -> SidebarSection {
    SidebarSection(
        id: id,
        name: name,
        icon: "star",
        content: AnyView(MockPluginContent(label: name)),
        prefersOuterScrollView: true
    )
}

private func makePanelView(width: CGFloat = 240, height: CGFloat = 500) -> SidebarPanelView {
    SidebarPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
}

private func mouseDownEvent(for window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: window.convertPoint(fromScreen: .zero),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1.0
    )!
}

final class SidebarLayoutTests: XCTestCase {

    // MARK: - Constants

    func testHeaderHeightConstant() {
        XCTAssertEqual(SidebarLayout.headerHeight, 26)
    }

    func testMinSectionHeightConstant() {
        XCTAssertEqual(SidebarLayout.minSectionHeight, 50)
    }

    // MARK: - Section Data

    func testSidebarSectionInit() {
        let s = makeSection(id: "files", name: "Files")
        XCTAssertEqual(s.id, "files")
        XCTAssertEqual(s.name, "Files")
    }

    // MARK: - Adding Panels

    func testAddSingleExpanded() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates.count, 1)
        XCTAssertTrue(v.sectionStates[0].isExpanded)
    }

    func testAddSingleCollapsed() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: [])
        XCTAssertEqual(v.sectionStates.count, 1)
        XCTAssertFalse(v.sectionStates[0].isExpanded)
    }

    func testAddMultipleSections() {
        let v = makePanelView()
        v.updateSections(
            [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")], expandedIDs: ["a", "b", "c"])
        XCTAssertEqual(v.sectionStates.count, 3)
    }

    func testAddMixedExpandedCollapsed() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")], expandedIDs: ["a", "c"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
    }

    func testAddEmpty() {
        let v = makePanelView()
        v.updateSections([], expandedIDs: [])
        XCTAssertEqual(v.sectionStates.count, 0)
    }

    // MARK: - Removing Panels

    func testRemoveSection() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b")], expandedIDs: ["a", "b"])
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates.count, 1)
    }

    func testRemoveAllSections() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        v.updateSections([], expandedIDs: [])
        XCTAssertEqual(v.sectionStates.count, 0)
    }

    func testReplaceSections() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b")], expandedIDs: ["a"])
        v.updateSections([makeSection(id: "c"), makeSection(id: "d")], expandedIDs: ["c", "d"])
        XCTAssertEqual(v.sectionStates.count, 2)
        XCTAssertEqual(v.sectionStates[0].id, "c")
    }

    // MARK: - Fold / Unfold

    func testCollapseSection() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["b"])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertEqual(v.sectionStates[0].contentHeight, 0)
    }

    func testExpandSection() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertGreaterThan(v.sectionStates[1].contentHeight, 0)
    }

    func testCollapseAllSections() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: [])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
    }

    func testExpandAllFromCollapsed() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: [])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
    }

    func testToggleBackAndForth() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["b"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
    }

    // MARK: - Expand last doesn't disturb collapsed middle

    func testExpandLastDoesNotExpandMiddle() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "c"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
        XCTAssertEqual(v.sectionStates[1].contentHeight, 0)
    }

    func testExpandLastFromAllCollapsed() {
        let v = makePanelView(height: 400)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: [])
        v.updateSections(s, expandedIDs: ["c"])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
        XCTAssertGreaterThan(v.sectionStates[2].contentHeight, SidebarLayout.minSectionHeight - 1)
    }

    func testExpandMiddle() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertFalse(v.sectionStates[2].isExpanded)
    }

    func testCollapseFirstThenExpandLast() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["b"])
        v.updateSections(s, expandedIDs: ["b", "c"])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
    }

    // MARK: - Layout correctness

    func testCollapsedSectionHasZeroContentHeight() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates[1].contentHeight, 0)
    }

    func testExpandedSectionHasPositiveContentHeight() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertGreaterThan(v.sectionStates[0].contentHeight, 0)
    }

    func testHeaderViewsAreSubviews() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b")], expandedIDs: ["a"])
        // 2 headers + 1 content hosting = 3 subviews
        XCTAssertEqual(v.subviews.count, 3)
    }

    func testCollapsedNoContentHosting() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: [])
        XCTAssertNil(v.sectionStates[0].contentContainer)
    }

    func testExpandedHasContentHosting() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertNotNil(v.sectionStates[0].contentContainer)
    }

    func testCollapseRemovesContentHosting() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        v.updateSections(s, expandedIDs: ["a"])
        XCTAssertNotNil(v.sectionStates[0].contentContainer)
        v.updateSections(s, expandedIDs: [])
        XCTAssertNil(v.sectionStates[0].contentContainer)
    }

    // MARK: - Idempotency

    func testUpdateSameSectionsIdempotent() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        v.updateSections(s, expandedIDs: ["a"])
        let h = v.sectionStates[0].contentHeight
        v.updateSections(s, expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates[0].contentHeight, h, accuracy: 1)
    }

    // MARK: - Dynamic names

    func testUpdateSectionName() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a", name: "Files")], expandedIDs: ["a"])
        v.updateSections([makeSection(id: "a", name: "Projects")], expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates[0].name, "Projects")
    }

    // MARK: - Toggle callback

    @MainActor func testToggleCallbackFires() {
        let _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let v = makePanelView()
        var toggled: String?
        v.onToggleExpand = { id in toggled = id }
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(v)
        v.frame = window.contentView?.bounds ?? .zero

        v.sectionStates[0].headerView.mouseDown(with: mouseDownEvent(for: window))
        XCTAssertEqual(toggled, "a")
    }

    // MARK: - Header view

    func testHeaderViewCreation() {
        let h = SidebarSectionHeaderView(sectionID: "x", name: "T", icon: "star", isExpanded: true)
        XCTAssertEqual(h.sectionID, "x")
        XCTAssertTrue(h.isFlipped)
    }

    @MainActor func testHeaderViewMouseDownInvokesToggleWithSectionID() {
        let h = SidebarSectionHeaderView(sectionID: "x", name: "A", icon: "star", isExpanded: false)
        var toggled: String?
        h.onToggle = { toggled = $0 }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        h.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(h)

        h.mouseDown(with: mouseDownEvent(for: window))
        XCTAssertEqual(toggled, "x")
    }

    // MARK: - Four sections stress

    func testFourSectionsAllExpanded() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        XCTAssertEqual(v.sectionStates.count, 4)
        XCTAssertTrue(v.sectionStates.allSatisfy(\.isExpanded))
    }

    func testFourSectionsAlternating() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: ["s0", "s2"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
        XCTAssertFalse(v.sectionStates[3].isExpanded)
    }

    func testFourSectionsCycleExpandCollapse() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        let allIDs = Set(s.map(\.id))
        v.updateSections(s, expandedIDs: allIDs)
        for id in allIDs.sorted() {
            v.updateSections(s, expandedIDs: allIDs.subtracting([id]))
        }
        v.updateSections(s, expandedIDs: allIDs)
        XCTAssertEqual(v.sectionStates.count, 4)
        XCTAssertTrue(v.sectionStates.allSatisfy(\.isExpanded))
    }

    // MARK: - Drag resize

    func testDragOnlyAffectsTwoAdjacentSections() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight
        let h3 = v.sectionStates[3].contentHeight

        // Drag between section 2 and 3 — only s2 and s3 should change
        v.handleDrag(
            aboveIndex: 2, belowIndex: 3, delta: 30,
            startHeights: (h2, h3))

        XCTAssertEqual(
            v.sectionStates[0].contentHeight, h0, accuracy: 0.5,
            "Section 0 should not change during drag between 2 and 3")
        XCTAssertEqual(
            v.sectionStates[1].contentHeight, h1, accuracy: 0.5,
            "Section 1 should not change during drag between 2 and 3")
    }

    func testDragPreservesTotalOfTwoSections() {
        let v = makePanelView(height: 600)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let total = h0 + h1

        // Drag down: section 0 grows, section 1 shrinks
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 50,
            startHeights: (h0, h1))

        let newTotal = v.sectionStates[0].contentHeight + v.sectionStates[1].contentHeight
        XCTAssertEqual(
            newTotal, total, accuracy: 0.5,
            "Sum of the two dragged sections must be preserved")
    }

    func testDragCannotShrinkBelowMinHeight() {
        let v = makePanelView(height: 400)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight

        // Drag down by a huge amount — should clamp at min height for below
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 9999,
            startHeights: (h0, h1))

        XCTAssertGreaterThanOrEqual(
            v.sectionStates[1].contentHeight,
            SidebarLayout.minSectionHeight,
            "Below section should not go below min height")
        XCTAssertGreaterThanOrEqual(
            v.sectionStates[0].contentHeight,
            SidebarLayout.minSectionHeight,
            "Above section should not go below min height")
    }

    func testDragUpCannotShrinkAboveBelowMinHeight() {
        let v = makePanelView(height: 400)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight

        // Drag up by a huge amount — should clamp at min height for above
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: -9999,
            startHeights: (h0, h1))

        XCTAssertGreaterThanOrEqual(
            v.sectionStates[0].contentHeight,
            SidebarLayout.minSectionHeight,
            "Above section should not go below min height")
        XCTAssertGreaterThanOrEqual(
            v.sectionStates[1].contentHeight,
            SidebarLayout.minSectionHeight,
            "Below section should not go below min height")
    }

    func testDragPastWindowEdgeDoesNotAffectOtherSections() {
        let v = makePanelView(height: 500)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight

        // Drag the last handle (between s1 and s2) way past the window
        v.handleDrag(
            aboveIndex: 1, belowIndex: 2, delta: 2000,
            startHeights: (h1, h2))

        XCTAssertEqual(
            v.sectionStates[0].contentHeight, h0, accuracy: 0.5,
            "Section 0 must not change when dragging handle between 1 and 2 past edge")
        XCTAssertGreaterThanOrEqual(
            v.sectionStates[2].contentHeight,
            SidebarLayout.minSectionHeight,
            "Last section should be clamped to min, not negative")
    }

    func testDragDoesNotCreateOverflow() {
        let v = makePanelView(height: 400)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight

        // Drag between 0 and 1
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 30,
            startHeights: (h0, h1))

        // Total content height should not exceed available
        let available =
            v.bounds.height
            - CGFloat(3) * SidebarLayout.headerHeight
            - CGFloat(2) * SidebarLayout.separatorHeight
        let total = v.sectionStates.filter(\.isExpanded)
            .reduce(CGFloat(0)) { $0 + $1.contentHeight }
        XCTAssertLessThanOrEqual(
            total, available + 1,
            "Total content height must not exceed available space after drag")
    }

    func testCollapseRedistributesSpaceToRemaining() {
        let v = makePanelView(height: 500)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        let allIDs = Set(s.map(\.id))
        v.updateSections(s, expandedIDs: allIDs)
        v.layoutAllSections()

        let availBefore = v.sectionStates.filter(\.isExpanded)
            .reduce(CGFloat(0)) { $0 + $1.contentHeight }

        // Collapse the last section
        v.updateSections(s, expandedIDs: allIDs.subtracting(["s3"]))
        v.layoutAllSections()

        // The remaining 3 expanded sections should fill the available space
        let headers = CGFloat(4) * SidebarLayout.headerHeight
        let seps = CGFloat(3) * SidebarLayout.separatorHeight
        let availableContent = v.bounds.height - headers - seps
        let expandedSum = v.sectionStates.filter(\.isExpanded)
            .reduce(CGFloat(0)) { $0 + $1.contentHeight }

        XCTAssertEqual(
            expandedSum, availableContent, accuracy: 2,
            "Remaining expanded sections should fill available space after collapse")
        XCTAssertEqual(
            v.sectionStates[3].contentHeight, 0,
            "Collapsed section should have zero content height")
    }

    func testCollapseLastSectionPushesHeaderToBottom() {
        let v = makePanelView(height: 500)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        let allIDs = Set(s.map(\.id))
        v.updateSections(s, expandedIDs: allIDs)
        v.layoutAllSections()

        // Collapse the last one
        v.updateSections(s, expandedIDs: allIDs.subtracting(["s2"]))
        v.layoutAllSections()

        // The collapsed header should be positioned after all expanded content
        let lastHeader = v.sectionStates[2].headerView
        let expandedBottom = v.sectionStates[1].headerView.frame.maxY + v.sectionStates[1].contentHeight
        let expectedY = expandedBottom + SidebarLayout.separatorHeight

        XCTAssertEqual(
            lastHeader.frame.origin.y, expectedY, accuracy: 1,
            "Collapsed last section header should sit right below expanded content")
    }

    func testMultipleDragsInSequence() {
        let v = makePanelView(height: 500)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        // Drag handle 0-1 down
        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 40,
            startHeights: (h0, h1))

        // Now drag handle 1-2 down
        let h1b = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight
        v.handleDrag(
            aboveIndex: 1, belowIndex: 2, delta: 30,
            startHeights: (h1b, h2))

        // Section 0 should be unchanged from its post-first-drag value
        let expected0 = min(h0 + h1 - SidebarLayout.minSectionHeight, max(SidebarLayout.minSectionHeight, h0 + 40))
        XCTAssertEqual(
            v.sectionStates[0].contentHeight, expected0, accuracy: 0.5,
            "Section 0 must remain stable after second drag on a different handle")

        // All sections should still be at least min height
        for (i, state) in v.sectionStates.enumerated() where state.isExpanded {
            XCTAssertGreaterThanOrEqual(
                state.contentHeight, SidebarLayout.minSectionHeight,
                "Section \(i) should be at least min height after sequential drags")
        }
    }

    // MARK: - Scroll Position Per Terminal

    func testSetTerminalIDSavesScrollOffsets() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid1 = UUID()
        let tid2 = UUID()

        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])

        // Simulate scrolling by directly setting the scroll view offset
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Switch to terminal 2 — should save terminal 1's offsets
        v.setTerminalID(tid2)

        let saved = v.scrollOffset(for: tid1, sectionID: "a")
        XCTAssertNotNil(saved, "Scroll offset should be saved for terminal 1")
        XCTAssertEqual(saved?.y ?? -1, 42, accuracy: 1, "Saved scroll offset should match")
    }

    func testScrollOffsetRestoredOnTerminalSwitch() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid1 = UUID()
        let tid2 = UUID()

        // Terminal 1: scroll to y=42
        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Switch to terminal 2: scroll to y=100
        v.setTerminalID(tid2)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Switch back to terminal 1 — should restore y=42
        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])

        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            let offset = scrollView.contentView.bounds.origin
            XCTAssertEqual(offset.y, 42, accuracy: 1, "Scroll position should be restored for terminal 1")
        }
    }

    func testScrollOffsetIndependentPerTerminal() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid1 = UUID()
        let tid2 = UUID()

        // Terminal 1 at y=20
        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Terminal 2 at y=80
        v.setTerminalID(tid2)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 80))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Explicitly save terminal 2's offsets before checking
        v.saveScrollOffsets(for: tid2)

        // Verify both are stored independently
        let saved1 = v.scrollOffset(for: tid1, sectionID: "a")
        let saved2 = v.scrollOffset(for: tid2, sectionID: "a")
        XCTAssertEqual(saved1?.y ?? -1, 20, accuracy: 1)
        XCTAssertEqual(saved2?.y ?? -1, 80, accuracy: 1)
    }

    func testScrollOffsetSavedPerSection() {
        let v = makePanelView(height: 600)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        let tid = UUID()

        v.setTerminalID(tid)
        v.updateSections(s, expandedIDs: ["a", "b"])

        // Scroll section a to y=10, section b to y=50
        for (i, expected) in [(0, 10.0), (1, 50.0)] {
            if let scrollView = v.sectionStates[i].contentContainer as? NSScrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: expected))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        // Save and check
        v.saveScrollOffsets(for: tid)
        XCTAssertEqual(v.scrollOffset(for: tid, sectionID: "a")?.y ?? -1, 10, accuracy: 1)
        XCTAssertEqual(v.scrollOffset(for: tid, sectionID: "b")?.y ?? -1, 50, accuracy: 1)
    }

    func testNoSavedOffsetForUnknownTerminal() {
        let v = makePanelView()
        let offset = v.scrollOffset(for: UUID(), sectionID: "a")
        XCTAssertNil(offset)
    }

    func testSameTerminalIDDoesNotSave() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid = UUID()

        v.setTerminalID(tid)
        v.updateSections(s, expandedIDs: ["a"])

        // Scroll to y=42
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Set same terminal ID again — should NOT trigger a save (no transition)
        v.setTerminalID(tid)
        // Offset should not be saved because oldID == newID
        let saved = v.scrollOffset(for: tid, sectionID: "a")
        XCTAssertNil(saved, "Same terminal should not trigger save")
    }

    // MARK: - Real plugin E2E: use actual BookmarksPlugin content in a window

    /// Uses the real BookmarksPlugin to generate content, in a real NSWindow,
    /// with the exact toggle-rebuild cycle from MainWindowController.
    @MainActor func testClickBookmarkHeaderWithRealPlugin() {
        let _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)

        let panel = SidebarPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            panel.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        // Use the real plugins to generate content
        let registry = PluginRegistry()
        registry.registerBuiltins()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            remoteSession: nil,
            gitContext: nil,
            processName: "zsh",
            paneCount: 1,
            tabCount: 1
        )
        var expandedIDs: Set<String> = ["file-tree-local"]

        func makeSections() -> [SidebarSection] {
            var sections: [SidebarSection] = []
            for pluginID in ["file-tree-local", "docker", "bookmarks"] {
                guard let plugin = registry.plugin(for: pluginID),
                    plugin.isVisible(for: context)
                else {
                    continue
                }
                let pluginCtx = registry.buildPluginContext(for: pluginID, terminal: context)
                guard let content = plugin.makeDetailView(context: pluginCtx) else {
                    continue
                }
                sections.append(
                    SidebarSection(
                        id: pluginID,
                        name: plugin.sectionTitle(context: pluginCtx) ?? plugin.manifest.name,
                        icon: plugin.manifest.icon,
                        content: content,
                        prefersOuterScrollView: plugin.prefersOuterScrollView
                    ))
            }
            return sections
        }

        func rebuild() {
            let sections = makeSections()
            panel.onToggleExpand = { id in
                if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
                // Exact same pattern as MainWindowController.rebuildPluginSidebar
                let newSections = makeSections()
                panel.updateSections(newSections, expandedIDs: expandedIDs)
            }
            panel.updateSections(sections, expandedIDs: expandedIDs)
        }

        // Initial load
        rebuild()
        window.layoutIfNeeded()

        let sectionCount = panel.sectionStates.count
        XCTAssertGreaterThan(sectionCount, 0, "Should have visible plugin sections")

        // Find bookmarks section
        let bmIndex = panel.sectionStates.firstIndex(where: { $0.id == "bookmarks" })
        XCTAssertNotNil(bmIndex, "Bookmarks section should exist")
        guard let idx = bmIndex else {
            window.close()
            return
        }

        XCTAssertFalse(panel.sectionStates[idx].isExpanded, "Bookmarks should start collapsed")

        // Click the bookmarks header — THIS IS WHAT CRASHES IN THE REAL APP
        let bmHeader = panel.sectionStates[idx].headerView
        bmHeader.mouseDown(with: mouseDownEvent(for: window))
        window.layoutIfNeeded()

        // Verify it expanded without crashing
        XCTAssertTrue(
            panel.sectionStates[idx].isExpanded,
            "Bookmarks should be expanded after clicking header")

        // Click again to collapse
        panel.sectionStates[idx].headerView.mouseDown(with: mouseDownEvent(for: window))
        window.layoutIfNeeded()

        XCTAssertFalse(
            panel.sectionStates[idx].isExpanded,
            "Bookmarks should be collapsed after second click")

        // Click ALL headers to expand everything
        for i in 0..<panel.sectionStates.count {
            if !panel.sectionStates[i].isExpanded {
                panel.sectionStates[i].headerView.mouseDown(with: mouseDownEvent(for: window))
                window.layoutIfNeeded()
            }
        }
        XCTAssertTrue(
            panel.sectionStates.allSatisfy(\.isExpanded),
            "All sections should be expanded")

        window.close()
    }
}
