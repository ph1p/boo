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
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: body) + 1))
        return "\(header)\n\(fence)\n\(body)\n\(fence)\n"
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
        let text: String
        let tabID: UUID
        init(text: String, tabID: UUID) {
            self.text = text
            self.tabID = tabID
        }
    }

    @objc func send(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload else { return }
        if !AgentHandoff.send(payload.text, to: payload.tabID) { NSSound.beep() }
    }

    /// "Send … to Agent" items for a terminal's context menu: one per kind of
    /// context available, each with a submenu of agents when there are several.
    func menuItems(for view: GhosttyView) -> [NSMenuItem] {
        let targets = AgentHandoff.targets(excluding: view.tabID)
        guard !targets.isEmpty else { return [] }
        let cwd = view.tabID.flatMap(AgentHandoff.workingDirectory(ofTab:))
        var contexts: [(title: String, text: String)] = []
        if let selection = view.readSelectionText(), !selection.isEmpty {
            contexts.append(("Send Selection", AgentHandoff.compose(selection, source: .selection, cwd: cwd)))
        }
        if let (source, output) = view.lastCommandOutput(), !output.isEmpty,
            case .output(let command, _) = source
        {
            let short = command.count > 30 ? String(command.prefix(29)) + "…" : command
            contexts.append(("Send Output of “\(short)”", AgentHandoff.compose(output, source: source, cwd: cwd)))
        }
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
        }
    }

    private func item(_ title: String, _ text: String, _ tabID: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(send(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Payload(text: text, tabID: tabID)
        return item
    }
}
