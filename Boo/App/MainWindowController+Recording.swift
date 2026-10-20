import Cocoa

// MARK: - Session Recording

/// One terminal currently being recorded in this window.
struct ActiveRecording {
    let paneView: PaneView
    let tabID: UUID
    let view: GhosttyView
    let title: String
    let startDate: Date
}

extension MainWindowController {

    /// Starts or stops an asciicast recording of the active terminal.
    @objc func toggleRecordingAction(_ sender: Any?) {
        guard let workspace = activeWorkspace, let gv = activeGhosttyView, !gv.isInputLocked,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        if gv.isRecording {
            stopRecordings([(pv, gv)])
        } else {
            startRecording(gv, in: pv)
        }
    }

    /// Records the front terminal of every pane in the active workspace that isn't already.
    @objc func recordAllPanesAction(_ sender: Any?) {
        for (pv, gv) in recordablePanes {
            guard startRecording(gv, in: pv) else { return }
        }
    }

    /// Drops a marker into the active terminal's recording; the player jumps between them.
    @objc func addRecordingMarkerAction(_ sender: Any?) {
        guard let gv = activeGhosttyView, let recorder = gv.recorder else { return }
        recorder.addMarker()
        BooAlert.showTransient("Marker added")
    }

    @objc func stopAllRecordingsAction(_ sender: Any?) {
        stopRecordings(activeRecordings.map { ($0.paneView, $0.view) })
    }

    @objc func revealRecordingsFolderAction(_ sender: Any?) {
        let dir = SessionRecorder.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Panes in the active workspace whose front terminal could start recording.
    var recordablePanes: [(PaneView, GhosttyView)] {
        guard let workspace = activeWorkspace else { return [] }
        return workspace.splitTree.leafIDs.compactMap { paneID in
            guard let pv = paneViews[paneID], pv.pane.activeTab?.contentType == .terminal,
                let gv = pv.ghosttyView, !gv.isRecording, !gv.isInputLocked
            else { return nil }
            return (pv, gv)
        }
    }

    /// Whether any terminal in this window records — cheaper than `activeRecordings`.
    var hasActiveRecordings: Bool { recordingCount > 0 }

    private var recordingCount: Int {
        workspacePaneViews.values.reduce(0) { sum, panes in
            panes.values.reduce(sum) { $0 + $1.pane.tabs.lazy.filter(\.state.isRecording).count }
        }
    }

    /// Every recording in this window, across all workspaces and background tabs.
    var activeRecordings: [ActiveRecording] {
        workspacePaneViews.values.flatMap(\.values).flatMap { pv in
            pv.pane.tabs.compactMap { tab -> ActiveRecording? in
                guard tab.state.isRecording, let gv = pv.terminalView(forTab: tab.id),
                    let recorder = gv.recorder
                else { return nil }
                return ActiveRecording(
                    paneView: pv, tabID: tab.id, view: gv, title: tab.title, startDate: recorder.startDate)
            }
        }
        .sorted { $0.startDate < $1.startDate }
    }

    /// Starts recording `gv`; false (after telling the user) when the file couldn't be created.
    @discardableResult
    func startRecording(_ gv: GhosttyView, in pv: PaneView) -> Bool {
        guard let tabID = gv.tabID else { return false }
        let tab = pv.pane.tabs.first { $0.id == tabID }
        let title = tab?.title ?? "terminal"
        do {
            try gv.startRecording(
                to: SessionRecorder.defaultURL(title: title, directory: tab?.workingDirectory), title: title,
                idleTimeLimit: AppSettings.shared.recordingIdleTimeLimit)
        } catch {
            BooAlert.showError(title: "Couldn't start recording", message: error.localizedDescription)
            return false
        }
        pv.setRecording(true, forTab: tabID)
        refreshRecordingSegment()
        return true
    }

    /// Stops each recording, then follows `AppSettings.recordingStopAction` once
    /// every file has been flushed.
    func stopRecordings(_ targets: [(PaneView, GhosttyView)]) {
        var urls: [URL] = []
        let flushed = DispatchGroup()
        for (pv, gv) in targets {
            guard gv.isRecording else { continue }
            flushed.enter()
            if let url = gv.stopRecording(completion: { flushed.leave() }) { urls.append(url) }
            if let tabID = gv.tabID { pv.setRecording(false, forTab: tabID) }
        }
        refreshRecordingSegment()
        let saved = urls
        flushed.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.recordingsFinished(saved) }
        }
    }

    private func recordingsFinished(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch AppSettings.shared.recordingStopAction {
        case .nothing:
            return
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .toast:
            window?.makeKeyAndOrderFront(nil)
            let reveal = BooAlert.ToastAction(title: "Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            let copy = BooAlert.ToastAction(title: urls.count == 1 ? "Copy Path" : "Copy Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            if urls.count == 1, let url = urls.first {
                let play = BooAlert.ToastAction(title: "Play") { [weak self] in
                    self?.handleOpenTab(.file(path: url.path))
                }
                BooAlert.showTransient("Recording saved", actions: [play, reveal, copy])
            } else {
                BooAlert.showTransient("\(urls.count) recordings saved", actions: [reveal, copy])
            }
        }
    }

    /// Syncs the "● N recording" status bar item with the live recordings.
    func refreshRecordingSegment() {
        let count = recordingCount
        let segment = statusBar.recordingSegment
        guard segment.count != count else { return }
        segment.count = count
        statusBar.needsDisplay = true
    }

    /// Lists the recordings with a stop item each, popped from the status bar.
    func showRecordingsMenu(in view: NSView, at point: NSPoint) {
        let recordings = activeRecordings
        guard !recordings.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Recordings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for rec in recordings {
            let elapsed = CastPlayback.formatTime(Date().timeIntervalSince(rec.startDate))
            let item = ClosureMenuItem(title: "Stop “\(rec.title)” — \(elapsed)") { [weak self] in
                self?.stopRecordings([(rec.paneView, rec.view)])
            }
            item.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if recordings.count > 1 {
            menu.addItem(.separator())
            menu.addItem(
                ClosureMenuItem(title: "Stop All Recordings") { [weak self] in
                    self?.stopAllRecordingsAction(nil)
                })
        }
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(title: "Show Recordings Folder") { [weak self] in
                self?.revealRecordingsFolderAction(nil)
            })
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: Pane controls

    /// Makes `pv` the active pane so selector actions target it; false when
    /// it isn't in the active workspace.
    @discardableResult
    private func focusControlsOwner(_ pv: PaneView) -> Bool {
        guard let workspace = activeWorkspace,
            let paneID = paneViews.first(where: { $0.value === pv })?.key
        else { return false }
        if workspace.activePaneID != paneID {
            paneView(pv, didFocus: paneID)
            pv.focusActiveView()
        }
        return true
    }

    /// Handles a click in a pane's corner controls: focus that pane, then act on it.
    func handlePaneControl(_ action: PaneControlAction, in pv: PaneView) {
        guard focusControlsOwner(pv) else { return }
        switch action {
        case .toggleRecording: toggleRecordingAction(nil)
        case .addMarker: addRecordingMarkerAction(nil)
        case .splitRight: splitVerticalAction(nil)
        case .splitDown: splitHorizontalAction(nil)
        case .toggleZoom: toggleZoomPaneAction(nil)
        case .closePane: closePaneAction(nil)
        }
    }

    /// The corner notch's ⋯ menu: the pane's own actions first, then the
    /// window-wide extras. Built per click, after the pane took focus, so the
    /// selector items act on it and validate against current state.
    func paneControlsMenu(for pv: PaneView) -> NSMenu {
        focusControlsOwner(pv)
        let menu = NSMenu()
        let gv = activeGhosttyView
        let entries = PaneControlsView.primaryEntries(
            canRecord: pv.pane.activeTab?.contentType == .terminal && gv?.isInputLocked == false,
            isRecording: gv?.isRecording == true,
            multiPane: pv.showCloseOnSingleTab,
            isZoomed: pv.isZoomed)
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = ClosureMenuItem(title: entry.title) { [weak self, weak pv] in
                guard let self, let pv else { return }
                self.handlePaneControl(entry.action, in: pv)
            }
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            if let shortcut = Self.mainMenuItem(for: Self.selector(for: entry.action)) {
                item.keyEquivalent = shortcut.keyEquivalent
                item.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector, _ symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("New Tab", #selector(newTabAction(_:)), "plus")
        add("Find…", #selector(findAction(_:)), "magnifyingglass")
        add("Clear Scrollback", #selector(clearScrollbackAction(_:)), "eraser")
        menu.addItem(.separator())
        let recording = hasActiveRecordings
        if !recording || !recordablePanes.isEmpty {
            add("Record All Panes", #selector(recordAllPanesAction(_:)), "record.circle")
        }
        if recording {
            add("Stop All Recordings", #selector(stopAllRecordingsAction(_:)), "stop.circle")
        }
        add("Open Recording…", #selector(openRecordingAction(_:)), "play.rectangle")
        add("Show Recordings Folder", #selector(revealRecordingsFolderAction(_:)), "folder")
        menu.addItem(.separator())
        add("Broadcast Input to All Panes", #selector(broadcastToAllPanesAction(_:)), "dot.radiowaves.left.and.right")
        add("Equalize Splits", #selector(equalizeSplitsAction(_:)), "square.split.2x2")
        return menu
    }

    /// The main-menu action behind each pane control.
    private static func selector(for action: PaneControlAction) -> Selector {
        switch action {
        case .toggleRecording: return #selector(toggleRecordingAction(_:))
        case .addMarker: return #selector(addRecordingMarkerAction(_:))
        case .splitRight: return #selector(splitVerticalAction(_:))
        case .splitDown: return #selector(splitHorizontalAction(_:))
        case .toggleZoom: return #selector(toggleZoomPaneAction(_:))
        case .closePane: return #selector(closePaneAction(_:))
        }
    }

    /// The main-menu item for `action`, whose shortcut the notch menu shows.
    private static func mainMenuItem(for action: Selector) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let sub = item.submenu, let found = search(sub) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }
}

/// Menu item that runs a closure; for menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { handler() }
}

/// "● N recording" in red while any terminal in the window records; click
/// lists them with stop items.
final class RecordingSegment: StatusBarPlugin {
    let id = "recording"
    let position: StatusBarPosition = .left
    let priority = 1
    var hitRect: NSRect = .zero
    var count = 0

    var tooltipText: String? { "Click to stop a recording" }

    static func label(count: Int) -> String { "● \(count) recording" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool { count > 0 }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        hitRect = Self.drawAlertLabel(Self.label(count: count), color: theme.error, at: x, y: y)
        return hitRect.width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        WindowManager.shared.controllers.first(where: { $0.window === barView.window })?
            .showRecordingsMenu(in: barView, at: NSPoint(x: hitRect.minX, y: hitRect.minY))
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        count > 0 ? "\(count) recording" + (count == 1 ? "" : "s") : nil
    }
}
