import Cocoa

extension Notification.Name {
    /// A key table mode started, changed table or ended.
    static let keyTableChanged = Notification.Name("BooKeyTableChanged")
}

/// Leader-key mode from `~/.boo/keytables.json`. Off while the file is
/// missing; re-read when Boo becomes active after the file changed.
@MainActor
final class KeyTables {
    static let shared = KeyTables(path: BooPaths.keyTablesFile)

    let path: String
    private(set) var machine: KeyTableMachine?
    private var loadedDate: Date?
    private var reportedProblems: [String] = []
    private var timer: Timer?
    private var activeObserver: Any?
    /// Keys whose press the mode took; their release must not reach Ghostty.
    private var swallowedKeyCodes = Set<UInt16>()

    init(path: String) {
        self.path = path
    }

    func start() {
        reloadIfChanged()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    var isActive: Bool { machine?.isActive == true }

    /// "⌃A …" in the root table, "⌃A → window" in another; nil when off.
    var indicator: String? {
        guard let machine, let table = machine.table else { return nil }
        let leader = machine.config.leader.display
        return table == KeyTableConfig.rootTable ? "\(leader) …" : "\(leader) → \(table)"
    }

    func reloadIfChanged() {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard date != loadedDate else { return }
        loadedDate = date
        reload(knownActionIDs: Set(ActionRegistry.actions().map(\.id)))
    }

    /// Loads the file and reports what is wrong with it once per distinct set
    /// of problems, so re-activating Boo doesn't nag.
    func reload(knownActionIDs: Set<String>, report: Bool = true) {
        end()
        guard let data = FileManager.default.contents(atPath: path) else {
            machine = nil
            reportedProblems = []
            return
        }
        var problems: [String]
        do {
            let parsed = try KeyTableConfig.parse(data)
            machine = KeyTableMachine(config: parsed.config)
            problems = parsed.problems + parsed.config.problems(knownActionIDs: knownActionIDs)
        } catch {
            machine = nil
            problems = ["the file is not a JSON object"]
        }
        guard report, !problems.isEmpty, problems != reportedProblems else { return }
        reportedProblems = problems
        BooAlert.showError(
            title: "Key Tables Have Problems",
            message: "\(abbreviatePath(path)):\n" + problems.map { "• \($0)" }.joined(separator: "\n"))
    }

    /// Feeds a key typed into `view`. True when the key was taken.
    func intercept(_ event: NSEvent, in view: GhosttyView) -> Bool {
        guard var current = machine else { return false }
        let before = current.table
        let outcome = current.handle(KeyChord(event: event))
        machine = current
        // Typing with the mode off is the common case: no timer, no redraw.
        if before != nil || current.table != nil { changed() }
        if outcome != .passThrough { swallowedKeyCodes.insert(event.keyCode) }
        switch outcome {
        case .passThrough:
            return false
        case .consumed:
            return true
        case .run(.action(let id)):
            if ActionRegistry.action(id: id)?.perform() != true { NSSound.beep() }
            return true
        case .run(.send(let text)):
            view.typeText(text)
            return true
        case .run(.table):
            return true
        }
    }

    /// True (once) for the release of a key the mode took.
    func swallowsRelease(_ event: NSEvent) -> Bool {
        swallowedKeyCodes.remove(event.keyCode) != nil
    }

    /// Ends the mode, as ⎋ or the timeout does.
    func end() {
        guard machine?.isActive == true else { return }
        machine?.reset()
        changed()
    }

    private func changed() {
        timer?.invalidate()
        timer = nil
        if let machine, machine.isActive {
            timer = Timer.scheduledTimer(withTimeInterval: machine.config.timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }
        NotificationCenter.default.post(name: .keyTableChanged, object: self)
    }
}

/// The leader key's mode in the status bar while it waits for a key.
final class KeyTableSegment: StatusBarPlugin {
    let id = "key-table"
    let position: StatusBarPosition = .left
    let priority = 0
    var tooltipText: String? { "Waiting for a key from ~/.boo/keytables.json — ⎋ cancels" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        MainActor.assumeIsolated { KeyTables.shared.indicator != nil }
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        guard let indicator = MainActor.assumeIsolated({ KeyTables.shared.indicator }) else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: theme.accentColor
        ]
        let str = indicator as NSString
        str.safeDraw(at: NSPoint(x: x + 4, y: y), withAttributes: attrs)
        return str.safeSize(withAttributes: attrs).width + 8
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        MainActor.assumeIsolated { KeyTables.shared.indicator }.map { "Key table: \($0)" }
    }
}
