import Cocoa
import UserNotifications

extension UNUserNotificationCenter {
    /// `UNUserNotificationCenter.current()` resolves a LaunchServices bundle proxy for the
    /// running process and raises `NSInternalInconsistencyException` when there is none —
    /// i.e. whenever this code runs outside a real `.app` bundle. Under `swift test` the
    /// host is Xcode's test tool, so a single terminal bell reaching the notifier aborted
    /// the whole test binary. Every notification path goes through here and treats
    /// "no bundle" as "notifications unavailable" rather than a crash.
    ///
    /// The check is on the bundle URL, not `bundleIdentifier`: the test host reports a
    /// perfectly good identifier (`com.apple.dt.xctest.tool`) while its bundle URL is a
    /// bare `…/Developer/usr/bin/` directory with no `Info.plist`.
    nonisolated(unsafe) static let currentIfBundled: UNUserNotificationCenter? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            booLog(.debug, .app, "Notifications unavailable — not running from an .app bundle")
            return nil
        }
        return .current()
    }()
}

@MainActor
final class ActivityNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ActivityNotifier()

    private var cachedAuthStatus: UNAuthorizationStatus = .notDetermined

    /// False until the first `getNotificationSettings` reply lands. Notifications
    /// posted before then must not be dropped just because the cache still says
    /// `.notDetermined` — see `deliver(_:)`.
    private var hasResolvedAuthStatus = false

    private static var center: UNUserNotificationCenter? { .currentIfBundled }

    private override init() {
        super.init()
        Self.center?.delegate = self
        // Permission can be granted (or revoked) in System Settings while Boo runs.
        // Without this, the launch-time cache is the only value we ever see and
        // notifications stay dead until restart.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        purgeExpired()
    }

    @objc private func appDidBecomeActive() {
        refreshCachedStatus()
    }

    func requestPermission() {
        guard let center = Self.center else { return }
        center.requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            if let error {
                booLog(.warning, .app, "Notification permission error: \(error)")
            }
            booLog(.debug, .app, "Notification permission granted: \(granted)")
            Task { @MainActor [weak self] in self?.refreshCachedStatus() }
        }
    }

    func refreshCachedStatus() {
        guard let center = Self.center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.cachedAuthStatus = status
                self?.hasResolvedAuthStatus = true
            }
        }
    }

    // MARK: - Delivery

    /// Notifications from one workspace that land within `NotificationBurstTracker.window`
    /// of each other, folded into one summary per workspace.
    private var bursts = NotificationBurstTracker()

    /// Pending auto-removals, keyed by notification identifier. A replacement under the
    /// same identifier cancels and reschedules its timer.
    private var expiryTasks: [String: Task<Void, Never>] = [:]

    /// One Notification Center entry per tab: a newer event replaces the older one.
    nonisolated static func tabIdentifier(paneID: UUID, tabIndex: Int) -> String {
        "boo.tab.\(paneID.uuidString).\(tabIndex)"
    }

    /// The burst summary of a workspace.
    nonisolated static func workspaceIdentifier(_ workspaceID: UUID) -> String {
        "boo.ws.\(workspaceID.uuidString)"
    }

    /// Whether a finished command ran long enough to notify. Unknown durations pass:
    /// dropping is worse than one extra notification.
    nonisolated static func meetsMinDuration(_ duration: TimeInterval?, minSeconds: Int) -> Bool {
        guard minSeconds > 0, let duration else { return true }
        return duration >= TimeInterval(minSeconds)
    }

    /// Body of a burst summary: newest first, at most three lines.
    nonisolated static func summaryBody(_ bodies: [String]) -> String {
        let newest = Array(bodies.reversed())
        var lines = Array(newest.prefix(3))
        if newest.count > 3 { lines.append("+\(newest.count - 3) more") }
        return lines.joined(separator: "\n")
    }

    /// Shared delivery path for every notification kind.
    ///
    /// Events tied to a tab replace that tab's previous notification, and with
    /// "group bursts" on, several tabs of one workspace reporting close together collapse
    /// into a single summary. Before the first `getNotificationSettings` reply lands we
    /// deliver anyway: dropping is unrecoverable, whereas an unauthorized `add` merely
    /// fails and is logged.
    private func deliver(
        kind: String, title: String, body: String, sound: UNNotificationSound?,
        workspaceID: UUID?, paneID: UUID?, tabIndex: Int, workspaceName: String? = nil,
        extraInfo: [String: Any] = [:]
    ) {
        guard Self.center != nil else { return }
        guard cachedAuthStatus == .authorized || !hasResolvedAuthStatus else {
            booLog(
                .debug, .app,
                "[Activity] \(kind) notification skipped — not authorized (status=\(cachedAuthStatus.rawValue))")
            return
        }
        guard let workspaceID, let paneID else {
            post(
                identifier: UUID().uuidString, kind: kind, title: title, body: body, sound: sound,
                thread: kind, userInfo: extraInfo)
            return
        }
        let tabID = Self.tabIdentifier(paneID: paneID, tabIndex: tabIndex)
        let target = Self.targetInfo(workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
        let entry = NotificationBurstTracker.Entry(tabKey: tabID, body: body)

        if AppSettings.shared.notificationGroupBursts, let workspaceName,
            let summary = bursts.record(workspaceID: workspaceID, entry: entry, at: Date())
        {
            // The summary stands in for the tabs it folds: their own entries go.
            remove(summary.entries.map(\.tabKey))
            // Within a burst only its first event sounds.
            post(
                identifier: Self.workspaceIdentifier(workspaceID), kind: "summary",
                title: "\(workspaceName) — \(summary.entries.count) tab\(summary.entries.count == 1 ? "" : "s")",
                body: Self.summaryBody(summary.entries.map(\.body)),
                sound: summary.startsBurst ? sound : nil, thread: workspaceID.uuidString,
                userInfo: target.merging(extraInfo) { a, _ in a })
            return
        }
        post(
            identifier: tabID, kind: kind, title: title, body: body, sound: sound,
            thread: workspaceID.uuidString, userInfo: target.merging(extraInfo) { a, _ in a })
    }

    private static func targetInfo(workspaceID: UUID, paneID: UUID, tabIndex: Int) -> [String: Any] {
        ["workspaceID": workspaceID.uuidString, "paneID": paneID.uuidString, "tabIndex": tabIndex]
    }

    private func post(
        identifier: String, kind: String, title: String, body: String, sound: UNNotificationSound?,
        thread: String, userInfo: [String: Any]
    ) {
        guard let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.threadIdentifier = thread
        content.userInfo = userInfo
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(req) { error in
            if let error {
                booLog(.warning, .app, "[Activity] \(kind) notification delivery error: \(error)")
            }
        }
        scheduleExpiry(identifier)
    }

    // MARK: - Removal

    /// The tab is being looked at: its notification, and the workspace summary once no
    /// tab in it is left unseen, are stale.
    func clearDelivered(paneID: UUID, tabIndex: Int) {
        let tabID = Self.tabIdentifier(paneID: paneID, tabIndex: tabIndex)
        var ids = [tabID]
        for workspaceID in bursts.remove(tabKey: tabID) {
            ids.append(Self.workspaceIdentifier(workspaceID))
        }
        remove(ids)
    }

    private func remove(_ ids: [String]) {
        for id in ids { expiryTasks.removeValue(forKey: id)?.cancel() }
        Self.center?.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func scheduleExpiry(_ identifier: String) {
        expiryTasks.removeValue(forKey: identifier)?.cancel()
        let minutes = AppSettings.shared.notificationExpiryMinutes
        guard minutes > 0 else { return }
        expiryTasks[identifier] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.expiryTasks[identifier] = nil
            self.bursts.forget(identifier: identifier)
            Self.center?.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// Drop notifications left over from an earlier run that are past the expiry — their
    /// timers died with that process.
    private func purgeExpired() {
        let minutes = AppSettings.shared.notificationExpiryMinutes
        guard minutes > 0, let center = Self.center else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(minutes) * 60)
        center.getDeliveredNotifications { notifications in
            let stale = notifications.filter { $0.date < cutoff }.map(\.request.identifier)
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.currentIfBundled?.removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center = Self.center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// `duration` nil means unknown (agent idle, no shell integration): never filtered.
    func notifyCommandEnded(
        tabTitle: String, workspaceName: String, exitCode: Int32,
        workspaceID: UUID, paneID: UUID, tabIndex: Int, duration: TimeInterval? = nil
    ) {
        guard AppSettings.shared.activityNotificationsEnabled,
            Self.meetsMinDuration(duration, minSeconds: AppSettings.shared.notifyMinCommandSeconds)
        else { return }
        deliver(
            kind: "command-end", title: workspaceName,
            body: (exitCode == 0 || exitCode == -1) ? "\(tabTitle) — done" : "\(tabTitle) — exit \(exitCode)",
            sound: .default, workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex,
            workspaceName: workspaceName)
    }

    /// An agent finished or waits for an answer (from agent hooks).
    func notifyAgent(
        workspaceName: String, body: String, workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard AppSettings.shared.activityNotificationsEnabled else { return }
        deliver(
            kind: "agent", title: workspaceName, body: body, sound: .default,
            workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex, workspaceName: workspaceName)
    }

    /// A process in a pane started listening on `port`.
    func notifyPort(
        _ port: UInt16, process: String, workspaceName: String,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard AppSettings.shared.portNotificationsEnabled else { return }
        deliver(
            kind: "port", title: workspaceName, body: "\(process) is listening on localhost:\(port)",
            sound: nil, workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex,
            workspaceName: workspaceName)
    }

    /// Post a notification for a terminal bell, analogous to `notifyCommandEnded`.
    /// Suppression mirrors the command-end path: skip when `activityNotificationsEnabled` is off.
    func notifyBell(
        tabTitle: String, workspaceName: String,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard AppSettings.shared.activityNotificationsEnabled else { return }
        deliver(
            kind: "bell", title: workspaceName, body: "\(tabTitle) — bell",
            sound: nil,  // Bell is already an audible event; skip extra sound.
            workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex, workspaceName: workspaceName)
    }

    /// Post an explicit desktop notification (OSC 777 / 99) from the running process.
    /// Suppression: skip when focused AND app is key, otherwise always deliver (regardless of
    /// `activityNotificationsEnabled` — the process explicitly requested it).
    func notifyDesktop(
        title: String, body: String, workspaceName: String,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        deliver(
            kind: "desktop", title: title.isEmpty ? workspaceName : title, body: body,
            sound: .default, workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex,
            workspaceName: workspaceName)
    }

    /// An agent task or today's agent spend passed its budget (once per crossing).
    func notifyBudget(
        title: String, body: String, workspaceID: UUID? = nil, paneID: UUID? = nil, tabIndex: Int = 0
    ) {
        deliver(
            kind: "budget", title: title, body: body, sound: .default,
            workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
    }

    /// An orchestrator card waits while its drawer is out of sight; clicking opens the drawer.
    func notifyOrchestrator(title: String, body: String) {
        guard AppSettings.shared.activityNotificationsEnabled else { return }
        deliver(
            kind: "orchestrator", title: title, body: body, sound: .default,
            workspaceID: nil, paneID: nil, tabIndex: 0, extraInfo: ["orchestrator": true])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if info["orchestrator"] as? Bool == true {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                guard let controller = WindowManager.shared.activeController ?? WindowManager.shared.controllers.first
                else { return }
                controller.window?.makeKeyAndOrderFront(nil)
                OrchestratorController.shared.openDrawer(in: controller)
            }
            completionHandler()
            return
        }
        guard
            let wsStr = info["workspaceID"] as? String,
            let paneStr = info["paneID"] as? String,
            let tabIndex = info["tabIndex"] as? Int,
            let workspaceID = UUID(uuidString: wsStr),
            let paneID = UUID(uuidString: paneStr)
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            guard let controller = WindowManager.shared.controller(owningWorkspace: workspaceID) else { return }
            controller.window?.makeKeyAndOrderFront(nil)
            controller.focusActivity(workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}

/// Folds notifications from one workspace into a summary when several tabs report
/// within `window` seconds of each other. Once a workspace has a summary, later events
/// join it until every tab in it has been looked at.
struct NotificationBurstTracker {
    static let window: TimeInterval = 5

    struct Entry: Equatable {
        let tabKey: String
        let body: String
    }

    struct Summary: Equatable {
        /// Latest event per tab, oldest first.
        let entries: [Entry]
        /// True when the event came after a quiet spell, so the summary may sound again.
        let startsBurst: Bool
    }

    private var bursts: [UUID: (entries: [Entry], lastAt: Date)] = [:]
    /// Tabs each workspace's delivered summary stands for.
    private(set) var summarized: [UUID: [Entry]] = [:]

    /// Record an event. Returns the summary to show, or nil when the event stands alone.
    mutating func record(workspaceID: UUID, entry: Entry, at now: Date) -> Summary? {
        var entries: [Entry] = []
        if let burst = bursts[workspaceID], now.timeIntervalSince(burst.lastAt) < Self.window {
            entries = burst.entries
        }
        let startsBurst = entries.isEmpty
        entries.removeAll { $0.tabKey == entry.tabKey }
        entries.append(entry)
        bursts[workspaceID] = (entries, now)

        guard entries.count > 1 || summarized[workspaceID] != nil else { return nil }
        var summary = summarized[workspaceID] ?? []
        for e in entries {
            summary.removeAll { $0.tabKey == e.tabKey }
            summary.append(e)
        }
        summarized[workspaceID] = summary
        return Summary(entries: summary, startsBurst: startsBurst)
    }

    /// Forget a tab that was looked at. Returns the workspaces whose summary no longer
    /// stands for any unseen tab.
    mutating func remove(tabKey: String) -> [UUID] {
        for (id, burst) in bursts {
            let kept = burst.entries.filter { $0.tabKey != tabKey }
            bursts[id] = kept.isEmpty ? nil : (kept, burst.lastAt)
        }
        var emptied: [UUID] = []
        for (id, entries) in summarized where entries.contains(where: { $0.tabKey == tabKey }) {
            let rest = entries.filter { $0.tabKey != tabKey }
            summarized[id] = rest.isEmpty ? nil : rest
            if rest.isEmpty { emptied.append(id) }
        }
        return emptied
    }

    /// A delivered notification expired: drop what it stood for.
    mutating func forget(identifier: String) {
        if let id = summarized.keys.first(where: { ActivityNotifier.workspaceIdentifier($0) == identifier }) {
            summarized[id] = nil
            bursts[id] = nil
        } else {
            _ = remove(tabKey: identifier)
        }
    }
}
