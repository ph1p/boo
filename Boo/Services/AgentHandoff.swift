import AppKit

/// Handing terminal context to a coding agent: a selection, the output of the
/// last command (an error, a failing test run) or dropped text is pasted into
/// the agent's prompt as a fenced block, without pressing Return, and the
/// agent's tab comes to the front so the user can add what to do with it.
enum AgentHandoff {
    enum Source: Equatable {
        case selection
        case output(command: String, exitCode: Int32?)
    }

    /// Longest text handed over; longer output keeps its end, where errors are.
    static let maxCharacters = 60_000

    // MARK: - Targets

    /// Agents that can receive context from `sourceTab`: those in the source's
    /// workspace first, then the most recently active.
    @MainActor static func targets(excluding sourceTab: UUID?, inbox: AgentInbox = .shared) -> [AgentInbox.Item] {
        let sourceWorkspace = sourceTab.flatMap { inbox.locate($0)?.workspace.id }
        return inbox.items.values
            .filter { $0.tabID != sourceTab }
            .compactMap { item in inbox.locate(item.tabID).map { (item, $0.workspace.id == sourceWorkspace) } }
            .sorted { a, b in a.1 != b.1 ? a.1 : a.0.updatedAt > b.0.updatedAt }
            .map(\.0)
    }

    /// "Claude — boo" or "Claude — api (monorepo)": agent, folder and workspace.
    @MainActor static func label(for item: AgentInbox.Item, inbox: AgentInbox = .shared) -> String {
        let agent = AgentInbox.displayName(of: item.agent)
        guard let location = inbox.locate(item.tabID) else { return agent }
        let folder = item.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        let workspace = location.workspace.displayName
        return folder.isEmpty || folder == workspace ? "\(agent) — \(workspace)" : "\(agent) — \(folder) (\(workspace))"
    }

    /// The tab's working directory, named in the handed-over context.
    @MainActor static func workingDirectory(ofTab tabID: UUID) -> String? {
        guard let location = AgentInbox.locateInWindows(tabID) else { return nil }
        let directory = location.pane.tabs[location.tabIndex].workingDirectory
        return directory.isEmpty ? nil : directory
    }

    // MARK: - Sending

    /// Pastes `text` into the agent's prompt and brings its tab to the front.
    @MainActor @discardableResult
    static func send(_ text: String, to tabID: UUID, inbox: AgentInbox = .shared) -> Bool {
        guard inbox.jump(to: tabID), let location = inbox.locate(tabID),
            let view = location.controller.terminalView(workspace: location.workspace, paneID: location.pane.id)
        else { return false }
        view.paste(text, submit: false)
        return true
    }

    /// Starts Claude Code in a split next to `sourceTab` with `text` as its
    /// first message. The text goes through a temp file: it can be tens of
    /// kilobytes, too long to type into the shell.
    @MainActor @discardableResult
    static func startAgent(with text: String, nextTo sourceTab: UUID) -> Bool {
        guard let location = AgentInbox.locateInWindows(sourceTab) else { return false }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boo-agent-\(UUID().uuidString).md")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            booLog(.error, .app, "[AgentHandoff] can't write prompt: \(error)")
            return false
        }
        let path = MainWindowController.shellQuoted(file.path)
        let command = "claude \"$(cat \(path); rm -f \(path))\""
        let tab = location.pane.tabs[location.tabIndex]
        // A remote tab's folder doesn't exist here; the split starts in the default.
        let cwd = tab.remoteSession == nil ? workingDirectory(ofTab: sourceTab) : nil
        return location.controller.splitPane(
            location.pane.id, in: location.workspace, toward: .right, cwd: cwd, launch: LaunchSpec(command: command))
            != nil
    }

    /// First message for an agent started from a failed command.
    static func fixRequest(_ composed: String) -> String {
        "This command failed. Find out why and fix it.\n\n" + composed
    }

    /// Only the failed tests of a test run: name, location and message each,
    /// instead of the whole log.
    static func compose(failures report: TestFailureReport, command: String, exitCode: Int32?, cwd: String?) -> String {
        let firstLine = command.components(separatedBy: "\n").first ?? command
        let status = exitCode.map { $0 == 0 ? "" : " (exit code \($0))" } ?? ""
        let place = cwd.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        let list = report.failures.map { failure in
            var entry = "- \(failure.name)"
            if let location = failure.location { entry += " at \(location)" }
            if !failure.message.isEmpty {
                entry += "\n" + failure.message.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
            }
            return entry
        }.joined(separator: "\n")
        let body = list.count > maxCharacters ? String(list.prefix(maxCharacters)) : list
        return "\(report.summary) (\(report.framework)) in `\(firstLine)`\(status)\(place):\n\(fenced(body))"
    }

    // MARK: - Composing

    /// The block pasted into the agent: a one-line header and the text fenced.
    static func compose(_ text: String, source: Source, cwd: String?) -> String {
        var body = text
        var truncated = false
        if body.count > maxCharacters {
            body = String(body.suffix(maxCharacters))
            if let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
            truncated = true
        }
        let place = cwd.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        var header: String
        switch source {
        case .selection:
            header = "From my terminal\(place):"
        case .output(let command, let exitCode):
            let firstLine = command.components(separatedBy: "\n").first ?? command
            let status = exitCode.map { $0 == 0 ? "" : " (exit code \($0))" } ?? " (still running)"
            header = "Output of `\(firstLine)`\(status)\(place):"
        }
        if truncated { header += " (end only, it was longer)" }
        return "\(header)\n\(fenced(body))"
    }

    /// `text` in a markdown code block whose fence is longer than any backtick
    /// run inside, so pasted terminal text can't close it early.
    static func fenced(_ text: String) -> String {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        return "\(fence)\n\(text)\n\(fence)\n"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    // MARK: - Last command output

    /// The output of `command` at the end of `screen` (terminal text, scrollback
    /// included). Finds the last line where the command was typed and takes
    /// what follows, minus the prompt drawn after it. Prompt lines are found by
    /// matching the lines above the command line against the screen's last
    /// lines, so multi-line prompts work. `finished` false: the command still
    /// runs, so there is no prompt after it.
    static func output(of command: String, in screen: String, finished: Bool = true) -> String? {
        let commandLines = command.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = commandLines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else {
            return nil
        }
        var lines = screen.components(separatedBy: "\n").map { trimTrailing($0) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let end = finished ? lines.count - 1 : lines.count
        guard end > 0 else { return nil }

        let searchable = lines[..<end].indices.reversed()
        guard
            let commandLine = searchable.first(where: { lines[$0].hasSuffix(first) })
                ?? searchable.first(where: { lines[$0].contains(first) })
        else { return nil }
        let outputStart = commandLine + commandLines.count
        var outputEnd = end
        if finished {
            // Prompt lines above the current prompt's last line repeat the ones
            // above the command line (blank separator, path, git branch...).
            var offset = 1
            while commandLine - offset >= 0, end - offset >= outputStart,
                lines[commandLine - offset] == lines[end - offset]
            {
                offset += 1
            }
            outputEnd = end - (offset - 1)
        }
        guard outputStart < outputEnd else { return "" }
        var output = Array(lines[outputStart..<outputEnd])
        while output.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeFirst() }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private static func trimTrailing(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last == " " || last == "\t" || last == "\r" { line.removeLast() }
        return String(line)
    }
}

/// Target of "Send to Agent" menu items; `representedObject` is a `Payload`.
@MainActor final class AgentHandoffMenuTarget: NSObject {
    static let shared = AgentHandoffMenuTarget()

    final class Payload: NSObject {
        /// Built on click: reading the last output scans up to 5000 lines of
        /// scrollback, too slow to do for every right-click.
        let text: @MainActor () -> String?
        let tabID: UUID
        init(text: @escaping @MainActor () -> String?, tabID: UUID) {
            self.text = text
            self.tabID = tabID
        }
    }

    @objc func send(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload else { return }
        guard let text = payload.text(), AgentHandoff.send(text, to: payload.tabID) else {
            NSSound.beep()
            return
        }
    }

    /// "Send … to Agent" items for a terminal's context menu: one per kind of
    /// context available, each with a submenu of agents when there are several.
    /// - Parameter block: prompt index of the right-clicked command block;
    ///   its output is offered instead of the last command's.
    func menuItems(for view: GhosttyView, block: Int? = nil) -> [NSMenuItem] {
        let targets = AgentHandoff.targets(excluding: view.tabID)
        guard !targets.isEmpty else {
            if let block, let start = startAgentItem(for: view, block: block) { return [start] }
            return []
        }
        let cwd = view.tabID.flatMap(AgentHandoff.workingDirectory(ofTab:))
        var contexts: [(title: String, text: @MainActor () -> String?)] = []
        if let selection = view.readSelectionText(), !selection.isEmpty {
            let text = AgentHandoff.compose(selection, source: .selection, cwd: cwd)
            contexts.append(("Send Selection", { text }))
        }
        // Offered whenever a command ran; its output is read only if picked.
        if let block, let command = view.blockCommand(at: block) {
            contexts.append(
                ("Send Output of “\(Self.short(command))”", blockText(view, block: block, command: command)))
        } else if let command = view.lastCommand?.command {
            contexts.append(
                (
                    "Send Output of “\(Self.short(command))”",
                    { [weak view] in
                        guard let (source, output) = view?.lastCommandOutput(), !output.isEmpty else { return nil }
                        return AgentHandoff.compose(output, source: source, cwd: cwd)
                    }
                ))
        }
        let start = block.flatMap { startAgentItem(for: view, block: $0) }
        return contexts.map { context in
            if targets.count == 1, let target = targets.first {
                return item("\(context.title) to \(AgentHandoff.label(for: target))", context.text, target.tabID)
            }
            let parent = NSMenuItem(title: "\(context.title) to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for target in targets {
                submenu.addItem(item(AgentHandoff.label(for: target), context.text, target.tabID))
            }
            parent.submenu = submenu
            return parent
        } + (start.map { [$0] } ?? [])
    }

    /// The menu of a failed block's hover button: each agent, then a new one.
    /// With parsed test failures the menu lists them (click opens the
    /// location) and sends only the failures; the full output moves into a
    /// submenu.
    func failedBlockMenu(for view: GhosttyView, block: Int, failures: TestFailureReport? = nil) -> NSMenu? {
        guard let tabID = view.tabID, let command = view.blockCommand(at: block) else { return nil }
        let menu = NSMenu()
        let output = blockText(view, block: block, command: command)
        guard let failures else {
            addSendItems(to: menu, title: "Send “\(Self.short(command))” to", text: output, tabID: tabID)
            if let start = startAgentItem(for: view, block: block, text: output) { menu.addItem(start) }
            return menu
        }

        menu.addItem(Self.header("\(failures.summary) · \(failures.framework)"))
        for failure in failures.failures.prefix(Self.maxFailureItems) {
            menu.addItem(failureItem(failure, view: view))
        }
        if failures.failures.count > Self.maxFailureItems {
            menu.addItem(Self.header("\(failures.failures.count - Self.maxFailureItems) more"))
        }
        menu.addItem(.separator())

        let cwd = AgentHandoff.workingDirectory(ofTab: tabID)
        let exitCode = view.exitCode(ofBlock: block, command: command)
        let text: @MainActor () -> String? = {
            AgentHandoff.compose(failures: failures, command: command, exitCode: exitCode, cwd: cwd)
        }
        addSendItems(to: menu, title: "Send failures to", text: text, tabID: tabID)
        if let start = startAgentItem(for: view, block: block, text: text) { menu.addItem(start) }

        let full = NSMenu()
        addSendItems(to: full, title: "Send full output to", text: output, tabID: tabID)
        if let start = startAgentItem(for: view, block: block, text: output) { full.addItem(start) }
        let fullItem = NSMenuItem(title: "Full Output", action: nil, keyEquivalent: "")
        fullItem.submenu = full
        menu.addItem(.separator())
        menu.addItem(fullItem)
        return menu
    }

    static let maxFailureItems = 20

    private func addSendItems(to menu: NSMenu, title: String, text: @escaping @MainActor () -> String?, tabID: UUID) {
        menu.addItem(Self.header(title))
        let before = menu.items.count
        for target in AgentHandoff.targets(excluding: tabID) {
            menu.addItem(item(AgentHandoff.label(for: target), text, target.tabID))
        }
        if menu.items.count > before { menu.addItem(.separator()) }
    }

    private static func header(_ title: String) -> NSMenuItem {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        return header
    }

    final class FailurePayload: NSObject {
        let failure: TestFailure
        weak var view: GhosttyView?
        init(failure: TestFailure, view: GhosttyView) {
            self.failure = failure
            self.view = view
        }
    }

    private func failureItem(_ failure: TestFailure, view: GhosttyView) -> NSMenuItem {
        let place = failure.file.map { file in
            let name = (file as NSString).lastPathComponent
            return " — " + (failure.line.map { "\(name):\($0)" } ?? name)
        }
        let item = NSMenuItem(
            title: failure.name + (place ?? ""), action: failure.file == nil ? nil : #selector(openFailure(_:)),
            keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        item.toolTip = failure.message.isEmpty ? nil : failure.message
        item.representedObject = FailurePayload(failure: failure, view: view)
        return item
    }

    @objc private func openFailure(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? FailurePayload, let file = payload.failure.file,
            let view = payload.view
        else { return }
        view.openLink(.file(path: file, line: payload.failure.line, column: nil))
    }

    /// "Fix with New Agent": only for failed blocks.
    private func startAgentItem(
        for view: GhosttyView, block: Int, text: (@MainActor () -> String?)? = nil
    ) -> NSMenuItem? {
        guard let tabID = view.tabID, let command = view.blockCommand(at: block),
            let code = view.exitCode(ofBlock: block, command: command), code != 0
        else { return nil }
        let item = NSMenuItem(title: "Fix with New Claude Code Agent", action: #selector(start(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Payload(text: text ?? blockText(view, block: block, command: command), tabID: tabID)
        return item
    }

    @objc private func start(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload, let text = payload.text(),
            AgentHandoff.startAgent(with: AgentHandoff.fixRequest(text), nextTo: payload.tabID)
        else {
            NSSound.beep()
            return
        }
    }

    /// The block's output composed for an agent, read when picked.
    private func blockText(_ view: GhosttyView, block: Int, command: String) -> @MainActor () -> String? {
        let cwd = view.tabID.flatMap(AgentHandoff.workingDirectory(ofTab:))
        return { [weak view] in
            guard let view, let output = view.readCommand(index: block, part: .output) else { return nil }
            let source = AgentHandoff.Source.output(
                command: command, exitCode: view.exitCode(ofBlock: block, command: command))
            return AgentHandoff.compose(output, source: source, cwd: cwd)
        }
    }

    static func short(_ command: String) -> String {
        command.count > 30 ? String(command.prefix(29)) + "…" : command
    }

    private func item(_ title: String, _ text: @escaping @MainActor () -> String?, _ tabID: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(send(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Payload(text: text, tabID: tabID)
        return item
    }
}
