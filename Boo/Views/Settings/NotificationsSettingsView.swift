import Cocoa
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @Environment(\.tokens) private var tokens
    @State private var activityNotificationsEnabled = AppSettings.shared.activityNotificationsEnabled
    @State private var portNotificationsEnabled = AppSettings.shared.portNotificationsEnabled
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var minCommandSeconds = AppSettings.shared.notifyMinCommandSeconds
    @State private var groupBursts = AppSettings.shared.notificationGroupBursts
    @State private var expiryMinutes = AppSettings.shared.notificationExpiryMinutes

    private static let minCommandChoices = [0, 5, 10, 30, 60]
    private static let expiryChoices = [0, 5, 15, 60]
    @ObservedObject private var observer = SettingsObserver(topics: [.notifications])

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

                ToggleRow(
                    label: "New port notifications",
                    help:
                        "Notify when a process in the active workspace starts listening on a port. Needs the Listening ports status bar segment.",
                    isOn: Binding(
                        get: { portNotificationsEnabled },
                        set: {
                            portNotificationsEnabled = $0
                            AppSettings.shared.portNotificationsEnabled = $0
                            if $0 { ActivityNotifier.shared.requestPermission() }
                        }
                    )
                )

                if activityNotificationsEnabled {
                    SettingRow(
                        label: "Minimum command duration",
                        help: "Only commands that ran at least this long notify. Shorter ones still mark the tab."
                    ) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { minCommandSeconds },
                                set: {
                                    minCommandSeconds = $0
                                    AppSettings.shared.notifyMinCommandSeconds = $0
                                }
                            )
                        ) {
                            ForEach(Self.minCommandChoices, id: \.self) { seconds in
                                Text(seconds == 0 ? "Any" : "\(seconds) seconds").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                if activityNotificationsEnabled || portNotificationsEnabled {
                    ToggleRow(
                        label: "Group bursts",
                        help:
                            "When several tabs in one workspace report within a few seconds, show one summary instead of one notification each. Each tab keeps at most one notification either way.",
                        isOn: Binding(
                            get: { groupBursts },
                            set: {
                                groupBursts = $0
                                AppSettings.shared.notificationGroupBursts = $0
                            }
                        )
                    )

                    SettingRow(
                        label: "Remove after",
                        help:
                            "Clear notifications from Notification Center after this long. Focusing the tab always clears its notification."
                    ) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { expiryMinutes },
                                set: {
                                    expiryMinutes = $0
                                    AppSettings.shared.notificationExpiryMinutes = $0
                                }
                            )
                        ) {
                            ForEach(Self.expiryChoices, id: \.self) { minutes in
                                Text(minutes == 0 ? "Never" : minutes < 60 ? "\(minutes) min" : "1 hour").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

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
        let t = tokens
        switch authStatus {
        case .authorized:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(t.success)
                    .font(.system(size: 12))
                Text("Notifications are allowed in System Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
        case .denied:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(t.warning)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boo is not allowed to send notifications.")
                        .font(.system(size: 11))
                        .foregroundStyle(t.muted)
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                    .buttonStyle(.themed)
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
            .buttonStyle(.themed)
        default:
            EmptyView()
        }
    }

    private func refreshAuthStatus() async {
        authStatus = await ActivityNotifier.shared.authorizationStatus()
    }
}
