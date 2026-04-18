import Cocoa
import SwiftUI

/// Window controller for the update notification panel.
final class UpdateWindowController: NSWindowController {
    static let shared = UpdateWindowController()

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: UpdateView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showIfUpdateAvailable() {
        switch AutoUpdater.shared.state {
        case .available, .downloading, .readyToInstall, .error:
            showWindow(nil)
            window?.center()
        default:
            break
        }
    }
}

// MARK: - SwiftUI Update View

struct UpdateView: View {
    @ObservedObject var updater = AutoUpdater.shared
    @State private var webViewHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            switch updater.state {
            case .checking:
                statusView {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .available(let release, let changelog):
                availableView(release: release, changelog: changelog)

            case .downloading(let progress):
                downloadingView(progress: progress)

            case .readyToInstall(let dmgURL):
                readyView(dmgURL: dmgURL)

            case .installing:
                statusView {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing update...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .error(let message):
                errorView(message: message)

            case .idle:
                statusView {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("You're up to date.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 440)
        .padding(20)
    }

    private func statusView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func availableView(release: AutoUpdater.Release, changelog: [AutoUpdater.Release]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Boo \(release.version)")
                        .font(.headline)
                    Text("Current version: \(AutoUpdater.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            let combinedMarkdown = Self.buildChangelog(from: changelog)
            if !combinedMarkdown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Release Notes")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    MarkdownWebView(
                        html: MarkdownRenderer.renderHTML(from: combinedMarkdown),
                        contentHeight: $webViewHeight
                    )
                    .frame(height: min(max(webViewHeight, 60), 300))
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                }
            }

            HStack(spacing: 8) {
                Button("Skip") {
                    updater.skipVersion(release.version)
                    UpdateWindowController.shared.close()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Later") {
                    updater.dismiss()
                    UpdateWindowController.shared.close()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Download & Install") {
                    updater.downloadUpdate(release)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private static func buildChangelog(from releases: [AutoUpdater.Release]) -> String {
        var parts: [String] = []
        for release in releases {
            guard let body = release.body, !body.isEmpty else { continue }
            parts.append("## \(release.version)\n\n\(body)")
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 10) {
            Text("Downloading update...")
                .font(.subheadline)
                .fontWeight(.medium)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    updater.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private func readyView(dmgURL: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green)
            Text("Ready to install")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("Boo will quit, install the update, and relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Install & Relaunch") {
                updater.installAndRelaunch(dmgURL: dmgURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.vertical, 8)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Update Error")
                .font(.subheadline)
                .fontWeight(.medium)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Dismiss") {
                updater.dismiss()
                UpdateWindowController.shared.close()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}
