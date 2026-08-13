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

    /// Shared delivery path for every notification kind.
    ///
    /// `kind` names the flavour for logs and groups notifications from the same
    /// pane into one thread so a chatty terminal doesn't flood Notification Center.
    /// Before the first `getNotificationSettings` reply lands we deliver anyway:
    /// dropping is unrecoverable, whereas an unauthorized `add` merely fails and
    /// is logged.
    private func deliver(
        kind: String, title: String, body: String, sound: UNNotificationSound?,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard let center = Self.center else { return }
        guard cachedAuthStatus == .authorized || !hasResolvedAuthStatus else {
            booLog(
                .debug, .app,
                "[Activity] \(kind) notification skipped — not authorized (status=\(cachedAuthStatus.rawValue))")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.threadIdentifier = paneID.uuidString
        content.userInfo = [
            "workspaceID": workspaceID.uuidString,
            "paneID": paneID.uuidString,
            "tabIndex": tabIndex
        ]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req) { error in
            if let error {
                booLog(.warning, .app, "[Activity] \(kind) notification delivery error: \(error)")
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center = Self.center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    func notifyCommandEnded(
        tabTitle: String, workspaceName: String, exitCode: Int32,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard AppSettings.shared.activityNotificationsEnabled else { return }
        deliver(
            kind: "command-end", title: workspaceName,
            body: (exitCode == 0 || exitCode == -1) ? "\(tabTitle) — done" : "\(tabTitle) — exit \(exitCode)",
            sound: .default, workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
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
            workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
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
            sound: .default, workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
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
            WindowBridgeModel.shared.windowController?.focusActivity(
                workspaceID: workspaceID, paneID: paneID, tabIndex: tabIndex)
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
