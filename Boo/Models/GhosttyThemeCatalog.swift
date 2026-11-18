import Foundation

/// The theme files Ghostty bundles (several hundred), offered next to the
/// curated built-ins. Names are listed lazily from disk and each file is parsed
/// on first use, so the catalog costs nothing until the gallery or a saved
/// theme name asks for it.
final class GhosttyThemeCatalog: @unchecked Sendable {
    static let shared = GhosttyThemeCatalog()

    private let lock = NSLock()
    private var cachedNames: [String]?
    /// Parse results by name; a nil value records a file that did not parse.
    private var parsed: [String: TerminalTheme?] = [:]
    private let directory: String?

    init(directory: String? = GhosttyThemeCatalog.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> String? {
        GhosttyRuntime.resolveResourcesDir(
            execPath: Bundle.main.executablePath, bundleResourcePath: Bundle.main.resourcePath
        ).map { $0 + "/themes" }
    }

    /// Every theme name in the catalog, sorted, without the curated built-ins.
    var names: [String] {
        if let cached = lock.withLock({ cachedNames }) { return cached }
        let curated = Set(TerminalTheme.themes.map(\.name))
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0) } ?? []
        let list = files.filter { !$0.hasPrefix(".") && !curated.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        lock.withLock { cachedNames = list }
        return list
    }

    /// The catalog theme named `name`, parsed on first use; nil when there is
    /// no such file or it does not parse.
    func theme(named name: String) -> TerminalTheme? {
        guard let directory, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        if let hit = lock.withLock({ parsed[name] }) { return hit }

        let theme = (try? String(contentsOfFile: directory + "/" + name, encoding: .utf8))
            .flatMap { try? ThemeImporter.parseGhostty($0, name: name) }?
            .toTheme(isCustom: false)
        lock.withLock { parsed[name] = .some(theme) }
        return theme
    }
}
