import CGhostty
import Cocoa

extension GhosttyView {
    // MARK: - Search

    func startSearch() { sendBindingAction("start_search") }
    func updateSearch(needle: String) { sendBindingAction(needle.isEmpty ? "end_search" : "search:\(needle)") }
    func endSearch() { sendBindingAction("end_search") }
    func navigateSearch(next: Bool) { sendBindingAction(next ? "navigate_search:next" : "navigate_search:previous") }

    // MARK: - Copy / Paste / Flash

    @objc func copy(_ sender: Any?) {
        if let range = copyModeOverlay?.state.range {
            copyScreenText(from: range.start, to: range.end)
            return
        }
        sendBindingAction("copy:clipboard")
    }

    /// Scrolls to the previous (-1) or next (1) shell prompt (OSC 133 A).
    func jumpToPrompt(_ delta: Int) { sendBindingAction("jump_to_prompt:\(delta)") }

    @objc override func selectAll(_ sender: Any?) { sendBindingAction("select_all") }

    private func sendBindingAction(_ action: String) {
        guard let surface = surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Quick select

    /// Label the matches on screen; the next keys pick one. Beeps when
    /// there is nothing to pick.
    func startQuickSelect() {
        guard quickSelectOverlay == nil, let rows = gridSize?.rows, let cellWidth, let cellHeight else { return }
        endCopyMode()
        let lines = (0..<Int(rows)).map { viewportLine($0) ?? "" }
        let matches = QuickSelect.matches(in: lines)
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let overlay = QuickSelectOverlay(
            frame: bounds, matches: matches,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            onPick: { [weak self] text, insert in
                guard let self else { return }
                self.endQuickSelect()
                if insert {
                    self.sendText(text)
                } else {
                    self.copyToPasteboard(text)
                    self.flashTerminal(nil)
                }
            },
            onCancel: { [weak self] in self?.endQuickSelect() })
        addSubview(overlay)
        quickSelectOverlay = overlay
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    func endQuickSelect() {
        quickSelectOverlay?.removeFromSuperview()
        quickSelectOverlay = nil
    }

    // MARK: - Copy mode

    /// A keyboard cursor over the scrollback; starts on the shell cursor
    /// when the view is at the bottom, else mid-viewport.
    func startCopyMode() {
        guard copyModeOverlay == nil, let surface, let size = gridSize, let cellWidth, let cellHeight else { return }
        endQuickSelect()
        let rows = Int(size.rows)
        let bar = scrollbar ?? GhosttyScrollbar(total: rows, offset: 0, len: rows)

        var cursor = CopyMode.Point(row: bar.offset + rows / 2, column: 0)
        if bar.offset + bar.len >= bar.total {
            var x = 0.0
            var y = 0.0
            var w = 0.0
            var h = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
            let row = Int((CGFloat(y) - cellHeight / 2 - Self.gridPadding) / cellHeight)
            let column = Int((CGFloat(x) - Self.gridPadding + cellWidth / 2) / cellWidth)
            cursor = CopyMode.Point(row: bar.offset + min(max(0, row), rows - 1), column: max(0, column))
        }

        let state = CopyMode(
            cursor: cursor, rows: bar.total, columns: Int(size.columns), pageRows: bar.len,
            cells: { [weak self] row in CopyMode.cells(of: self?.screenLine(row) ?? "") })
        let overlay = CopyModeOverlay(
            frame: bounds, state: state, cellSize: CGSize(width: cellWidth, height: cellHeight),
            viewport: { [weak self] in
                let bar = self?.scrollbar
                return (bar?.offset ?? 0, bar?.len ?? rows)
            },
            onScroll: { [weak self] top in self?.sendBindingAction("scroll_to_row:\(top)") },
            onCopy: { [weak self] start, end in
                guard let self else { return }
                self.copyScreenText(from: start, to: end)
                self.endCopyMode()
                self.flashTerminal(nil)
            },
            onExit: { [weak self] in self?.endCopyMode() })
        addSubview(overlay)
        copyModeOverlay = overlay
        copyModeReturnRow = bar.offset
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    /// Leaves copy mode, scrolling back to where it started.
    func endCopyMode(restoreScroll: Bool = true) {
        guard let overlay = copyModeOverlay else { return }
        overlay.removeFromSuperview()
        copyModeOverlay = nil
        if restoreScroll, let row = copyModeReturnRow { sendBindingAction("scroll_to_row:\(row)") }
        copyModeReturnRow = nil
    }

    /// One screen row (scrollback included) as text.
    private func screenLine(_ row: Int) -> String? {
        guard let columns = gridSize?.columns, columns > 0 else { return nil }
        return readScreenText(
            from: CopyMode.Point(row: row, column: 0), to: CopyMode.Point(row: row, column: Int(columns) - 1))
    }

    private func readScreenText(from start: CopyMode.Point, to end: CopyMode.Point) -> String? {
        readText(GHOSTTY_POINT_SCREEN, from: start, to: end)
    }

    /// Text between two exact grid points in the given coordinate space.
    private func readText(_ tag: ghostty_point_tag_e, from start: CopyMode.Point, to end: CopyMode.Point) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(0, start.column)), y: UInt32(max(0, start.row))),
            bottom_right: ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(0, end.column)), y: UInt32(max(0, end.row))),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    private func copyScreenText(from start: CopyMode.Point, to end: CopyMode.Point) {
        guard let text = readScreenText(from: start, to: end), !text.isEmpty else {
            NSSound.beep()
            return
        }
        copyToPasteboard(text)
    }

    @objc func flashTerminal(_ sender: Any?) {
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        addSubview(overlay)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 0
        }) {
            MainActor.assumeIsolated { overlay.removeFromSuperview() }
        }
    }

    /// Pastes `text` like ⌘V (bracketed when the program asked for it), so a
    /// multi-line message reaches a TUI as one input; `submit` presses Return after.
    func paste(_ text: String, submit: Bool) {
        sendText(text)
        guard submit else { return }
        // Let the program finish handling the paste before Return arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendKey(keyCode: 0x24, mods: GHOSTTY_MODS_NONE, text: "\r")
        }
    }

    func sendText(_ text: String) {
        guard let surface = surface, !blocksInput else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    /// Types `text` as if the user had (a key table's `send:`).
    func typeText(_ text: String) {
        sendText(text)
    }

    /// The terminal has echo turned off (a password prompt), per the pty's termios.
    var isEchoOff: Bool {
        guard let surface else { return false }
        let name = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(name) }
        guard let ptr = name.ptr, name.len > 0 else { return false }
        let path = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(name.len)), as: UTF8.self)
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var attrs = termios()
        guard tcgetattr(fd, &attrs) == 0 else { return false }
        return attrs.c_lflag & tcflag_t(ECHO) == 0
    }

    /// Read the visible viewport text (used by the Remote Control web mirror).
    /// Must be called on the main thread — surface access is not thread-safe.
    func readViewportText() -> String? {
        readText(GHOSTTY_POINT_VIEWPORT)
    }

    /// The last `lines` lines of scrollback plus screen, trailing blank lines dropped.
    func readRecentText(lines: Int) -> String? {
        guard let text = readText(GHOSTTY_POINT_SCREEN) else { return nil }
        var all = text.components(separatedBy: "\n")
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
        return all.suffix(max(lines, 1)).joined(separator: "\n")
    }

    /// The selected text, if any.
    func readSelectionText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    /// The selection, or else the last command's output; nil when both are empty.
    func selectionOrLastOutput() -> (AgentHandoff.Source, String)? {
        if let selection = readSelectionText(), !selection.isEmpty { return (.selection, selection) }
        if let (source, output) = lastCommandOutput(), !output.isEmpty { return (source, output) }
        return nil
    }

    /// Output of the last command run here: from the shell's OSC 133 marks
    /// when it sends them, else matched in the scrollback.
    func lastCommandOutput() -> (AgentHandoff.Source, String)? {
        guard let last = lastCommand else { return nil }
        let source = AgentHandoff.Source.output(command: last.command, exitCode: last.exitCode)
        if let index = lastCommandIndex() {
            return (source, readCommand(index: index, part: .output) ?? "")
        }
        guard let screen = readRecentText(lines: 5000),
            let output = AgentHandoff.output(of: last.command, in: screen, finished: last.exitCode != nil)
        else { return nil }
        return (source, output)
    }

    /// Prompt index of the last command that was run. A finished command is
    /// followed by a fresh prompt, so it starts looking one prompt up; prompts
    /// left empty (Return on a blank line) are skipped.
    func lastCommandIndex() -> Int? {
        let start = commandHistory.last?.isRunning == true ? 0 : 1
        for index in start..<(start + 10) {
            guard let input = readCommand(index: index, part: .input) else { continue }
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return index }
        }
        return nil
    }

    // MARK: - Command blocks (OSC 133 marks, via ghostty-command-output.patch)

    struct PromptMark: Equatable {
        enum Status { case none, succeeded, failed }
        /// Viewport row of the prompt's first line.
        var row: Int
        /// 0 for the newest prompt on the screen, counting up into history.
        var index: Int
        var status: Status
    }

    enum CommandPart { case input, output }

    /// Matches `window-padding-x/y` in the generated Ghostty config.
    nonisolated static let gridPadding: CGFloat = 3

    /// Prompts that start in the viewport, newest first.
    func promptMarks() -> [PromptMark] {
        guard let surface else { return [] }
        var buffer = [ghostty_prompt_mark_s](repeating: ghostty_prompt_mark_s(), count: 256)
        let count = Int(ghostty_surface_prompt_marks(surface, &buffer, UInt(buffer.count)))
        return buffer.prefix(count).map { mark in
            let status: PromptMark.Status
            switch mark.status {
            case GHOSTTY_COMMAND_STATUS_SUCCEEDED: status = .succeeded
            case GHOSTTY_COMMAND_STATUS_FAILED: status = .failed
            default: status = .none
            }
            return PromptMark(row: Int(mark.row), index: Int(mark.index), status: status)
        }
    }

    /// Index of the prompt whose command block contains a viewport row.
    func promptIndex(atViewportRow row: Int) -> Int? {
        guard let surface, row >= 0 else { return nil }
        let index = ghostty_surface_prompt_index_at(surface, UInt32(row))
        return index < 0 ? nil : Int(index)
    }

    /// The typed command or the output of the command block at a prompt index.
    func readCommand(index: Int, part: CommandPart) -> String? {
        guard let surface, index >= 0 else { return nil }
        var text = ghostty_text_s()
        let tag = part == .input ? GHOSTTY_COMMAND_PART_INPUT : GHOSTTY_COMMAND_PART_OUTPUT
        guard ghostty_surface_read_command(surface, UInt32(index), tag, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    /// Height of one grid row in points.
    var cellHeight: CGFloat? {
        guard let size = gridSize, size.cell_height_px > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        return CGFloat(size.cell_height_px) / scale
    }

    /// Width of one grid column in points.
    var cellWidth: CGFloat? {
        guard let size = gridSize, size.cell_width_px > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        return CGFloat(size.cell_width_px) / scale
    }

    /// Viewport row under a point in this view's coordinates.
    func viewportRow(at point: NSPoint) -> Int? {
        guard let cellHeight, let rows = gridSize?.rows else { return nil }
        let fromTop = bounds.height - point.y - Self.gridPadding
        guard fromTop >= 0 else { return nil }
        let row = Int(fromTop / cellHeight)
        return row < Int(rows) ? row : nil
    }

    /// Viewport column under a point in this view's coordinates.
    func viewportColumn(at point: NSPoint) -> Int? {
        guard let cellWidth, let columns = gridSize?.columns else { return nil }
        let x = point.x - Self.gridPadding
        guard x >= 0 else { return nil }
        let column = Int(x / cellWidth)
        return column < Int(columns) ? column : nil
    }

    /// The text of one viewport row.
    func viewportLine(_ row: Int) -> String? {
        guard let columns = gridSize?.columns, columns > 0 else { return nil }
        return readText(
            GHOSTTY_POINT_VIEWPORT, from: CopyMode.Point(row: row, column: 0),
            to: CopyMode.Point(row: row, column: Int(columns) - 1))
    }

    /// The link or file reference under a point, if any.
    func link(at point: NSPoint) -> TerminalLink? {
        guard let row = viewportRow(at: point), let column = viewportColumn(at: point),
            let line = viewportLine(row)
        else { return nil }
        guard let index = LinkResolver.characterIndex(forColumn: column, in: line) else { return nil }
        return LinkResolver.link(in: line, at: index)
    }

    /// Opens the link under `point`; false when there is none.
    func openLink(at point: NSPoint, otherTarget: Bool) -> Bool {
        guard let link = link(at: point) else { return false }
        openLink(link.kind, otherTarget: otherTarget)
        return true
    }

    /// Opens a link from this terminal: relative paths resolve against its
    /// folder, remote files open over its session, and its profile picks the
    /// target.
    func openLink(_ link: TerminalLink.Kind, otherTarget: Bool = false) {
        let location = tabID.flatMap { AgentInbox.locateInWindows($0) }
        let tab = location.map { $0.pane.tabs[$0.tabIndex] }
        let cwd = tab.map { $0.remoteSession != nil ? ($0.remoteWorkingDirectory ?? "") : $0.workingDirectory }
        let origin = LinkOpener.Origin(
            cwd: cwd?.isEmpty == false ? cwd : nil, remote: tab?.remoteSession,
            controller: location?.controller ?? window?.windowController as? MainWindowController)
        let profile = ProfileStore.shared.profile(named: tab?.state.profile)
        let target = profile?.linkTarget ?? AppSettings.shared.defaultLinkTarget
        LinkOpener.open(link, from: origin, target: otherTarget ? target.other : target)
    }

    /// The command typed at a prompt, or nil for an empty prompt.
    func blockCommand(at index: Int) -> String? {
        guard let input = readCommand(index: index, part: .input) else { return nil }
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// Exit code of a command block: from the history when it recorded the
    /// command, else 0 or 1 from the prompt's mark; nil while it runs.
    func exitCode(ofBlock index: Int, command: String) -> Int32? {
        if index == 0, commandHistory.last?.isRunning == true { return nil }
        if let record = commandHistory.records.last(where: { $0.command == command && !$0.isRunning }) {
            return record.exitCode
        }
        switch promptMarks().first(where: { $0.index == index })?.status {
        case .failed: return 1
        case .succeeded: return 0
        default: return nil
        }
    }

    func addCommandBlockItems(to menu: NSMenu, block: Int) {
        guard let command = blockCommand(at: block) else { return }
        var items: [(String, Selector)] = [
            ("Copy Command", #selector(copyBlockCommand(_:))),
            ("Copy Output", #selector(copyBlockOutput(_:)))
        ]
        // Typing into a running program would not re-run anything.
        if commandHistory.last?.isRunning != true {
            items.append(("Re-run “\(AgentHandoffMenuTarget.short(command))”", #selector(rerunBlockCommand(_:))))
        }
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = block
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc private func copyBlockCommand(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? Int, let command = blockCommand(at: block) else { return }
        copyToPasteboard(command)
    }

    @objc private func copyBlockOutput(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? Int else { return }
        copyToPasteboard(readCommand(index: block, part: .output) ?? "")
    }

    @objc private func rerunBlockCommand(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? Int, let command = blockCommand(at: block) else { return }
        paste(command, submit: true)
    }

    /// Copies the last command's output; beeps when there is none.
    @discardableResult
    func copyLastCommandOutput() -> Bool {
        guard let (_, output) = lastCommandOutput(), !output.isEmpty else {
            NSSound.beep()
            return false
        }
        copyToPasteboard(output)
        return true
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func readText(_ tag: ghostty_point_tag_e) -> String? {
        guard let surface = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, Self.wholeArea(tag), &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    /// Selection spanning the whole viewport or screen.
    private static func wholeArea(_ tag: ghostty_point_tag_e) -> ghostty_selection_s {
        ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
    }

    private func string(from text: ghostty_text_s) -> String? {
        guard let ptr = text.text else { return nil }
        return String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                count: Int(text.text_len)),
            as: UTF8.self)
    }

    /// Read the visible viewport as VT sequences (styles, colors, palette,
    /// cursor) for replay into the Remote Control browser-side terminal.
    /// Must be called on the main thread — surface access is not thread-safe.
    func readViewportStyled() -> String? {
        readStyled(GHOSTTY_POINT_VIEWPORT)
    }

    /// The whole screen including scrollback, styled; saved on quit for
    /// scrollback restore.
    func readScreenStyled() -> String? {
        readStyled(GHOSTTY_POINT_SCREEN)
    }

    private func readStyled(_ tag: ghostty_point_tag_e) -> String? {
        guard let surface = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_text_styled(surface, Self.wholeArea(tag), &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    @objc func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        sendText(str)
        (window?.windowController as? MainWindowController)?.broadcastInput(.text(str), from: self)
    }
}
