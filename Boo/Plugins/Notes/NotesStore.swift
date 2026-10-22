import AppKit
import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted with the note's path as `object` after text was appended to it.
    static let noteAppended = Notification.Name("BooNoteAppended")
}

/// A note file and the name it is listed under.
struct NoteFile: Identifiable, Equatable {
    var path: String
    var title: String
    var modified: Date

    var id: String { path }
}

/// One line of a note that matched a search.
struct NoteMatch: Identifiable, Equatable {
    var path: String
    var title: String
    /// 1-based.
    var line: Int
    var text: String

    var id: String { "\(path):\(line)" }
}

/// Per-workspace markdown notes in `~/.boo/notes/`. A note is keyed by the
/// workspace folder (so it survives deleting and re-adding the workspace),
/// or by the workspace ID when the workspace has no folder. `scratch.md` is
/// one global note shared by all workspaces.
enum NotesStore {
    static let pluginID = "notes"
    static let scratchTitle = "Scratch"
    private static let scratchFileName = "scratch.md"
    /// File name → workspace name, since hashed file names say nothing.
    private static let indexFileName = "titles.json"

    /// File name (without directory) of the note for a workspace.
    static func fileName(folderPath: String, workspaceID: UUID) -> String {
        let folder = (folderPath as NSString).standardizingPath
        guard !folder.isEmpty, folder != "/" else { return workspaceID.uuidString.lowercased() + ".md" }
        let digest = Insecure.SHA1.hash(data: Data(folder.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".md"
    }

    static func path(folderPath: String, workspaceID: UUID, in directory: String = BooPaths.notesDir) -> String {
        directory.appendingPathComponent(fileName(folderPath: folderPath, workspaceID: workspaceID))
    }

    static func scratchPath(in directory: String = BooPaths.notesDir) -> String {
        directory.appendingPathComponent(scratchFileName)
    }

    /// Note path of the active window's workspace.
    @MainActor
    static func activeNotePath() -> (path: String, title: String)? {
        guard let workspace = WindowManager.shared.activeController?.activeWorkspace else { return nil }
        return (path(folderPath: workspace.folderPath, workspaceID: workspace.id), workspace.displayName)
    }

    // MARK: - Titles and listing

    private static func titles(in directory: String) -> [String: String] {
        let url = URL(fileURLWithPath: directory.appendingPathComponent(indexFileName))
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Records the workspace name a note is listed under; writes only on change.
    static func rememberTitle(_ title: String, for path: String) {
        rememberTitles([(path, title)])
    }

    /// Batched `rememberTitle`: one index read and at most one write per
    /// directory. Pairs are `(path, title)`.
    static func rememberTitles(_ pairs: [(path: String, title: String)]) {
        let byDirectory = Dictionary(grouping: pairs) { $0.path.deletingLastPathComponent }
        for (directory, pairs) in byDirectory {
            var index = titles(in: directory)
            var changed = false
            for (path, title) in pairs {
                let name = path.lastPathComponent
                guard name != scratchFileName, index[name] != title else { continue }
                index[name] = title
                changed = true
            }
            if changed { writeTitles(index, in: directory) }
        }
    }

    private static func writeTitles(_ index: [String: String], in directory: String) {
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(
                to: URL(fileURLWithPath: directory.appendingPathComponent(indexFileName)),
                options: .atomic)
        } catch {
            debugLog("[Notes] title index write failed: \(error.localizedDescription)")
        }
    }

    /// All notes, scratch first, then most recently modified.
    static func list(in directory: String = BooPaths.notesDir) -> [NoteFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let index = titles(in: directory)
        let notes = names.filter { $0.hasSuffix(".md") }.map { name -> NoteFile in
            let path = directory.appendingPathComponent(name)
            let modified =
                (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            let title =
                name == scratchFileName ? scratchTitle : index[name] ?? String(name.dropLast(".md".count))
            return NoteFile(path: path, title: title, modified: modified)
        }
        return notes.sorted {
            let scratch = ($0.title == scratchTitle, $1.title == scratchTitle)
            return scratch.0 != scratch.1 ? scratch.0 : $0.modified > $1.modified
        }
    }

    /// Lines containing `query` (case-insensitive) across all notes, in
    /// `list` order, at most `limit`.
    static func search(_ query: String, in directory: String = BooPaths.notesDir, limit: Int = 200) -> [NoteMatch] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var matches: [NoteMatch] = []
        for note in list(in: directory) {
            guard let text = try? String(contentsOfFile: note.path, encoding: .utf8) else { continue }
            var number = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                number += 1
                guard line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                matches.append(
                    NoteMatch(path: note.path, title: note.title, line: number, text: String(trimmed.prefix(200))))
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }

    // MARK: - Appending

    nonisolated(unsafe) private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// `text` as a markdown block to append: a fenced block (fence longer than
    /// any backtick run inside) under a timestamp line naming `cwd`. With
    /// `command`, the block starts with `$ command`.
    static func appendBlock(_ text: String, command: String? = nil, cwd: String? = nil, date: Date = Date()) -> String {
        var body = text.trimmingCharacters(in: .newlines)
        if let command, !command.isEmpty { body = "$ \(command)\n\(body)" }
        var stamp = "_\(stampFormatter.string(from: date))_"
        if let cwd, !cwd.isEmpty { stamp += " · `\((cwd as NSString).abbreviatingWithTildeInPath)`" }
        return "\(stamp)\n\n\(AgentHandoff.fenced(body))"
    }

    /// Appends `text` to the note at `path`, separated from existing content
    /// by a blank line. Creates the file when missing.
    @discardableResult
    static func append(
        _ text: String, command: String? = nil, cwd: String? = nil, to path: String, date: Date = Date()
    ) -> Bool {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var separator = ""
        if !existing.isEmpty {
            separator = existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        }
        let updated = existing + separator + appendBlock(text, command: command, cwd: cwd, date: date)
        do {
            try FileManager.default.createDirectory(
                atPath: path.deletingLastPathComponent, withIntermediateDirectories: true)
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            debugLog("[Notes] append failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Open editors

    /// Sidebar editors by note path, so an append can save their pending
    /// edits first instead of reloading over them.
    @MainActor private static let openEditors = NSMapTable<NSString, EditorContentView>.strongToWeakObjects()

    @MainActor static func register(_ editor: EditorContentView, for path: String) {
        openEditors.setObject(editor, forKey: path as NSString)
    }

    /// Drops `editor` wherever it is registered (a newer editor on its path stays).
    @MainActor static func unregister(_ editor: EditorContentView) {
        for case let path as NSString in openEditors.keyEnumerator().allObjects
        where openEditors.object(forKey: path) === editor {
            openEditors.removeObject(forKey: path)
        }
    }

    @MainActor static func editor(for path: String) -> EditorContentView? {
        openEditors.object(forKey: path as NSString)
    }

    /// Saves unsaved edits of an open editor on `path`, then calls `then`.
    @MainActor static func flush(_ path: String, then: @escaping @MainActor () -> Void) {
        guard let editor = editor(for: path), editor.hasUnsavedChanges else {
            return then()
        }
        editor.saveFile { _ in MainActor.assumeIsolated { then() } }
    }
}
