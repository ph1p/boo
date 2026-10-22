import AppKit
import Foundation

/// Where a file link opens.
enum LinkTarget: String, Codable, CaseIterable, Sendable {
    /// Boo's built-in Monaco editor tab.
    case monaco
    /// The external editor from Settings → Editor.
    case external

    var displayName: String {
        switch self {
        case .monaco: return "Built-in Editor"
        case .external: return "External Editor"
        }
    }

    var other: LinkTarget { self == .monaco ? .external : .monaco }
}

/// External editors a file link can open in. Each preset is a template with
/// `{path}`, `{line}` and `{col}`: a URL (placeholders percent-encoded) or a
/// shell command (placeholders shell-quoted).
enum ExternalEditorPreset: String, CaseIterable, Codable, Sendable {
    case vscode, cursor, zed, sublime, xcode, terminalEditor, custom

    var displayName: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .xcode: return "Xcode"
        case .terminalEditor: return "$EDITOR in a New Tab"
        case .custom: return "Custom Command"
        }
    }

    /// nil for `.terminalEditor` (opens a tab) and `.custom` (user template).
    var template: String? {
        switch self {
        case .vscode: return "vscode://file{path}:{line}:{col}"
        case .cursor: return "cursor://file{path}:{line}:{col}"
        case .zed: return "zed://file{path}:{line}:{col}"
        case .sublime:
            return "'/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl' {path}:{line}:{col}"
        case .xcode: return "/usr/bin/xed -l {line} {path}"
        case .terminalEditor, .custom: return nil
        }
    }
}

/// A link found in a line of terminal text.
struct TerminalLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case url(URL)
        /// `path` as written (maybe relative); `line`/`column` are 1-based.
        case file(path: String, line: Int?, column: Int?)
    }

    var kind: Kind
    /// Character (grapheme) offsets in the line, which match terminal columns
    /// for single-width text.
    var range: Range<Int>
}

/// Finds `file:line(:col)`, `file(line,col)`, `File "x", line n` and URLs in
/// terminal text, and resolves paths against a working directory.
enum LinkResolver {
    private static let pathChars = #"[A-Za-z0-9_.\-+@~/]"#

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"\b(?:https?|file|ftp)://[^\s<>"'`]+"#)
    /// `File "app.py", line 12` (Python tracebacks).
    private static let pythonRegex = try! NSRegularExpression(
        pattern: #"File "([^"]+)", line (\d+)"#)
    /// `path(12,4)` (MSBuild, TypeScript).
    private static let parenRegex = try! NSRegularExpression(
        pattern: "(\(pathChars)+)\\((\\d+)(?:,\\s*(\\d+))?\\)")
    /// `path:12:4`, `path:12`, or a bare path with a slash or an extension.
    private static let pathRegex = try! NSRegularExpression(
        pattern: "(\(pathChars)+)(?::(\\d+)(?::(\\d+))?)?")

    /// All links in `line`, left to right, without overlaps.
    static func links(in line: String) -> [TerminalLink] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, TerminalLink.Kind)] = []

        func overlaps(_ r: NSRange) -> Bool {
            found.contains { NSIntersectionRange($0.0, r).length > 0 }
        }

        for m in urlRegex.matches(in: line, range: full) {
            var r = m.range
            var text = ns.substring(with: r)
            let trimmed = trimTrailingPunctuation(text)
            r.length -= text.utf16.count - trimmed.utf16.count
            text = trimmed
            guard let url = URL(string: text) else { continue }
            found.append((r, .url(url)))
        }
        for m in pythonRegex.matches(in: line, range: full) where !overlaps(m.range) {
            let path = ns.substring(with: m.range(at: 1))
            found.append((m.range, .file(path: path, line: Int(ns.substring(with: m.range(at: 2))), column: nil)))
        }
        for m in parenRegex.matches(in: line, range: full) where !overlaps(m.range) {
            let path = ns.substring(with: m.range(at: 1))
            guard looksLikePath(path) else { continue }
            found.append((m.range, .file(path: path, line: int(m, 2, ns), column: int(m, 3, ns))))
        }
        for m in pathRegex.matches(in: line, range: full) where !overlaps(m.range) {
            var pathRange = m.range(at: 1)
            var path = ns.substring(with: pathRange)
            let lineNo = int(m, 2, ns)
            // A sentence-ending dot or a trailing slash isn't part of a file name.
            while lineNo == nil, path.count > 1, let last = path.last, ".,".contains(last) {
                path.removeLast()
                pathRange.length -= 1
            }
            guard looksLikePath(path) else { continue }
            let range = lineNo == nil ? pathRange : m.range
            found.append((range, .file(path: path, line: lineNo, column: int(m, 3, ns))))
        }

        return found.sorted { $0.0.location < $1.0.location }.compactMap { r, kind in
            guard let range = characterRange(r, in: line) else { return nil }
            return TerminalLink(kind: kind, range: range)
        }
    }

    /// The character index in `line` drawn at terminal `column`, counting
    /// wide characters (CJK, emoji) as two cells.
    static func characterIndex(forColumn column: Int, in line: String) -> Int? {
        var cell = 0
        for (index, character) in line.enumerated() {
            let width = isWide(character) ? 2 : 1
            if column < cell + width { return index }
            cell += width
        }
        return nil
    }

    static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        // Emoji drawn as emoji (by default or via the VS16 selector).
        if scalar.properties.isEmojiPresentation || character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
            return true
        }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// The link covering character `column` of `line`.
    static func link(in line: String, at column: Int) -> TerminalLink? {
        links(in: line).first { $0.range.contains(column) }
    }

    /// An absolute path for `path` (tilde-expanded, relative to `cwd`).
    static func resolve(_ path: String, cwd: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        guard let cwd, !cwd.isEmpty else { return expanded }
        return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// Candidates to try for a path as printed: as-is, then without git's
    /// `a/` / `b/` diff prefixes.
    static func candidates(_ path: String, cwd: String?) -> [String] {
        var out = [resolve(path, cwd: cwd)]
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            out.append(resolve(String(path.dropFirst(2)), cwd: cwd))
        }
        return out
    }

    /// The first candidate that exists locally (cached for 2 s per path).
    static func existingLocalPath(_ path: String, cwd: String?) -> String? {
        candidates(path, cwd: cwd).first { ExistenceCache.shared.isFile($0) }
    }

    /// Fills `{path}`, `{line}`, `{col}` into an editor template.
    /// URL templates get percent-encoded values; shell templates get quoted ones.
    /// Whether `text` starts with a URL scheme (`vscode://…`).
    static func isURLTemplate(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) != nil
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func expandTemplate(_ template: String, path: String, line: Int?, column: Int?) -> String {
        let pathValue =
            isURLTemplate(template)
            ? path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path : shellQuote(path)
        return
            template
            .replacingOccurrences(of: "{path}", with: pathValue)
            .replacingOccurrences(of: "{line}", with: String(line ?? 1))
            .replacingOccurrences(of: "{col}", with: String(column ?? 1))
    }

    // MARK: Helpers

    private static func int(_ m: NSTextCheckingResult, _ group: Int, _ ns: NSString) -> Int? {
        let r = m.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return Int(ns.substring(with: r))
    }

    /// Something with a slash or a file extension, and at least one letter
    /// (so `12:30:45` and `1.2.3` don't count).
    static func looksLikePath(_ path: String) -> Bool {
        guard path.contains(where: \.isLetter), !path.hasSuffix("/") || path.count > 1 else { return false }
        if path.contains("/") { return path != "//" }
        // `name.ext`: the extension starts with a letter and is short.
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return false }
        let ext = path[path.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.first?.isLetter == true
            && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func trimTrailingPunctuation(_ text: String) -> String {
        var s = Substring(text)
        while let last = s.last {
            if ".,;:!?'\"".contains(last) {
                s.removeLast()
            } else if last == ")" && s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count {
                s.removeLast()
            } else if last == "]" && s.filter({ $0 == "[" }).count < s.filter({ $0 == "]" }).count {
                s.removeLast()
            } else {
                break
            }
        }
        return String(s)
    }

    /// Converts a UTF-16 range to grapheme offsets.
    private static func characterRange(_ r: NSRange, in line: String) -> Range<Int>? {
        guard let range = Range(r, in: line) else { return nil }
        let start = line.distance(from: line.startIndex, to: range.lowerBound)
        let length = line.distance(from: range.lowerBound, to: range.upperBound)
        return start..<(start + length)
    }

    /// File existence, cached briefly so hovering doesn't stat on every move.
    final class ExistenceCache: @unchecked Sendable {
        static let shared = ExistenceCache()
        static let ttl: TimeInterval = 2

        private let lock = NSLock()
        private var entries: [String: (Bool, Date)] = [:]

        func isFile(_ path: String) -> Bool {
            let now = Date()
            if let hit = lock.withLock({ entries[path] }), now.timeIntervalSince(hit.1) < Self.ttl {
                return hit.0
            }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            lock.withLock {
                if entries.count > 512 { entries.removeAll() }
                entries[path] = (exists, now)
            }
            return exists
        }
    }
}

/// Opens links found by `LinkResolver`.
@MainActor
enum LinkOpener {
    /// Where a link was clicked or matched.
    struct Origin {
        var cwd: String?
        var remote: RemoteSessionType?
        weak var controller: MainWindowController?
    }

    /// Opens `link`. `target` nil uses the profile's or the global default.
    static func open(_ link: TerminalLink.Kind, from origin: Origin, target: LinkTarget? = nil) {
        switch link {
        case .url(let url):
            if url.isFileURL {
                open(.file(path: url.path, line: nil, column: nil), from: origin, target: target)
            } else if let controller = origin.controller, AppSettings.shared.linkOpenMode == .browserTab {
                controller.handleOpenTab(.browser(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        case .file(let path, let line, let column):
            if let remote = origin.remote {
                // Remote files only open in Monaco; there's no local path for an
                // external editor.
                openRemote(path: path, line: line, column: column, session: remote, origin: origin)
                return
            }
            guard let resolved = LinkResolver.existingLocalPath(path, cwd: origin.cwd) else {
                BooAlert.showTransient("No such file: \(path)")
                return
            }
            switch target ?? AppSettings.shared.defaultLinkTarget {
            case .monaco:
                origin.controller?.openFileInEditor(path: resolved, line: line, column: column)
            case .external:
                openExternally(path: resolved, line: line, column: column, origin: origin)
            }
        }
    }

    static func openExternally(path: String, line: Int?, column: Int?, origin: Origin) {
        let settings = AppSettings.shared
        let preset = settings.externalEditorPreset
        if preset == .terminalEditor {
            origin.controller?.openFileInTerminalEditor(path, line: line)
            return
        }
        let template = preset == .custom ? settings.externalEditorTemplate : (preset.template ?? "")
        guard !template.trimmingCharacters(in: .whitespaces).isEmpty else {
            BooAlert.showTransient("Set an external editor in Settings → Editor")
            return
        }
        let command = LinkResolver.expandTemplate(template, path: path, line: line, column: column)
        if LinkResolver.isURLTemplate(command) {
            guard let url = URL(string: command), NSWorkspace.shared.open(url) else {
                BooAlert.showTransient("Couldn't open \(preset.displayName)")
                return
            }
            return
        }
        runShell(command, label: preset.displayName)
    }

    /// Runs `command` with the login-shell PATH so editor CLIs are found.
    private static func runShell(_ command: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/local/bin:/opt/homebrew/bin"
            process.environment = env
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    BooAlert.showTransient("Couldn't run \(label): \(error.localizedDescription)")
                }
                return
            }
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return }
            let message = String(decoding: err.prefix(300), as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            booLog(.warning, .app, "[Links] \(label) exited \(process.terminationStatus): \(message)")
            DispatchQueue.main.async {
                BooAlert.showTransient("\(label) failed" + (message.isEmpty ? "" : ": \(message)"))
            }
        }
    }

    /// Copies a remote file to a temp file and opens it in Monaco (read-only
    /// copy; saving writes the temp file).
    private static func openRemote(path: String, line: Int?, column: Int?, session: RemoteSessionType, origin: Origin) {
        let remotePath: String
        if path.hasPrefix("/") || path.hasPrefix("~") {
            remotePath = path
        } else if let cwd = origin.cwd, !cwd.isEmpty {
            remotePath = (cwd as NSString).appendingPathComponent(path)
        } else {
            remotePath = path
        }
        let quoted: String
        if remotePath.hasPrefix("~/") {
            quoted = "~/" + LinkResolver.shellQuote(String(remotePath.dropFirst(2)))
        } else {
            quoted = LinkResolver.shellQuote(remotePath)
        }
        let maxBytes = 5 * 1024 * 1024
        let command = "test -f \(quoted) && head -c \(maxBytes) \(quoted)"
        let controller = origin.controller
        RemoteExplorer.runRemoteCommand(session: session, command: command) { output in
            MainActor.assumeIsolated {
                guard let output else {
                    BooAlert.showTransient("Couldn't read \(path) on \(session.displayName)")
                    return
                }
                let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                    "boo-remote/\(session.displayName.replacingOccurrences(of: "/", with: "_"))")
                let local = (dir as NSString).appendingPathComponent((remotePath as NSString).lastPathComponent)
                do {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try output.write(toFile: local, atomically: true, encoding: .utf8)
                } catch {
                    BooAlert.showTransient("Couldn't open \(path): \(error.localizedDescription)")
                    return
                }
                controller?.openFileInEditor(path: local, line: line, column: column)
            }
        }
    }
}
