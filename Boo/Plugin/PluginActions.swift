import Cocoa
import SwiftUI
@preconcurrency import UserNotifications

/// Unified action dispatch for plugins, replacing both PluginHostActions and DSLActionHandler.
/// Plugins use this single object for all host interactions.
@MainActor
final class PluginActions {
    var sendToTerminal: ((String) -> Void)?
    var openDirectoryInNewTab: ((String) -> Void)?
    var openDirectoryInNewPane: ((String) -> Void)?
    /// Open a file content tab (editor, viewer, etc.) in a new split pane.
    var openFileInNewPane: ((String) -> Void)?
    var pastePathToActivePane: ((String) -> Void)?
    /// Display an image using the Kitty Graphics Protocol.
    /// `newTab`: open a new tab first; false = inject into the focused terminal's PTY directly.
    var displayImageInTerminal: ((String, Bool) -> Void)?
    /// Returns true when the active terminal has a non-shell foreground process running.
    var isTerminalBusy: (() -> Bool)?

    /// Open a new tab with the specified payload (terminal, browser, or file).
    var openTab: ((TabPayload) -> Void)?

    /// Register a factory for a named custom tab type.
    /// The factory is called each time a new tab of this type needs to be created.
    /// Registering the same typeID twice replaces the previous factory.
    var registerMultiContentTab: ((String, @escaping (PluginTabContext) -> AnyView) -> Void)?

    /// Open (or focus an existing) custom tab by type.
    /// If a tab with the same typeID + context.key already exists in the active workspace,
    /// it is focused instead of creating a duplicate.
    var openMultiContentTab: ((String, PluginTabContext) -> Void)?

    /// Set the AI agent session ID for the active tab.
    var setAgentSessionID: ((String?) -> Void)?
    /// Get the AI agent session ID for the active tab.
    var getAgentSessionID: (() -> String?)?
    /// Running agent sessions in terminal tabs of the active workspace.
    var workspaceAgentSessions: (() -> [WorkspaceAgentSession])?
    /// Focus a terminal tab that owns a workspace-scoped agent session.
    var focusAgentSession: ((WorkspaceAgentSession.ID) -> Void)?

    func pastePath(_ path: String) {
        pastePathToActivePane?(path)
    }

    /// Convenience method to open a file in the appropriate viewer.
    func openFile(_ path: String) {
        openTab?(.file(path: path))
    }

    func cd(to path: String) {
        sendToTerminal?("cd \(RemoteExplorer.shellEscPath(path))\r")
    }

    func exec(_ command: String) {
        sendToTerminal?(command + "\r")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) {
            BooAlert.showTransient("Could not copy to clipboard")
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func openInEditor(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Handle a DSL action. Returns a result description for VoiceOver announcement.
    @discardableResult
    func handle(_ action: DSLAction) -> String? {
        switch action.type {
        case "cd":
            guard let path = action.path, !path.isEmpty else { return nil }
            cd(to: path)
            return "Changed directory to \(path)"

        case "open":
            guard let path = action.path, !path.isEmpty else { return nil }
            openInEditor(path)
            return "Opened \(path)"

        case "exec":
            guard let command = action.command, !command.isEmpty else { return nil }
            sendToTerminal?(command + "\r")
            return nil

        case "copy":
            guard let text = action.text ?? action.path, !text.isEmpty else { return nil }
            copy(text)
            return "Copied to clipboard"

        case "reveal":
            guard let path = action.path, !path.isEmpty else { return nil }
            reveal(path)
            return "Revealed in Finder"

        case "url":
            guard let urlStr = action.url ?? action.text, !urlStr.isEmpty,
                let url = URL(string: urlStr),
                url.scheme == "https" || url.scheme == "http"
            else { return nil }
            NSWorkspace.shared.open(url)
            return "Opened URL"

        case "newTab":
            openDirectoryInNewTab?(action.path ?? "")
            return "Opened new tab"

        case "newPane":
            openDirectoryInNewPane?(action.path ?? "")
            return "Opened new pane"

        case "paste":
            guard let text = action.text, !text.isEmpty else { return nil }
            pastePathToActivePane?(text)
            return "Pasted text"

        case "notification":
            guard let text = action.text ?? action.command, !text.isEmpty else { return nil }
            let title = action.title ?? "Boo"
            sendNotification(title: title, body: text)
            return nil

        default:
            return nil
        }
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
