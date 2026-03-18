import Cocoa

/// Routes DSL action identifiers to terminal and system operations.
/// ADR-6: Actions are declared in DSL output, interpreted by exterm.
final class DSLActionHandler {

    /// Callback to send a command string to the focused terminal.
    var sendToTerminal: ((String) -> Void)?

    /// Handle a DSL action. Returns a result description for VoiceOver announcement.
    @discardableResult
    func handle(_ action: DSLAction) -> String? {
        switch action.type {
        case "cd":
            guard let path = action.path, !path.isEmpty else { return nil }
            sendToTerminal?("cd \(shellEscape(path))\r")
            return "Changed directory to \(path)"

        case "open":
            guard let path = action.path, !path.isEmpty else { return nil }
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open"
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = [editor, path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            return "Opened \(path)"

        case "exec":
            guard let command = action.command, !command.isEmpty else { return nil }
            sendToTerminal?(command + "\r")
            return nil // terminal output IS the feedback

        case "copy":
            guard let text = action.text ?? action.path, !text.isEmpty else { return nil }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return "Copied to clipboard"

        case "reveal":
            guard let path = action.path, !path.isEmpty else { return nil }
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            return "Revealed in Finder"

        default:
            return nil
        }
    }

    /// Minimal shell escaping for paths with spaces.
    private func shellEscape(_ str: String) -> String {
        if str.contains(" ") || str.contains("'") || str.contains("\"") ||
           str.contains("(") || str.contains(")") || str.contains("&") {
            return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return str
    }
}
