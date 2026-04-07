import Cocoa

/// Unified action dispatch for plugins, replacing both PluginHostActions and DSLActionHandler.
/// Plugins use this single object for all host interactions.
@MainActor
final class PluginActions {
    var sendToTerminal: ((String) -> Void)?
    var openDirectoryInNewTab: ((String) -> Void)?
    var openDirectoryInNewPane: ((String) -> Void)?
    var pastePathToActivePane: ((String) -> Void)?
    /// Display an image using the Kitty Graphics Protocol.
    /// `newTab`: open a new tab first; false = inject into the focused terminal's PTY directly.
    var displayImageInTerminal: ((String, Bool) -> Void)?

    func pastePath(_ path: String) {
        pastePathToActivePane?(path)
    }

    func cd(to path: String) {
        sendToTerminal?("cd \(RemoteExplorer.shellEscPath(path))\r")
    }

    func exec(_ command: String) {
        sendToTerminal?(command + "\r")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

        default:
            return nil
        }
    }
}
