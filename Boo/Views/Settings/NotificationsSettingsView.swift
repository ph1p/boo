import Cocoa
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @State private var activityNotificationsEnabled = AppSettings.shared.activityNotificationsEnabled
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .notifications])

    var body: some View {
        let _ = observer.revision

        SettingsPage(title: "Notifications") {
            Section(title: "Activity") {
                ToggleRow(
                    label: "Command notifications",
                    help: "Show a system notification when a command finishes in a background tab or workspace.",
                    isOn: Binding(
                        get: { activityNotificationsEnabled },
                        set: {
                            activityNotificationsEnabled = $0
                            AppSettings.shared.activityNotificationsEnabled = $0
                            if $0 { ActivityNotifier.shared.requestPermission() }
                        }
                    )
                )

                if activityNotificationsEnabled {
                    permissionRow
                }
            }
        }
        .task { await refreshAuthStatus() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await refreshAuthStatus() }
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        let t = Tokens.current
        switch authStatus {
        case .authorized:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Notifications are allowed in System Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
        case .denied:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boo is not allowed to send notifications.")
                        .font(.system(size: 11))
                        .foregroundStyle(t.muted)
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        case .notDetermined:
            Button("Grant Permission…") {
                ActivityNotifier.shared.requestPermission()
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await refreshAuthStatus()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func refreshAuthStatus() async {
        authStatus = await ActivityNotifier.shared.authorizationStatus()
    }
}
