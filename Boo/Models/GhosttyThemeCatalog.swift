import Foundation

/// The theme files Ghostty bundles (several hundred), offered next to the
/// curated built-ins. Names are listed lazily from disk and each file is parsed
/// on first use, so the catalog costs nothing until the gallery or a saved
/// theme name asks for it.
final class GhosttyThemeCatalog: @unchecked Sendable {
    static let shared = GhosttyThemeCatalog()

    /// Where the theme files live.
    enum Source: Equatable {
        /// One file per theme, as Ghostty's own build lays them out.
        case directory(String)
        /// Every theme in one file, as `scripts/pack-ghostty-themes.sh` writes
        /// it for the app bundle: a line of `\u{1E}` plus the name starts each one.
        case pack(String)
    }

    private let lock = NSLock()
    private var cachedNames: [String]?
    /// Parse results by name; a nil value records a file that did not parse.
    private var parsed: [String: TerminalTheme?] = [:]
    /// Byte range of each theme's text in the pack, read once.
    private var packIndex: [String: Range<Int>]?
    private let source: Source?

    init(source: Source? = GhosttyThemeCatalog.defaultSource()) {
        self.source = source
    }

    convenience init(directory: String?) {
        self.init(source: directory.map(Source.directory))
    }

    /// The packed file when the resources have one, else the themes folder.
    static func defaultSource() -> Source? {
        guard
            let resources = GhosttyRuntime.resolveResourcesDir(
                execPath: Bundle.main.executablePath, bundleResourcePath: Bundle.main.resourcePath)
        else { return nil }
        let pack = resources + "/themes.pack"
        return FileManager.default.fileExists(atPath: pack) ? .pack(pack) : .directory(resources + "/themes")
    }

    /// Every theme name in the catalog, sorted, without the curated built-ins.
    var names: [String] {
        if let cached = lock.withLock({ cachedNames }) { return cached }
        let curated = Set(TerminalTheme.themes.map(\.name))
        let all: [String]
        switch source {
        case .directory(let directory): all = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        case .pack: all = Array(index().keys)
        case nil: all = []
        }
        let list = all.filter { !$0.hasPrefix(".") && !curated.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        lock.withLock { cachedNames = list }
        return list
    }

    /// The catalog theme named `name`, parsed on first use; nil when there is
    /// no such file or it does not parse.
    func theme(named name: String) -> TerminalTheme? {
        guard source != nil, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        if let hit = lock.withLock({ parsed[name] }) { return hit }

        let theme = text(of: name)
            .flatMap { try? ThemeImporter.parseGhostty($0, name: name) }?
            .toTheme(isCustom: false)
        lock.withLock { parsed[name] = .some(theme) }
        return theme
    }

    private func text(of name: String) -> String? {
        switch source {
        case .directory(let directory):
            return try? String(contentsOfFile: directory + "/" + name, encoding: .utf8)
        case .pack(let path):
            guard let range = index()[name],
                let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
                range.upperBound <= data.count
            else { return nil }
            return String(decoding: data[range], as: UTF8.self)
        case nil:
            return nil
        }
    }

    private func index() -> [String: Range<Int>] {
        if let hit = lock.withLock({ packIndex }) { return hit }
        var index: [String: Range<Int>] = [:]
        if case .pack(let path) = source,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        {
            index = Self.parsePack(data)
        }
        lock.withLock { packIndex = index }
        return index
    }

    /// Where each theme's text sits in a pack, by name.
    static func parsePack(_ data: Data) -> [String: Range<Int>] {
        let bytes = [UInt8](data)
        let separator: UInt8 = 0x1E
        let newline: UInt8 = 0x0A
        var starts: [Int] = []
        for i in bytes.indices where bytes[i] == separator && (i == 0 || bytes[i - 1] == newline) {
            starts.append(i)
        }
        var index: [String: Range<Int>] = [:]
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : bytes.count
            let nameEnd = bytes[start..<end].firstIndex(of: newline) ?? end
            let name = String(decoding: bytes[(start + 1)..<nameEnd], as: UTF8.self)
            guard !name.isEmpty else { continue }
            index[name] = min(nameEnd + 1, end)..<end
        }
        return index
    }
}
