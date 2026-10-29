import SwiftUI

/// Shown while waiting for the remote session to authenticate/connect.
struct RemoteConnectingView: View {
    let session: RemoteSessionType

    var body: some View {
        let theme = AppSettings.shared.theme

        VStack(spacing: 12) {
            Spacer()

            Image(systemName: session.icon)
                .font(.system(size: 28))
                .foregroundStyle(Color(nsColor: theme.accentColor).opacity(0.6))

            Text("Connecting to")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: theme.chromeMuted))

            Text(session.displayName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.chromeText))

            ProgressView()
                .scaleEffect(0.7)
                .padding(.top, 4)

            Text(session.connectingHint)
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: theme.chromeMuted).opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
    }

}

/// Shown when the file explorer could not connect to the remote session.
struct RemoteConnectionFailedView: View {
    let session: RemoteSessionType
    var onRetry: (() -> Void)?
    @State private var isRetrying = false

    var body: some View {
        let theme = AppSettings.shared.theme

        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "xmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Color(nsColor: theme.chromeMuted).opacity(0.6))

            Text("Could not connect to")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: theme.chromeMuted))

            Text(session.displayName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.chromeText))

            Text(
                canPrompt
                    ? "Key and agent auth failed. Connect… asks for\na password, passphrase or 2FA code."
                    : "File explorer requires key-based\nSSH auth or SSH agent."
            )
            .font(.system(size: 10))
            .foregroundStyle(Color(nsColor: theme.chromeMuted).opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)

            if isRetrying {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                HStack(spacing: 8) {
                    if canPrompt {
                        Button("Connect…") { connect(interactive: true) }
                            .help("Open a shared SSH connection, asking in a dialog if the host needs input")
                    }
                    Button("Retry") { connect(interactive: false) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
    }

    /// Plain ssh/mosh hosts can prompt; container ssh (vagrant, colima) manages its own keys.
    private var canPrompt: Bool {
        if case .container = session { return false }
        return true
    }

    private func connect(interactive: Bool) {
        guard session.isSSHBased else {
            onRetry?()
            return
        }
        isRetrying = true
        let done: @Sendable (Bool) -> Void = { [self] _ in
            MainActor.assumeIsolated {
                self.isRetrying = false
                self.onRetry?()
            }
        }
        let alias = session.sshConnectionTarget
        if interactive {
            SSHControlManager.shared.connectInteractively(alias: alias, completion: done)
        } else {
            SSHControlManager.shared.ensureConnection(alias: alias, completion: done)
        }
    }
}

/// The remote explorer: the shared `FileTreeView` once the first listing arrived, a
/// connecting placeholder before that, and the connection-failed view when the target
/// could not be reached at all (an unreadable folder stays in the tree as a placeholder row).
struct RemoteFileTreeContainer: View {
    @ObservedObject var root: FileTreeNode
    let source: RemoteFileTreeSource
    var actions: FileTreeActions
    var navigation: FileTreeNavigation?

    var body: some View {
        if root.children == nil {
            RemoteConnectingView(session: source.session)
        } else if root.loadFailed && source.isUnreachable {
            RemoteConnectionFailedView(session: source.session) {
                root.loadChildrenAsync()
            }
        } else {
            FileTreeView(root: root, actions: actions, navigation: navigation)
        }
    }
}
