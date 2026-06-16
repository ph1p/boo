import Cocoa
import UserNotifications

@MainActor
final class ActivityNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ActivityNotifier()

    private var cachedAuthStatus: UNAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            if let error {
                booLog(.warning, .app, "Notification permission error: \(error)")
            }
            booLog(.debug, .app, "Notification permission granted: \(granted)")
            Task { @MainActor [weak self] in self?.refreshCachedStatus() }
        }
    }

    func refreshCachedStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.cachedAuthStatus = status
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func notifyCommandEnded(
        tabTitle: String, workspaceName: String, exitCode: Int32,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard AppSettings.shared.activityNotificationsEnabled else { return }
        guard cachedAuthStatus == .authorized else {
            booLog(
                .debug, .app, "[Activity] notification skipped — not authorized (status=\(cachedAuthStatus.rawValue))")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = workspaceName
        content.body = (exitCode == 0 || exitCode == -1) ? "\(tabTitle) — done" : "\(tabTitle) — exit \(exitCode)"
        content.sound = .default
        content.userInfo = [
            "workspaceID": workspaceID.uuidString,
            "paneID": paneID.uuidString,
            "tabIndex": tabIndex
        ]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                booLog(.warning, .app, "[Activity] notification delivery error: \(error)")
            }
        }
    }

    /// Post a notification for a terminal bell, analogous to `notifyCommandEnded`.
    /// Suppression mirrors the command-end path: skip when `activityNotificationsEnabled` is off.
    func notifyBell(
        tabTitle: String, workspaceName: String,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard AppSettings.shared.activityNotificationsEnabled else { return }
        guard cachedAuthStatus == .authorized else {
            booLog(
                .debug, .app,
                "[Activity] bell notification skipped — not authorized (status=\(cachedAuthStatus.rawValue))")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = workspaceName
        content.body = "\(tabTitle) — bell"
        content.sound = nil  // Bell is already an audible event; skip extra sound.
        content.userInfo = [
            "workspaceID": workspaceID.uuidString,
            "paneID": paneID.uuidString,
            "tabIndex": tabIndex
        ]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                booLog(.warning, .app, "[Activity] bell notification delivery error: \(error)")
            }
        }
    }

    /// Post an explicit desktop notification (OSC 777 / 99) from the running process.
    /// Suppression: skip when focused AND app is key, otherwise always deliver (regardless of
    /// `activityNotificationsEnabled` — the process explicitly requested it).
    func notifyDesktop(
        title: String, body: String, workspaceName: String,
        workspaceID: UUID, paneID: UUID, tabIndex: Int
    ) {
        guard cachedAuthStatus == .authorized else {
            booLog(
                .debug, .app,
                "[Activity] desktop notification skipped — not authorized (status=\(cachedAuthStatus.rawValue))")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? workspaceName : title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "workspaceID": workspaceID.uuidString,
            "paneID": paneID.uuidString,
            "tabIndex": tabIndex
        ]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                booLog(.warning, .app, "[Activity] desktop notification delivery error: \(error)")
            }
        }
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
