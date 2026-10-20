import XCTest

@testable import Boo

@MainActor final class PaneControlsTests: XCTestCase {

    private let keys = [
        "openWorkspaceEditorOnCreate", "openGroupEditorOnCreate", "newTabsJoinActiveGroup",
        "paneControlsVisibility", "highlightRecordingPane", "recordingStopAction", "recordingsFolder",
        "recordingFileNameTemplate", "recordingIdleTimeLimit"
    ]

    override func tearDown() async throws {
        await MainActor.run {
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    private func makePaneView(multiPane: Bool = true) -> PaneView {
        let pane = Pane()
        pane.addTab(workingDirectory: "/tmp", title: "t0")
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pv.showCloseOnSingleTab = multiPane
        pv.layoutSubtreeIfNeeded()
        return pv
    }

    // MARK: Settings

    func testNewSettingDefaults() {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let s = AppSettings.shared
        XCTAssertTrue(s.openWorkspaceEditorOnCreate)
        XCTAssertTrue(s.openGroupEditorOnCreate)
        XCTAssertTrue(s.newTabsJoinActiveGroup)
        XCTAssertEqual(s.paneControlsVisibility, .hover)
        XCTAssertTrue(s.highlightRecordingPane)
        XCTAssertEqual(s.recordingStopAction, .toast)
        XCTAssertEqual(s.recordingsFolder, "")
        XCTAssertEqual(s.recordingFileNameTemplate, SessionRecorder.defaultTemplate)
        XCTAssertEqual(s.recordingIdleTimeLimit, 2)
    }

    func testBlankTemplateFallsBackAndIdleLimitClamps() {
        AppSettings.shared.recordingFileNameTemplate = "   "
        XCTAssertEqual(AppSettings.shared.recordingFileNameTemplate, SessionRecorder.defaultTemplate)
        AppSettings.shared.recordingIdleTimeLimit = -4
        XCTAssertEqual(AppSettings.shared.recordingIdleTimeLimit, 0)
    }

    func testCustomRecordingsFolderIsUsed() {
        AppSettings.shared.recordingsFolder = "~/casts"
        XCTAssertEqual(SessionRecorder.recordingsDirectory.path, NSString(string: "~/casts").expandingTildeInPath)
        AppSettings.shared.recordingsFolder = ""
        XCTAssertEqual(SessionRecorder.recordingsDirectory.path, BooPaths.recordingsDir)
    }

    // MARK: Visibility

    func testExpandedPerVisibilitySetting() {
        XCTAssertTrue(PaneView.paneControlsExpanded(.hover, pointerInside: true, isFocused: false))
        XCTAssertFalse(PaneView.paneControlsExpanded(.hover, pointerInside: false, isFocused: true))
        XCTAssertTrue(PaneView.paneControlsExpanded(.focused, pointerInside: false, isFocused: true))
        XCTAssertFalse(PaneView.paneControlsExpanded(.focused, pointerInside: false, isFocused: false))
        XCTAssertFalse(PaneView.paneControlsExpanded(.never, pointerInside: true, isFocused: true))
    }

    func testHiddenUntilHovered() {
        AppSettings.shared.paneControlsVisibility = .hover
        let pv = makePaneView()
        pv.updatePaneControls()
        XCTAssertFalse(pv.paneControlsShown)
        pv.isPointerInPane = true
        pv.updatePaneControls()
        XCTAssertTrue(pv.paneControlsShown)
        XCTAssertFalse(pv.paneControls.isHidden)
    }

    func testNotchSitsInBottomRightCorner() {
        let pv = makePaneView()
        pv.isPointerInPane = true
        pv.updatePaneControls()
        let frame = pv.paneControls.frame
        XCTAssertEqual(frame.maxX, pv.bounds.width, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, pv.bounds.height, accuracy: 0.5)
        XCTAssertEqual(frame.height, PaneControlsView.height)
    }

    func testNotchOnlyTakesClicksInItsBody() {
        let pv = makePaneView()
        pv.isPointerInPane = true
        pv.updatePaneControls()
        let controls = pv.paneControls
        let body = controls.convert(controls.bodyRect, to: pv)
        XCTAssertNotNil(controls.hitTest(NSPoint(x: body.midX, y: body.midY)))
        XCTAssertGreaterThan(body.minY, controls.frame.minY)
        XCTAssertEqual(body.maxY, controls.frame.maxY, accuracy: 0.5)
        // The fillets above the body and left of it belong to the content.
        XCTAssertNil(controls.hitTest(NSPoint(x: controls.frame.maxX - 1, y: controls.frame.minY + 1)))
        XCTAssertNil(controls.hitTest(NSPoint(x: controls.frame.minX + 1, y: controls.frame.maxY - 1)))
    }

    func testIslandEdgeRunsAroundTheCut() {
        let pv = makePaneView()
        XCTAssertEqual(pv.layer?.borderWidth, IslandMetrics.borderWidth)
        XCTAssertTrue(pv.islandCutStroke.isHidden)
        pv.isPointerInPane = true
        pv.updatePaneControls()
        XCTAssertEqual(pv.layer?.borderWidth, 0)
        XCTAssertFalse(pv.islandCutStroke.isHidden)
        XCTAssertNotNil(pv.islandCutStroke.path)
        XCTAssertEqual(pv.islandCutStroke.color.cgColor, pv.layer?.borderColor)
    }

    func testIslandOutlineSkirtsTheNotch() {
        let path = PaneControlsView.islandOutline(
            paneSize: NSSize(width: 300, height: 200), notchWidth: 40, radius: 6)
        XCTAssertEqual(path.boundingBox.minX, 0.5, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxY, 199.5, accuracy: 0.01)
        // Inside the pane, but not inside the cut corner.
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 100)))
        XCTAssertFalse(path.contains(CGPoint(x: 290, y: 195)))
        XCTAssertTrue(path.contains(CGPoint(x: 250, y: 195)))
    }

    func testCollapsedNotchKeepsZoomButton() {
        AppSettings.shared.paneControlsVisibility = .hover
        let pv = makePaneView()
        pv.updatePaneControls()
        XCTAssertFalse(pv.paneControlsShown)
        pv.isZoomed = true
        XCTAssertTrue(pv.paneControlsShown)
        XCTAssertFalse(pv.paneControls.isExpanded)
        pv.isZoomed = false
        XCTAssertFalse(pv.paneControlsShown)
    }

    func testMenuEntriesFollowPaneState() {
        let actions = { (entries: [PaneControlEntry?]) in entries.map { $0?.action } }
        XCTAssertEqual(
            actions(
                PaneControlsView.primaryEntries(canRecord: true, isRecording: false, multiPane: false, isZoomed: false)),
            [.toggleRecording, nil, .splitRight, .splitDown])
        XCTAssertEqual(
            actions(
                PaneControlsView.primaryEntries(canRecord: false, isRecording: false, multiPane: true, isZoomed: false)),
            [.splitRight, .splitDown, .toggleZoom, nil, .closePane])
        let recording = PaneControlsView.primaryEntries(
            canRecord: true, isRecording: true, multiPane: true, isZoomed: true)
        XCTAssertEqual(
            actions(recording),
            [.toggleRecording, .addMarker, nil, .splitRight, .splitDown, .toggleZoom, nil, .closePane])
        XCTAssertEqual(recording.first??.title, "Stop Recording")
        XCTAssertEqual(recording.compactMap { $0 }.first { $0.action == .toggleZoom }?.title, "Show All Panes")
    }

    func testNarrowPaneHidesControls() {
        let pv = makePaneView()
        pv.frame.size.width = 60
        pv.isPointerInPane = true
        pv.updatePaneControls()
        XCTAssertFalse(pv.paneControlsShown)
    }

    func testRecordingBorderHiddenWithoutRecording() {
        let pv = makePaneView()
        pv.updatePaneControls()
        XCTAssertTrue(pv.recordingBorder.isHidden)
    }

    // MARK: Recording UI

    func testElapsedFormat() {
        XCTAssertEqual(CastPlayback.formatTime(0), "0:00")
        XCTAssertEqual(CastPlayback.formatTime(65), "1:05")
        XCTAssertEqual(CastPlayback.formatTime(3725), "1:02:05")
        XCTAssertEqual(CastPlayback.formatTime(-3), "0:00")
    }

    func testRecordingSegmentLabelAndVisibility() {
        let segment = RecordingSegment()
        let state = StatusBarState(
            currentDirectory: "/tmp", paneCount: 2, tabCount: 2, runningProcess: "", isRemote: false)
        XCTAssertFalse(segment.isVisible(settings: AppSettings.shared, state: state))
        XCTAssertNil(segment.accessibilitySegmentLabel(state: state))
        segment.count = 2
        XCTAssertTrue(segment.isVisible(settings: AppSettings.shared, state: state))
        XCTAssertEqual(RecordingSegment.label(count: 2), "● 2 recording")
        XCTAssertEqual(segment.accessibilitySegmentLabel(state: state), "2 recordings")
    }

    func testDefaultURLAvoidsExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        AppSettings.shared.recordingsFolder = dir.path
        let date = Date(timeIntervalSince1970: 0)
        let first = SessionRecorder.defaultURL(title: "zsh", date: date)
        FileManager.default.createFile(atPath: first.path, contents: nil)
        let second = SessionRecorder.defaultURL(title: "zsh", date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-zsh-2.cast"), second.lastPathComponent)
    }

    func testFileNameTemplateTokens() {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 3, 4)
        (components.hour, components.minute, components.second) = (5, 6, 7)
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(
            SessionRecorder.fileName(template: "{date}-{time}-{title}", title: "vim a/b", directory: nil, date: date),
            "2026-03-04-050607-vim-a-b")
        XCTAssertEqual(
            SessionRecorder.fileName(template: "{dir} {title}", title: "zsh", directory: "/Users/x/boo", date: date),
            "boo zsh")
        // Nothing usable left: falls back to the timestamp.
        XCTAssertEqual(
            SessionRecorder.fileName(template: "///", title: "zsh", directory: nil, date: date), "2026-03-04-050607")
    }
}
