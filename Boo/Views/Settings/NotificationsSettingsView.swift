import Cocoa
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @Environment(\.tokens) private var tokens
    @State private var activityNotificationsEnabled = AppSettings.shared.activityNotificationsEnabled
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var phonePushEnabled = AppSettings.shared.phonePushEnabled
    @State private var phonePushURL = AppSettings.shared.phonePushURL
    @State private var longCommandSeconds = AppSettings.shared.phonePushLongCommandSeconds
    @State private var pushTestResult: String?

    private static let longCommandChoices = [30, 60, 120, 300, 600, 1800]
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

                if activityNotificationsEnabled {
                    permissionRow
                }
            }

            Section(title: "Push to Phone") {
                ToggleRow(
                    label: "Push to phone",
                    help:
                        "POST to an ntfy topic when an agent needs input, a long command finishes, or an SSH connection drops — only while you're not looking at that tab. Sent: the event type, the workspace name and the agent name. Never terminal content.",
                    isOn: Binding(
                        get: { phonePushEnabled },
                        set: {
                            phonePushEnabled = $0
                            AppSettings.shared.phonePushEnabled = $0
                        }
                    )
                )

                if phonePushEnabled {
                    SettingRow(
                        label: "Topic URL",
                        help:
                            "An ntfy.sh topic (pick a hard-to-guess name) or your own ntfy server. With remote control running, tapping the push opens the remote page."
                    ) {
                        HStack(spacing: 8) {
                            SettingTextField(
                                placeholder: "https://ntfy.sh/your-secret-topic",
                                text: $phonePushURL,
                                monospaced: true
                            )
                            .onChange(of: phonePushURL) { _, value in AppSettings.shared.phonePushURL = value }
                            Button("Send Test") {
                                pushTestResult = "Sending…"
                                PhonePusher.shared.sendTest(topicURL: phonePushURL) { failure in
                                    pushTestResult = failure.map { "Failed: \($0)" } ?? "Sent"
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(phonePushURL.isEmpty)
                        }
                    }
                    if let pushTestResult {
                        DescriptionLabel(text: pushTestResult)
                    }

                    SettingRow(label: "Long command") {
                        Picker(
                            "",
                            selection: Binding(
                                get: { longCommandSeconds },
                                set: {
                                    longCommandSeconds = $0
                                    AppSettings.shared.phonePushLongCommandSeconds = $0
                                }
                            )
                        ) {
                            ForEach(Self.longCommandChoices, id: \.self) { seconds in
                                Text(seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) min").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 140)
                    }
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
