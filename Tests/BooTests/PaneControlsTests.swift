import XCTest

@testable import Boo

@MainActor final class PaneControlsTests: XCTestCase {

    private let keys = [
        "openWorkspaceEditorOnCreate", "openGroupEditorOnCreate", "newTabsJoinActiveGroup",
        "paneControlsVisibility", "highlightRecordingPane", "recordingStopAction", "recordingsFolder"
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

    func testControlsSitInContentTopRightCorner() {
        let pv = makePaneView()
        pv.isPointerInPane = true
        pv.updatePaneControls()
        let frame = pv.paneControls.frame
        XCTAssertEqual(frame.maxX, pv.bounds.width - 8, accuracy: 0.5)
        XCTAssertEqual(frame.minY, pv.tabBarHeight + 8, accuracy: 0.5)
        XCTAssertEqual(frame.height, PaneControlsView.height)
    }

    func testCloseAndZoomOnlyWithSeveralPanes() {
        let single = makePaneView(multiPane: false)
        single.isPointerInPane = true
        single.updatePaneControls()
        let multi = makePaneView(multiPane: true)
        multi.isPointerInPane = true
        multi.updatePaneControls()
        // Zoom + close add two buttons.
        XCTAssertEqual(multi.paneControls.frame.width - single.paneControls.frame.width, 48, accuracy: 0.5)
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
}
