import SwiftUI

// MARK: - Status Bar

struct StatusBarSettingsView: View {
    @State private var showTime = AppSettings.shared.statusBarShowTime
    @State private var showPaneInfo = AppSettings.shared.statusBarShowPaneInfo
    @State private var showConnection = AppSettings.shared.statusBarShowConnection
    @State private var showPath = AppSettings.shared.statusBarShowPath
    @State private var showGitBranch = AppSettings.shared.statusBarShowGitBranch
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .statusBar])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        SettingsPage(title: "Status Bar") {
            Section(title: "Preview") {
                statusBarPreview(t)
            }

            Section(title: "Left Segments") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Connection", isOn: $showConnection)
                        .onChange(of: showConnection) { v in AppSettings.shared.statusBarShowConnection = v }
                    ToggleRow(label: "Current path", isOn: $showPath)
                        .onChange(of: showPath) { v in AppSettings.shared.statusBarShowPath = v }
                    ToggleRow(label: "Git branch", isOn: $showGitBranch)
                        .onChange(of: showGitBranch) { v in AppSettings.shared.statusBarShowGitBranch = v }
                }
            }

            Section(title: "Right Segments") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Pane & tab count", isOn: $showPaneInfo)
                        .onChange(of: showPaneInfo) { v in AppSettings.shared.statusBarShowPaneInfo = v }
                    ToggleRow(label: "Clock", isOn: $showTime)
                        .onChange(of: showTime) { v in AppSettings.shared.statusBarShowTime = v }
                }
            }
        }
    }

    private func statusBarPreview(_ t: Tokens) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if showConnection {
                    statusChip(icon: "circle.fill", label: "local", color: Color.green, t: t)
                }
                if showPath {
                    statusChip(icon: "folder", label: "~/projects/boo", color: t.muted, t: t)
                }
                if showGitBranch {
                    statusChip(icon: "arrow.triangle.branch", label: "main", color: t.muted, t: t)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                if showPaneInfo {
                    statusChip(icon: nil, label: "2 panes \u{00B7} 3 tabs", color: t.muted, t: t)
                }
                if showTime {
                    statusChip(icon: nil, label: "12:00", color: t.muted, t: t)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(t.chromeBg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(t.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func statusChip(icon: String?, label: String, color: Color, t: Tokens) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(color)
        }
    }
}
