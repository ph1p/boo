import Foundation
import SQLite3

/// One recorded command, or (from `search`) the latest run of a distinct command.
struct HistoryEntry: Equatable, Sendable, Identifiable {
    var id: Int64
    var command: String
    var cwd: String
    var exitCode: Int32?
    var durationMs: Int64
    var host: String?
    var workspaceID: UUID?
    var paneID: UUID?
    var startedAt: Date
    /// How often the command ran (within the search filters).
    var count: Int = 1

    var failed: Bool { (exitCode ?? 0) != 0 }
}

/// Narrows a history search; the overlay's chips.
struct HistoryFilter: Equatable, Sendable {
    var text = ""
    var workspaceID: UUID?
    var failedOnly = false
    /// Matches the host column; `.some(nil)` means local commands only.
    var host: String??
    var cwd: String?
    /// Ranks runs in this directory higher without filtering on it.
    var preferredCwd: String?
}

/// Command history in `~/.boo/history.db` (SQLite, FTS5 on the command text).
/// All database work runs on a private serial queue; callers get results back
/// through completion handlers or `async`.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore(path: BooPaths.historyDB)

    let path: String
    private let queue = DispatchQueue(label: "boo.history", qos: .utility)
    /// Only touched on `queue`.
    private var db: OpaquePointer?
    private var openFailed = false

    init(path: String) {
        self.path = path
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: Writing

    func insert(_ command: FinishedCommand) {
        queue.async { [self] in
            guard let db = open() else { return }
            exec(
                db,
                """
                INSERT INTO history (cmd, cwd, exit, duration_ms, host, workspace_id, pane_id, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(command.command), .text(command.cwd), command.exitCode.map { .int(Int64($0)) } ?? .null,
                    .int(Int64((command.duration * 1000).rounded())), command.host.map { .text($0) } ?? .null,
                    .text(command.workspaceID.uuidString), .text(command.paneID.uuidString),
                    .real(command.startedAt.timeIntervalSince1970)
                ])
        }
    }

    /// Removes every run of `command`.
    func delete(command: String, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if let db = open() { exec(db, "DELETE FROM history WHERE cmd = ?", [.text(command)]) }
            completion?()
        }
    }

    func clear(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if let db = open() {
                exec(db, "DELETE FROM history", [])
                exec(db, "INSERT INTO history_fts(history_fts) VALUES ('rebuild')", [])
                exec(db, "VACUUM", [])
            }
            completion?()
        }
    }

    /// Drops entries started before `days` ago; 0 keeps everything.
    func prune(olderThanDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        queue.async { [self] in
            if let db = open() { exec(db, "DELETE FROM history WHERE started_at < ?", [.real(cutoff)]) }
        }
    }

    // MARK: Reading

    func search(_ filter: HistoryFilter, limit: Int = 200, now: Date = Date()) async -> [HistoryEntry] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: searchOnQueue(filter, limit: limit, now: now))
            }
        }
    }

    func count() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let db = open() else { return continuation.resume(returning: 0) }
                let rows = query(db, "SELECT COUNT(*) FROM history", []) { sqlite3_column_int64($0, 0) }
                continuation.resume(returning: Int(rows.first ?? 0))
            }
        }
    }

    /// Blocking; for tests and the palette's synchronous sources only.
    func searchSync(_ filter: HistoryFilter, limit: Int = 200, now: Date = Date()) -> [HistoryEntry] {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { searchOnQueue(filter, limit: limit, now: now) }
    }

    private func searchOnQueue(_ filter: HistoryFilter, limit: Int, now: Date) -> [HistoryEntry] {
        guard let db = open() else { return [] }
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        var entries: [HistoryEntry]
        if text.isEmpty {
            entries = candidates(db, filter, match: nil, limit: limit)
        } else {
            entries = candidates(db, filter, match: Self.ftsQuery(text), limit: 1000)
            // FTS matches tokens by prefix; a subsequence ("gcm" for "git
            // commit -m") needs the fuzzy pass over recent commands.
            if entries.isEmpty {
                entries = candidates(db, filter, match: nil, limit: 3000)
                    .filter { FuzzyMatcher.score(text, $0.command) != nil }
            }
        }
        return Array(
            Self.rank(entries, text: text, preferredCwd: filter.preferredCwd ?? filter.cwd, now: now).prefix(limit))
    }

    /// Ranks by fuzzy match, recency, frequency and a same-directory bonus.
    static func rank(_ entries: [HistoryEntry], text: String, preferredCwd: String?, now: Date) -> [HistoryEntry] {
        func score(_ e: HistoryEntry) -> Double {
            let age = max(0, now.timeIntervalSince(e.startedAt)) / 3600
            // Half-life of a week: yesterday's command beats last month's.
            var s = 100 * pow(0.5, age / 168)
            s += 12 * log2(Double(e.count) + 1)
            if let preferredCwd, e.cwd == preferredCwd { s += 40 }
            if !text.isEmpty, let match = FuzzyMatcher.score(text, e.command) { s += Double(match) / 10 }
            return s
        }
        return entries.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Each whitespace-separated token as a quoted prefix term.
    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }

    // MARK: SQLite

    private enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    /// Distinct commands, latest run first, with how often each ran.
    private func candidates(
        _ db: OpaquePointer, _ filter: HistoryFilter, match: String?, limit: Int
    )
        -> [HistoryEntry]
    {
        var conditions: [String] = []
        var values: [Value] = []
        if let match {
            conditions.append("h.id IN (SELECT rowid FROM history_fts WHERE history_fts MATCH ?)")
            values.append(.text(match))
        }
        if let workspaceID = filter.workspaceID {
            conditions.append("h.workspace_id = ?")
            values.append(.text(workspaceID.uuidString))
        }
        if filter.failedOnly { conditions.append("h.exit IS NOT NULL AND h.exit != 0") }
        if let host = filter.host {
            if let host {
                conditions.append("h.host = ?")
                values.append(.text(host))
            } else {
                conditions.append("h.host IS NULL")
            }
        }
        if let cwd = filter.cwd {
            conditions.append("h.cwd = ?")
            values.append(.text(cwd))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        // SQLite returns the other columns from the row holding MAX(started_at).
        let sql = """
            SELECT h.id, h.cmd, h.cwd, h.exit, h.duration_ms, h.host, h.workspace_id, h.pane_id,
                   MAX(h.started_at), COUNT(*)
            FROM history h \(whereClause)
            GROUP BY h.cmd ORDER BY MAX(h.started_at) DESC LIMIT \(limit)
            """
        return query(db, sql, values) { stmt in
            HistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                command: Self.text(stmt, 1) ?? "",
                cwd: Self.text(stmt, 2) ?? "",
                exitCode: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 3),
                durationMs: sqlite3_column_int64(stmt, 4),
                host: Self.text(stmt, 5),
                workspaceID: Self.text(stmt, 6).flatMap(UUID.init),
                paneID: Self.text(stmt, 7).flatMap(UUID.init),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                count: Int(sqlite3_column_int64(stmt, 9)))
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    /// Opens (and migrates) the database on first use. A failure disables
    /// history for the session rather than retrying on every command.
    private func open() -> OpaquePointer? {
        if let db { return db }
        guard !openFailed else { return nil }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            fail("open failed: \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?")")
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }
        let schema = """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY,
                cmd TEXT NOT NULL,
                cwd TEXT NOT NULL,
                exit INTEGER,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                host TEXT,
                workspace_id TEXT,
                pane_id TEXT,
                started_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS history_started ON history(started_at);
            CREATE INDEX IF NOT EXISTS history_cmd ON history(cmd);
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                cmd, content='history', content_rowid='id', tokenize='unicode61 tokenchars ''-_./'''
            );
            CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, cmd) VALUES (new.id, new.cmd);
            END;
            CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, cmd) VALUES ('delete', old.id, old.cmd);
            END;
            """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK else {
            fail("schema failed: \(error.map { String(cString: $0) } ?? "?")")
            sqlite3_free(error)
            sqlite3_close_v2(handle)
            return nil
        }
        db = handle
        return handle
    }

    private func fail(_ message: String) {
        openFailed = true
        booLog(.error, .app, "[History] \(message); history disabled")
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String, _ values: [Value]) -> Bool {
        guard let stmt = prepare(db, sql, values) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            booLog(.warning, .app, "[History] \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, _ values: [Value], row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = prepare(db, sql, values) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(row(stmt)) }
        return rows
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, _ values: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            booLog(.warning, .app, "[History] prepare: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        // SQLITE_TRANSIENT: SQLite copies the bound text.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .int(let i): sqlite3_bind_int64(stmt, index, i)
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }
}

/// Feeds finished commands into `HistoryStore`, minus ignored ones.
@MainActor
final class HistoryRecorder {
    static let shared = HistoryRecorder()

    private var subscription: Any?
    private var settingsObserver: Any?
    private var ignore: NSRegularExpression?

    func start() {
        guard subscription == nil else { return }
        compileIgnore()
        subscription = CommandLog.shared.finished.sink { [weak self] command in
            self?.record(command)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["topic"] as? String == SettingsTopic.history.rawValue else { return }
            MainActor.assumeIsolated { self?.compileIgnore() }
        }
        HistoryStore.shared.prune(olderThanDays: AppSettings.shared.historyRetentionDays)
    }

    nonisolated static func isIgnored(_ command: String, by regex: NSRegularExpression?) -> Bool {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let regex else { return false }
        return regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    private func record(_ command: FinishedCommand) {
        guard AppSettings.shared.historyEnabled, !Self.isIgnored(command.command, by: ignore) else { return }
        HistoryStore.shared.insert(command)
    }

    private func compileIgnore() {
        let pattern = AppSettings.shared.historyIgnorePattern
        if pattern.isEmpty {
            ignore = nil
        } else if let regex = try? NSRegularExpression(pattern: pattern) {
            ignore = regex
        } else {
            // A broken pattern falls back to the default rather than recording secrets.
            booLog(.warning, .app, "[History] invalid ignore pattern, using default")
            ignore = try? NSRegularExpression(pattern: AppSettings.defaultHistoryIgnorePattern)
        }
    }
}
