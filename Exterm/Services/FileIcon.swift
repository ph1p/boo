import Foundation

/// Maps a filename to an SF Symbols icon name.
func fileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "js", "ts", "jsx", "tsx": return "doc.text"
    case "json": return "curlybraces"
    case "md", "txt": return "doc.plaintext"
    case "py", "rb", "go", "rs": return "doc.text"
    case "sh", "bash", "zsh": return "terminal"
    case "conf", "cfg", "ini", "yml", "yaml", "toml": return "gearshape"
    case "png", "jpg", "jpeg", "gif", "svg": return "photo"
    case "html", "css": return "globe"
    case "metal", "h", "c", "cpp", "m": return "chevron.left.forwardslash.chevron.right"
    case "log": return "doc.text"
    default: return "doc"
    }
}

/// Shell-escape a path using single quotes.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
