import XCTest

@testable import Boo

@MainActor final class PaneControlsTests: XCTestCase {

    private let keys = [
        "openWorkspaceEditorOnCreate", "openGroupEditorOnCreate", "newTabsJoinActiveGroup",
        "paneControlsVisibility", "tabOverflowMode", "highlightRecordingPane", "recordingStopAction",
        "recordingsFolder",
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

    func testMoreButtonShowsOnHoverNextToPlus() throws {
        AppSettings.shared.paneControlsVisibility = .hover
        AppSettings.shared.tabOverflowMode = .scroll
        let pv = makePaneView()
        pv.updatePaneControls()
        XCTAssertFalse(pv.isMoreButtonShown)
        XCTAssertEqual(pv.tabBarButtons, [.plus, .more], "⋯ keeps its slot while hidden")
        let plus = try XCTUnwrap(pv.tabBarButtonSlot(.plus))
        let more = try XCTUnwrap(pv.tabBarButtonSlot(.more))
        XCTAssertEqual(more.minX, plus.maxX)
        XCTAssertNil(pv.tabBarButton(at: NSPoint(x: more.midX, y: more.midY)), "hidden ⋯ takes no clicks")
        XCTAssertEqual(pv.tabBarButton(at: NSPoint(x: plus.midX, y: plus.midY)), .plus)

        pv.isPointerInPane = true
        pv.updatePaneControls()
        XCTAssertTrue(pv.isMoreButtonShown)
        XCTAssertEqual(pv.tabBarButton(at: NSPoint(x: more.midX, y: more.midY)), .more)
    }

    func testNeverVisibilityDropsMoreButton() {
        AppSettings.shared.paneControlsVisibility = .never
        let pv = makePaneView()
        XCTAssertEqual(pv.tabBarButtons, [.plus])
        XCTAssertEqual(pv.tabBarButtonsWidth, pv.plusButtonWidth)
    }

    func testMoreButtonOpensPaneMenuProvider() {
        let pv = makePaneView()
        var built = 0
        pv.paneMenuProvider = {
            built += 1
            return nil
        }
        pv.pressTabBarButton(.more, event: nil)
        XCTAssertEqual(built, 1)
    }

    func testMenuEntriesFollowPaneState() {
        let actions = { (entries: [PaneControlEntry?]) in entries.map { $0?.action } }
        XCTAssertEqual(
            actions(
                PaneControls.primaryEntries(canRecord: true, isRecording: false, multiPane: false, isZoomed: false)),
            [.toggleRecording, nil, .splitRight, .splitDown])
        XCTAssertEqual(
            actions(
                PaneControls.primaryEntries(canRecord: false, isRecording: false, multiPane: true, isZoomed: false)),
            [.splitRight, .splitDown, .toggleZoom])
        let recording = PaneControls.primaryEntries(
            canRecord: true, isRecording: true, multiPane: true, isZoomed: true)
        XCTAssertEqual(
            actions(recording),
            [.toggleRecording, .addMarker, nil, .splitRight, .splitDown, .toggleZoom])
        XCTAssertEqual(recording.first??.title, "Stop Recording")
        XCTAssertEqual(recording.compactMap { $0 }.first { $0.action == .toggleZoom }?.title, "Show All Panes")
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
