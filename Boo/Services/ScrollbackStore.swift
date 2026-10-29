import Foundation

/// Terminal scrollback carried across app restarts. On quit each terminal
/// tab's screen (with SGR styling) is written to `~/.boo/scrollback/<tabID>`;
/// on restore the file is fed into the new surface before the shell prints
/// anything, then deleted. Files are owner-only: scrollback can hold secrets.
enum ScrollbackStore {
    /// Per-tab cap. Older output is dropped at a line boundary.
    static let maxBytes = 2 * 1024 * 1024

    nonisolated(unsafe) static var _testDirectory: String?
    static var directory: String { _testDirectory ?? (BooPaths.configDir as NSString).appendingPathComponent("scrollback") }

    /// Restored tab ID → saved scrollback ID, consumed when the surface is created.
    nonisolated(unsafe) private static var pending: [UUID: UUID] = [:]
    private static let lock = NSLock()

    private static func path(for id: UUID) -> String {
        (directory as NSString).appendingPathComponent(id.uuidString)
    }

    // MARK: - Save

    /// Remove all saved scrollback, e.g. before writing a fresh set on quit.
    static func clear() {
        try? FileManager.default.removeItem(atPath: directory)
        lock.withLock { pending.removeAll() }
    }

    static func save(_ text: String, for id: UUID) {
        guard let data = trimmed(text) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: path(for: id), contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Drops trailing blank lines (the empty rows below the prompt) and caps
    /// the size, cutting at a newline so no escape sequence is split.
    static func trimmed(_ text: String) -> Data? {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        var data = Data(lines.joined(separator: "\n").utf8)
        if data.count > maxBytes {
            let tail = data.suffix(maxBytes)
            let cut = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
            data = Data(tail[cut...])
        }
        return data.isEmpty ? nil : data
    }

    /// Blank once SGR sequences are ignored.
    private static func isBlank(_ line: String) -> Bool {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;:]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Restore

    /// Link a restored tab to the scrollback saved under its previous ID.
    static func schedule(savedID: UUID, for tabID: UUID) {
        guard FileManager.default.fileExists(atPath: path(for: savedID)) else { return }
        lock.withLock { pending[tabID] = savedID }
    }

    /// Bytes to replay into the tab's new surface, or nil. Deletes the file.
    static func take(for tabID: UUID) -> [UInt8]? {
        guard let savedID = lock.withLock({ pending.removeValue(forKey: tabID) }) else { return nil }
        let file = path(for: savedID)
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let data = FileManager.default.contents(atPath: file), !data.isEmpty else { return nil }
        // Line endings as a pty would send them, then reset attributes and
        // leave the new prompt on a fresh line.
        let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        return Array((body + "\u{1B}[0m\r\n").utf8)
    }

    /// Delete saved files no restored tab claimed (closed workspaces, missing folders).
    static func pruneUnclaimed() {
        let claimed = lock.withLock { Set(pending.values.map(\.uuidString)) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in files where !claimed.contains(name) {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
        }
    }
}
