import AppKit
import Foundation

/// Applies `rules.json` to live terminal tabs: picks each tab's profile from
/// its context, fires context rules when a tab enters a matching context, and
/// fires output rules on matching lines.
@MainActor
final class RuleEngine {
    static let shared = RuleEngine()

    /// Programs that ask for secrets or hand the tty to another machine;
    /// `sendText` never types into them.
    static let sendTextBlocklist: Set<String> = ["sudo", "su", "doas", "ssh", "gpg", "passwd", "pinentry"]
    static let defaultCooldown: TimeInterval = 5
    /// More firings than this within `loopWindow` suspend the rule.
    static let loopLimit = 10
    static let loopWindow: TimeInterval = 10
    nonisolated static let runTimeout: TimeInterval = 30
    private static let confirmedKey = "confirmedTriggerRules"

    private final class Entry {
        weak var view: GhosttyView?
        var matcher: OutputRuleMatcher?
        var context = RuleContext.empty
        /// Context rules with actions that matched last time; they fire again
        /// only after the tab leaves and re-enters their context.
        var activeContextRules = Set<String>()
        var lastFire: [String: Date] = [:]
        var lastSentBlock: [String: Int] = [:]
        let settle = Debouncer(delay: 0.3)

        init(view: GhosttyView) { self.view = view }
    }

    private var entries: [UUID: Entry] = [:]
    private var recentFirings: [String: [Date]] = [:]
    private var observers: [Any] = []
    private var started = false
    private let kube = KubeContextReader()

    func start() {
        guard !started else { return }
        started = true
        RulesStore.shared.start()
        ProfileStore.shared.start()
        Pane.onTabContextChanged = { tabID in
            // Called from Pane mutators, which run on the main thread.
            MainActor.assumeIsolated { RuleEngine.shared.contextChanged(tabID) }
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .rulesChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RuleEngine.shared.rulesChanged() }
            })
        observers.append(
            center.addObserver(forName: .profilesChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RuleEngine.shared.reevaluateAll() }
            })
        observers.append(
            center.addObserver(forName: .settingsChanged, object: nil, queue: .main) { note in
                // The default profile lives in the profiles topic.
                guard note.userInfo?["topic"] as? String == SettingsTopic.profiles.rawValue else { return }
                MainActor.assumeIsolated { RuleEngine.shared.reevaluateAll() }
            })
    }

    // MARK: Tabs

    func register(_ view: GhosttyView) {
        guard let tabID = view.tabID else { return }
        if let old = entries[tabID] { detachMatcher(old) }
        let entry = Entry(view: view)
        entries[tabID] = entry
        installMatcher(entry, tabID: tabID)
        evaluate(tabID)
    }

    func unregister(tabID: UUID) {
        guard let entry = entries.removeValue(forKey: tabID) else { return }
        entry.settle.cancel()
        detachMatcher(entry)
    }

    /// The profile a new local tab starting in `cwd` gets, for its shell,
    /// environment and starting directory.
    func launchProfile(cwd: String) -> Profile? {
        let context = RuleContext(
            host: nil, cwd: cwd, container: nil,
            kubeContext: RulesStore.shared.active.usesKubeContext ? kube.current() : nil, process: "")
        let name = RuleMatcher.profile(for: context, in: RulesStore.shared.active) ?? AppSettings.shared.defaultProfile
        return ProfileStore.shared.profile(named: name)
    }

    /// Pins a tab to `name` (nil: back to the rules and the default).
    /// "Auto" plus every profile, checking the one in effect; picking one
    /// pins it to the tab until "Auto".
    func profileMenu(tabID: UUID) -> NSMenu {
        let menu = NSMenu()
        let state = AgentInbox.locateInWindows(tabID).map { $0.pane.tabs[$0.tabIndex].state }
        let auto = ClosureMenuItem(title: "Auto") { [weak self] in self?.setProfileOverride(nil, tabID: tabID) }
        auto.state = state?.profileOverride == nil ? .on : .off
        if state?.profileOverride == nil, let current = state?.profile {
            auto.title = "Auto (\(current))"
        }
        menu.addItem(auto)
        let names = ProfileStore.shared.names
        if !names.isEmpty { menu.addItem(.separator()) }
        for name in names {
            let item = ClosureMenuItem(title: name) { [weak self] in self?.setProfileOverride(name, tabID: tabID) }
            item.state = state?.profileOverride == name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(title: "Edit Profiles…") {
                SettingsWindowController.shared.showSettings(tab: .profiles)
            })
        return menu
    }

    func setProfileOverride(_ name: String?, tabID: UUID) {
        guard let loc = AgentInbox.locateInWindows(tabID) else { return }
        let state = loc.pane.tabs[loc.tabIndex].state
        loc.pane.setProfile(at: loc.tabIndex, override: name, effective: state.profile)
        evaluate(tabID)
    }

    private func contextChanged(_ tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        // A cd or a process start comes in bursts; settle first.
        entry.settle.schedule { [weak self] in self?.evaluate(tabID) }
    }

    private func rulesChanged() {
        for (tabID, entry) in entries {
            installMatcher(entry, tabID: tabID)
        }
        reevaluateAll()
    }

    private func reevaluateAll() {
        for tabID in entries.keys { evaluate(tabID) }
    }

    private func evaluate(_ tabID: UUID) {
        guard let entry = entries[tabID], let view = entry.view else {
            entries[tabID] = nil
            return
        }
        guard let loc = AgentInbox.locateInWindows(tabID) else { return }
        let rules = RulesStore.shared.active
        let tab = loc.pane.tabs[loc.tabIndex]
        let context = Self.context(of: tab, kube: rules.usesKubeContext ? kube.current() : nil)
        entry.context = context
        entry.matcher?.update(context: context)

        // Profile: the tab's own pick, else the first matching rule, else the default.
        let override = tab.state.profileOverride
        let candidate = override ?? RuleMatcher.profile(for: context, in: rules) ?? AppSettings.shared.defaultProfile
        let profile = ProfileStore.shared.profile(named: candidate)
        if loc.pane.setProfile(at: loc.tabIndex, override: override, effective: profile?.name) {
            loc.controller.refreshTabBar(workspace: loc.workspace, pane: loc.pane)
        }
        if let surface = view.surface {
            GhosttyRuntime.shared.setProfile(profile, for: surface)
        }

        // Context rules fire on entering their context.
        let matching = RuleMatcher.matchingActionRules(for: context, in: rules)
        let ids = Set(matching.map(\.id))
        let entered = matching.filter { !entry.activeContextRules.contains($0.id) }
        entry.activeContextRules = ids
        for rule in entered {
            fire(rule, captures: [], line: nil, tabID: tabID)
        }
    }

    static func context(of tab: Pane.Tab, kube: String?) -> RuleContext {
        var host: String?
        var alias: String?
        var container: String?
        switch tab.remoteSession {
        case .ssh(let h, let a):
            host = h
            alias = a
        case .mosh(let h):
            host = h
        case .container(let target, _):
            container = target
        case nil:
            break
        }
        let cwd = tab.remoteSession != nil ? (tab.remoteWorkingDirectory ?? "") : tab.workingDirectory
        return RuleContext(
            host: host, hostAlias: alias, cwd: cwd, container: container, kubeContext: kube,
            process: tab.state.foregroundProcess)
    }

    // MARK: Output rules

    private func installMatcher(_ entry: Entry, tabID: UUID) {
        let rules = RulesStore.shared.active.outputRules
        guard let view = entry.view else { return }
        if rules.isEmpty {
            detachMatcher(entry)
        } else if let matcher = entry.matcher {
            matcher.update(rules: rules)
        } else {
            let matcher = OutputRuleMatcher(rules: rules, context: entry.context) { match in
                RuleEngine.shared.outputMatched(match, tabID: tabID)
            }
            entry.matcher = matcher
            view.outputTap.add(matcher, snapshot: false, surface: view.surface)
        }
    }

    private func detachMatcher(_ entry: Entry) {
        guard let matcher = entry.matcher else { return }
        entry.view?.outputTap.remove(matcher, surface: entry.view?.surface)
        entry.matcher = nil
    }

    private func outputMatched(_ match: OutputMatch, tabID: UUID) {
        guard let entry = entries[tabID],
            let rule = RulesStore.shared.active.outputRules.first(where: { $0.id == match.ruleID })
        else { return }
        let cooldown = rule.cooldown ?? Self.defaultCooldown
        if let last = entry.lastFire[rule.id], Date().timeIntervalSince(last) < cooldown { return }
        entry.lastFire[rule.id] = Date()
        fire(rule, captures: match.captures, line: match.line, tabID: tabID)
    }

    // MARK: Firing

    private func fire(_ rule: Rule, captures: [String], line: String?, tabID: UUID) {
        guard case .actions(let actions) = rule.then else { return }
        guard !loopGuardTripped(rule) else { return }
        booLog(.info, .app, "[Rules] \(rule.id) fired")
        for action in actions {
            perform(action, rule: rule, captures: captures, line: line, tabID: tabID)
        }
    }

    /// Records a firing; suspends the rule when it fires too often (e.g. its
    /// own `sendText` output matches it again).
    private func loopGuardTripped(_ rule: Rule) -> Bool {
        let now = Date()
        var times = (recentFirings[rule.id] ?? []).filter { now.timeIntervalSince($0) < Self.loopWindow }
        times.append(now)
        recentFirings[rule.id] = times
        guard times.count > Self.loopLimit else { return false }
        recentFirings[rule.id] = nil
        RulesStore.shared.suspend(rule.id)
        booLog(.warning, .app, "[Rules] \(rule.id) suspended: fired \(times.count) times in \(Int(Self.loopWindow))s")
        let id = rule.id
        BooAlert.showTransient(
            "Rule “\(id)” fired too often and was paused",
            actions: [BooAlert.ToastAction(title: "Resume") { RulesStore.shared.resume(id) }])
        return true
    }

    private func perform(_ action: TriggerAction, rule: Rule, captures: [String], line: String?, tabID: UUID) {
        guard let loc = AgentInbox.locateInWindows(tabID) else { return }
        let expand = { (s: String) in CaptureTemplate.expand(s, captures: captures) }
        switch action {
        case .notify(let title, let body):
            let title = title.map(expand) ?? rule.id
            let body = body.map(expand) ?? line ?? ""
            ActivityNotifier.shared.notifyDesktop(
                title: title, body: body, workspaceName: loc.workspace.displayName,
                workspaceID: loc.workspace.id, paneID: loc.pane.id, tabIndex: loc.tabIndex)
            // The phone only learns which rule fired, never terminal content.
            PhonePusher.shared.triggerFired(ruleID: rule.id, workspaceName: loc.workspace.displayName)

        case .markTab:
            loc.controller.markTabFromTrigger(
                ruleID: rule.id, workspace: loc.workspace, pane: loc.pane, tabIndex: loc.tabIndex)

        case .run(let command):
            Self.run(command, rule: rule, captures: captures, tabID: tabID, cwd: entries[tabID]?.context.cwd)

        case .sendText(let template):
            sendText(expand(template), rule: rule, tabID: tabID)

        case .openLink(let template):
            let text = expand(template)
            let tab = loc.pane.tabs[loc.tabIndex]
            let origin = LinkOpener.Origin(
                cwd: entries[tabID]?.context.cwd, remote: tab.remoteSession, controller: loc.controller)
            if let link = LinkResolver.links(in: text).first {
                LinkOpener.open(link.kind, from: origin)
            } else {
                booLog(.warning, .app, "[Rules] \(rule.id): no link in \"\(text)\"")
            }
        }
    }

    private func sendText(_ text: String, rule: Rule, tabID: UUID) {
        guard let entry = entries[tabID], let view = entry.view else { return }
        // Once per command: a prompt that repeats inside one command is answered once.
        let block = CommandLog.shared.block(of: tabID)
        if rule.isOutputRule, entry.lastSentBlock[rule.id] == block { return }
        let process = (entry.context.process as NSString).lastPathComponent
        if Self.sendTextBlocklist.contains(process) {
            booLog(.info, .app, "[Rules] \(rule.id): not typing into \(process)")
            return
        }
        if view.isEchoOff {
            booLog(.info, .app, "[Rules] \(rule.id): not typing at a hidden-input prompt")
            return
        }
        let send = { [weak self, weak view] in
            guard let self, let view else { return }
            self.entries[tabID]?.lastSentBlock[rule.id] = CommandLog.shared.block(of: tabID)
            view.typeText(text)
        }
        if Self.isConfirmed(rule) {
            send()
            return
        }
        // First use of this rule (as written): ask before typing anything.
        let fingerprint = rule.fingerprint
        BooAlert.showTransient(
            "Rule “\(rule.id)” wants to type into this terminal",
            actions: [
                BooAlert.ToastAction(title: "Allow") {
                    Self.confirm(fingerprint)
                    MainActor.assumeIsolated { send() }
                }
            ])
    }

    static func isConfirmed(_ rule: Rule) -> Bool {
        (UserDefaults.standard.stringArray(forKey: confirmedKey) ?? []).contains(rule.fingerprint)
    }

    /// Forgets every approved `sendText` rule; each asks again on its next firing.
    static func resetConfirmations() {
        UserDefaults.standard.removeObject(forKey: confirmedKey)
    }

    private static func confirm(_ fingerprint: String) {
        var list = UserDefaults.standard.stringArray(forKey: confirmedKey) ?? []
        guard !list.contains(fingerprint) else { return }
        list.append(fingerprint)
        UserDefaults.standard.set(list, forKey: confirmedKey)
    }

    /// Runs a `run` action's command with `/bin/sh -c`, as written: captures
    /// reach it only through `BOO_MATCH_0`…`BOO_MATCH_9`, never spliced into
    /// the command line.
    private static func run(_ command: String, rule: Rule, captures: [String], tabID: UUID, cwd: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        for i in 0...9 {
            env["BOO_MATCH_\(i)"] = i < captures.count ? captures[i] : ""
        }
        env["BOO_RULE_ID"] = rule.id
        env["BOO_TAB_ID"] = tabID.uuidString
        process.environment = env
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let ruleID = rule.id
        DispatchQueue.global(qos: .utility).async {
            do {
                try process.run()
            } catch {
                booLog(.warning, .app, "[Rules] \(ruleID): run failed: \(error.localizedDescription)")
                return
            }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + runTimeout, execute: timer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let text = String(decoding: data.prefix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let level: BooLogger.Level = process.terminationStatus == 0 ? .info : .warning
            booLog(
                level, .app,
                "[Rules] \(ruleID): run exited \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text)")")
        }
    }
}

/// Reads the current kubectl context from `$KUBECONFIG` (first file) or
/// `~/.kube/config`, re-reading only when the file changes.
final class KubeContextReader {
    private var cachedPath: String?
    private var cachedMTime: Date?
    private var cachedValue: String?

    func current() -> String? {
        guard let path = KubeStore.kubeconfigPaths().first else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if path == cachedPath, mtime == cachedMTime { return cachedValue }
        cachedPath = path
        cachedMTime = mtime
        cachedValue = mtime == nil ? nil : (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(Self.parse)
        return cachedValue
    }

    /// The top-level `current-context:` value of a kubeconfig.
    static func parse(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("current-context:") else { continue }
            var value = line.dropFirst("current-context:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
