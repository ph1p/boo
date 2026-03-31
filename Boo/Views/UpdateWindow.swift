import Cocoa
import SwiftUI

/// Window controller for the update notification panel.
final class UpdateWindowController: NSWindowController {
    static let shared = UpdateWindowController()

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
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

    var body: some View {
        VStack(spacing: 16) {
            switch updater.state {
            case .checking:
                ProgressView("Checking for updates...")
                    .padding(.top, 20)

            case .available(let release):
                availableView(release: release)

            case .downloading(let progress):
                downloadingView(progress: progress)

            case .readyToInstall(let dmgURL):
                readyView(dmgURL: dmgURL)

            case .installing:
                ProgressView("Installing update...")
                    .padding(.top, 20)

            case .error(let message):
                errorView(message: message)

            case .idle:
                Text("No updates available.")
                    .foregroundColor(.secondary)
                    .padding(.top, 20)
            }

            Spacer()
        }
        .frame(width: 380)
        .padding()
    }

    private func availableView(release: AutoUpdater.Release) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Boo \(release.version) Available")
                        .font(.headline)
                    Text("You have \(AutoUpdater.currentVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if let body = release.body, !body.isEmpty {
                ScrollView {
                    Text(body)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }

            HStack {
                Button("Skip This Version") {
                    updater.skipVersion(release.version)
                    UpdateWindowController.shared.close()
                }
                .buttonStyle(.bordered)

                Button("Remind Me Later") {
                    updater.dismiss()
                    UpdateWindowController.shared.close()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Download & Install") {
                    updater.downloadUpdate(release)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 12) {
            Text("Downloading update...")
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Cancel") {
                updater.cancelDownload()
            }
            .buttonStyle(.bordered)
        }
    }

    private func readyView(dmgURL: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            Text("Update downloaded!")
                .font(.headline)
            Text("Boo will quit, install the update, and relaunch.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Install & Relaunch") {
                updater.installAndRelaunch(dmgURL: dmgURL)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Update Error")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Dismiss") {
                updater.dismiss()
                UpdateWindowController.shared.close()
            }
            .buttonStyle(.bordered)
        }
    }
}
