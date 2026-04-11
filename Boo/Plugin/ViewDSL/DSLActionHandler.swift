import Cocoa
@preconcurrency import UserNotifications

/// Routes DSL action identifiers to terminal and system operations.
/// ADR-6: Actions are declared in DSL output, interpreted by boo.
final class DSLActionHandler {

    /// Callback to send a command string to the focused terminal.
    var sendToTerminal: ((String) -> Void)?
    /// Callbacks for tab/pane creation.
    var openDirectoryInNewTab: ((String) -> Void)?
    var openDirectoryInNewPane: ((String) -> Void)?
    var pastePathToActivePane: ((String) -> Void)?

    /// Handle a DSL action. Returns a result description for VoiceOver announcement.
    @discardableResult
    func handle(_ action: DSLAction) -> String? {
        switch action.type {
        case "cd":
            guard let path = action.path, !path.isEmpty else { return nil }
            sendToTerminal?("cd \(RemoteExplorer.shellEscPath(path))\r")
            return "Changed directory to \(path)"

        case "open":
            guard let path = action.path, !path.isEmpty else { return nil }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return "Opened \(path)"

        case "exec":
            guard let command = action.command, !command.isEmpty else { return nil }
            sendToTerminal?(command + "\r")
            return nil  // terminal output IS the feedback

        case "copy":
            guard let text = action.text ?? action.path, !text.isEmpty else { return nil }
            NSPasteboard.general.clearContents()
            if !NSPasteboard.general.setString(text, forType: .string) {
                DispatchQueue.main.async {
                    BooAlert.showTransient("Could not copy to clipboard")
                }
            }
            return "Copied to clipboard"

        case "reveal":
            guard let path = action.path, !path.isEmpty else { return nil }
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            return "Revealed in Finder"

        case "url":
            guard let urlStr = action.url ?? action.text, !urlStr.isEmpty,
                let url = URL(string: urlStr)
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
            Self.sendNotification(title: title, body: text)
            return nil

        default:
            return nil
        }
    }

    private static func sendNotification(title: String, body: String) {
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
