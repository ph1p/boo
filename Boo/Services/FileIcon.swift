import Foundation

/// Maps a filename to an SF Symbols icon name.
func fileIcon(for name: String) -> String {
    switch name.lowercased() {
    case "dockerfile", "containerfile", "docker-compose.yml", "compose.yaml": return "shippingbox"
    case "makefile", "justfile", "rakefile", "package.swift": return "hammer"
    case "license", "license.md", "license.txt", "copying": return "checkmark.seal"
    case ".gitignore", ".gitattributes", ".gitmodules", ".dockerignore": return "eye.slash"
    case ".env", ".envrc": return "key"
    default: break
    }
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "js", "ts", "jsx", "tsx", "mjs", "cjs": return "doc.text"
    case "json": return "curlybraces"
    case "md", "txt", "rst": return "doc.plaintext"
    case "py", "rb", "go", "rs", "java", "kt", "zig", "lua", "php", "ex", "exs": return "doc.text"
    case "sh", "bash", "zsh", "fish": return "terminal"
    case "conf", "cfg", "ini", "yml", "yaml", "toml", "plist", "xcconfig": return "gearshape"
    case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico", "bmp", "tiff": return "photo"
    case "html", "css", "scss", "htm": return "globe"
    case "metal", "h", "c", "cpp", "m", "mm", "hpp", "cc": return "chevron.left.forwardslash.chevron.right"
    case "log": return "doc.text"
    case "pdf": return "doc.richtext"
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
    case "lock", "resolved": return "lock"
    case "csv", "tsv", "xlsx", "numbers": return "tablecells"
    case "sql", "sqlite", "db": return "cylinder"
    case "mp3", "wav", "aac", "flac", "m4a": return "waveform"
    case "mp4", "mov", "mkv", "webm", "avi": return "film"
    case "ttf", "otf", "woff", "woff2": return "textformat"
    case "pem", "key", "crt", "cer", "p12": return "key"
    default: return "doc"
    }
}

/// Maps a folder name to an SF Symbols icon name.
func folderIcon(for name: String) -> String {
    switch name.lowercased() {
    case ".git", ".github", ".vscode", ".idea", ".claude", ".config": return "folder.badge.gearshape"
    case "node_modules", "vendor", "pods", ".build", "build", "dist", "deriveddata": return "shippingbox.fill"
    default: return "folder.fill"
    }
}

/// Shell-escape a path using single quotes.
func shellEscape(_ path: String) -> String {
    let special = CharacterSet(charactersIn: " '\"\\$`!#&|;(){}[]<>*?~\t\n")
    if path.unicodeScalars.contains(where: { special.contains($0) }) {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return path
}
