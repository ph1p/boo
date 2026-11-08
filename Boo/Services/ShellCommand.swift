import Foundation

/// Shell-escape a path using single quotes.
func shellEscape(_ path: String) -> String {
    let special = CharacterSet(charactersIn: " '\"\\$`!#&|;(){}[]<>*?~\t\n")
    if path.unicodeScalars.contains(where: { special.contains($0) }) {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return path
}

/// Commands Boo types into a shell for the user (cd, editor, branch switch),
/// as opposed to ones the user wrote. They start with a space so they stay out
/// of shell history: Boo's shell integration turns on ignore-space in zsh and
/// bash, and fish skips such lines on its own.
enum ShellCommand {
    /// `command` hidden from history and submitted.
    static func hidden(_ command: String) -> String { " " + command + "\r" }

    /// `cd` to a path the caller already escaped for its shell.
    static func cd(_ escapedPath: String) -> String { hidden("cd \(escapedPath)") }

    /// Clears the screen and scrollback.
    static let clearScrollback = hidden("printf '\\033[3J\\033[2J\\033[H'")
}
