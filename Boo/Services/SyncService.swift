import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted on the main queue when sync status or conflicts change.
    static let syncStatusChanged = Notification.Name("BooSyncStatusChanged")
}

/// What to do with one synced file, given its hash locally, in the sync
/// folder and at the last sync (nil = absent).
enum SyncAction: Equatable {
    case none
    case push
    case pull
    case deleteLocal
    case deleteRemote
    case conflict

    static func decide(local: String?, remote: String?, base: String?) -> SyncAction {
        if local == remote { return .none }
        let localChanged = local != base
        let remoteChanged = remote != base
        switch (localChanged, remoteChanged) {
        case (true, false): return local == nil ? .deleteRemote : .push
        case (false, true): return remote == nil ? .deleteLocal : .pull
        default:
            // Never synced, one side only: copy it over.
            if base == nil, local == nil { return .pull }
            if base == nil, remote == nil { return .push }
            return .conflict
        }
    }
}

/// One synced unit: a file under `~/.boo`, or the settings snapshot.
struct SyncItem: Hashable {
    enum Kind: Hashable {
        case file(local: String)
        case settings
    }

    /// Path relative to the sync folder; also the sync-state key.
    let name: String
    let kind: Kind
}

/// Hashes at the last sync, keyed by item name.
struct SyncState: Codable, Equatable {
    var hashes: [String: String] = [:]

    static func load(from path: String) -> SyncState {
        guard let data = FileManager.default.contents(atPath: path),
            let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    func save(to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Mirrors Boo's config with a folder (e.g. in iCloud Drive). Each round
/// compares local, remote and last-sync hashes per item: a one-sided change
/// is copied over, a two-sided change becomes a conflict for the user.
final class SyncEngine {
    struct Result: Equatable {
        var pushed: [String] = []
        var pulled: [String] = []
        var conflicts: [String] = []
        /// Remote items still being downloaded (`.icloud` placeholders).
        var pending: [String] = []
    }

    static let configFiles = ["profiles.json", "rules.json", "keytables.json", "snippets.json"]
    static let configDirs = ["themes", "recipes"]
    static let settingsName = "settings.json"

    let localDir: String
    let remoteDir: String
    let stateFile: String
    /// Current synced settings; nil skips settings (tests).
    var settingsSnapshot: (() -> [String: Any])?
    var applySettings: (([String: Any]) -> Void)?

    init(localDir: String, remoteDir: String, stateFile: String) {
        self.localDir = localDir
        self.remoteDir = remoteDir
        self.stateFile = stateFile
    }

    // MARK: - Items

    func items() -> [SyncItem] {
        var items: [SyncItem] = []
        if settingsSnapshot != nil { items.append(SyncItem(name: Self.settingsName, kind: .settings)) }
        for name in Self.configFiles {
            items.append(SyncItem(name: name, kind: .file(local: local(name))))
        }
        let state = SyncState.load(from: stateFile)
        for dir in Self.configDirs {
            var names = Set(files(in: local(dir)) + files(in: remote(dir)))
            // Deleted on both sides since the last sync still need their state dropped.
            names.formUnion(
                state.hashes.keys.filter { $0.hasPrefix(dir + "/") }.map { String($0.dropFirst(dir.count + 1)) })
            for name in names.sorted() {
                let rel = dir + "/" + name
                items.append(SyncItem(name: rel, kind: .file(local: local(rel))))
            }
        }
        return items
    }

    private func local(_ rel: String) -> String { (localDir as NSString).appendingPathComponent(rel) }
    private func remote(_ rel: String) -> String { (remoteDir as NSString).appendingPathComponent(rel) }

    /// Regular, visible files of a directory. `.name.icloud` placeholders
    /// count under their real name, so a file not yet downloaded isn't
    /// mistaken for a deletion.
    private func files(in dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { name in
            if let real = Self.placeholderTarget(name) { return real }
            guard !name.hasPrefix(".") else { return nil }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return isDir.boolValue ? nil : name
        }
    }

    /// "foo.json" for an iCloud placeholder named ".foo.json.icloud".
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private func isPlaceholder(_ rel: String) -> Bool {
        let path = remote(rel)
        let placeholder =
            ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("." + (path as NSString).lastPathComponent + ".icloud")
        return !FileManager.default.fileExists(atPath: path) && FileManager.default.fileExists(atPath: placeholder)
    }

    // MARK: - Content

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical settings bytes: sorted keys, so equal settings hash equal.
    static func settingsData(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    func localData(_ item: SyncItem) -> Data? {
        switch item.kind {
        case .settings: return settingsSnapshot.flatMap { Self.settingsData($0()) }
        case .file(let path): return FileManager.default.contents(atPath: path)
        }
    }

    /// Remote bytes; settings are re-serialized canonically so formatting
    /// differences don't count as a change.
    func remoteData(_ item: SyncItem) -> Data? {
        guard let data = FileManager.default.contents(atPath: remote(item.name)) else { return nil }
        guard item.kind == .settings else { return data }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        return Self.settingsData(dict) ?? data
    }

    private func writeRemote(_ item: SyncItem, _ data: Data) throws {
        let path = remote(item.name)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func writeLocal(_ item: SyncItem, _ data: Data) throws {
        switch item.kind {
        case .settings:
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            applySettings?(dict)
        case .file(let path):
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: - Round

    /// One sync round. Conflicting items are left alone (state unchanged).
    func run() -> Result {
        var state = SyncState.load(from: stateFile)
        var result = Result()
        for item in items() {
            if isPlaceholder(item.name) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: remote(item.name)))
                result.pending.append(item.name)
                continue
            }
            let localData = localData(item)
            let remoteData = remoteData(item)
            let localHash = localData.map(Self.hash)
            let remoteHash = remoteData.map(Self.hash)
            do {
                switch SyncAction.decide(local: localHash, remote: remoteHash, base: state.hashes[item.name]) {
                case .none:
                    state.hashes[item.name] = localHash
                case .push:
                    try writeRemote(item, localData!)
                    state.hashes[item.name] = localHash
                    result.pushed.append(item.name)
                case .pull:
                    try writeLocal(item, remoteData!)
                    state.hashes[item.name] = remoteHash
                    result.pulled.append(item.name)
                case .deleteRemote:
                    try FileManager.default.removeItem(atPath: remote(item.name))
                    state.hashes[item.name] = nil
                    result.pushed.append(item.name)
                case .deleteLocal:
                    if case .file(let path) = item.kind { try FileManager.default.removeItem(atPath: path) }
                    state.hashes[item.name] = nil
                    result.pulled.append(item.name)
                case .conflict:
                    result.conflicts.append(item.name)
                }
            } catch {
                debugLog("[Sync] \(item.name): \(error.localizedDescription)")
            }
        }
        state.save(to: stateFile)
        return result
    }

    /// Resolves a conflict: `keepLocal` pushes ours, else pulls theirs.
    func resolve(_ name: String, keepLocal: Bool) throws {
        guard let item = items().first(where: { $0.name == name }) else { return }
        var state = SyncState.load(from: stateFile)
        if keepLocal {
            if let data = localData(item) {
                try writeRemote(item, data)
                state.hashes[name] = Self.hash(data)
            } else {
                try? FileManager.default.removeItem(atPath: remote(name))
                state.hashes[name] = nil
            }
        } else {
            if let data = remoteData(item) {
                try writeLocal(item, data)
                state.hashes[name] = Self.hash(data)
            } else {
                if case .file(let path) = item.kind { try? FileManager.default.removeItem(atPath: path) }
                state.hashes[name] = nil
            }
        }
        state.save(to: stateFile)
    }

    /// Local and remote copies as files, for a diff.
    func diffFiles(_ name: String) -> (local: String, remote: String)? {
        guard let item = items().first(where: { $0.name == name }) else { return nil }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("boo-sync-diff")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "_")
        let localPath = (dir as NSString).appendingPathComponent("mine-" + base)
        let remotePath = (dir as NSString).appendingPathComponent("theirs-" + base)
        FileManager.default.createFile(atPath: localPath, contents: localData(item) ?? Data())
        FileManager.default.createFile(atPath: remotePath, contents: remoteData(item) ?? Data())
        return (localPath, remotePath)
    }
}

/// Runs the sync engine against `AppSettings.syncFolder`: on launch, when
/// the folder setting changes, and 1 s after local or remote changes.
@MainActor
final class SyncService {
    static let shared = SyncService()

    private(set) var conflicts: [String] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    private var engine: SyncEngine?
    private var remoteWatcher: FileSystemWatcher?
    private var localWatcher: FileSystemWatcher?
    private let debouncer = Debouncer(delay: 1)
    private var settingsObserver: NSObjectProtocol?
    private var folder = ""
    /// Our own writes echo through the watchers; ignore events while applying.
    private var isSyncing = false

    private init() {}

    var isEnabled: Bool { !folder.isEmpty }

    func start() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] note in
            let topic = note.userInfo?["topic"] as? String
            MainActor.assumeIsolated {
                guard let self, !self.isSyncing else { return }
                if topic == SettingsTopic.sync.rawValue || AppSettings.shared.syncFolder != self.folder {
                    self.configure()
                } else {
                    self.scheduleSync()
                }
            }
        }
        configure()
    }

    private func configure() {
        let folder = AppSettings.shared.syncFolder
        guard folder != self.folder || engine == nil else { return }
        self.folder = folder
        remoteWatcher?.stop()
        localWatcher?.stop()
        remoteWatcher = nil
        localWatcher = nil
        conflicts = []
        lastError = nil
        guard !folder.isEmpty else {
            engine = nil
            post()
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            engine = nil
            lastError = "Sync folder unavailable: \(error.localizedDescription)"
            post()
            return
        }
        let engine = SyncEngine(localDir: BooPaths.configDir, remoteDir: folder, stateFile: BooPaths.syncStateFile)
        engine.settingsSnapshot = { AppSettings.shared.syncSnapshot() }
        engine.applySettings = { AppSettings.shared.applySyncSnapshot($0) }
        self.engine = engine

        remoteWatcher = FileSystemWatcher(path: folder) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        let synced = Set(SyncEngine.configFiles + SyncEngine.configDirs)
        let configDir = (BooPaths.configDir as NSString).standardizingPath
        localWatcher = FileSystemWatcher(
            path: BooPaths.configDir,
            filter: { path in
                // First component under ~/.boo (FSEvents may report /private paths).
                guard let range = path.range(of: configDir + "/") else { return false }
                let rel = path[range.upperBound...]
                return synced.contains(String(rel.split(separator: "/").first ?? ""))
            }
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        remoteWatcher?.start()
        localWatcher?.start()
        syncNow()
    }

    private func scheduleSync() {
        guard engine != nil, !isSyncing else { return }
        debouncer.schedule { [weak self] in self?.syncNow() }
    }

    func syncNow() {
        guard let engine else { return }
        isSyncing = true
        let result = engine.run()
        reloadPulled(result.pulled)
        conflicts = result.conflicts
        lastSync = Date()
        lastError = nil
        // Let the watchers' echo of our own writes pass before listening again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.isSyncing = false }
        }
        post()
        if !result.pulled.isEmpty {
            debugLog("[Sync] pulled \(result.pulled.joined(separator: ", "))")
        }
    }

    func resolve(_ name: String, keepLocal: Bool) {
        guard let engine else { return }
        isSyncing = true
        do {
            try engine.resolve(name, keepLocal: keepLocal)
            if !keepLocal { reloadPulled([name]) }
            conflicts.removeAll { $0 == name }
        } catch {
            BooAlert.showTransient("Could not resolve \(name): \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.isSyncing = false }
        }
        post()
    }

    /// Shows mine vs theirs with `git diff --no-index` in a new tab.
    func openDiff(_ name: String) {
        guard let files = engine?.diffFiles(name) else { return }
        WindowManager.shared.activeController?.openCommandTab(
            "git --no-pager diff --no-index -- \(RemoteExplorer.shellEscPath(files.local)) "
                + RemoteExplorer.shellEscPath(files.remote))
    }

    /// Files written by profile/rules stores reload through their own
    /// watchers; these need a nudge.
    private func reloadPulled(_ names: [String]) {
        if names.contains("keytables.json") { KeyTables.shared.reloadIfChanged() }
        if names.contains("snippets.json") { SnippetService.shared.reload() }
    }

    private func post() {
        NotificationCenter.default.post(name: .syncStatusChanged, object: nil)
    }
}
