import AppKit

extension Notification.Name {
    /// `~/.boo/profiles.json` was (re)loaded.
    static let profilesChanged = Notification.Name("BooProfilesChanged")
}

/// A named overlay on the global settings, applied to one tab's terminal.
/// Every nil field inherits `AppSettings`.
struct Profile: Codable, Equatable, Sendable {
    var name: String
    /// A theme name from Settings → Theme (built-in or custom).
    var theme: String?
    var fontFamily: String?
    var fontSize: Double?
    /// A shader preset name or a path to a GLSL file; "" turns the global shader off.
    var shader: String?
    /// Runs instead of the login shell in new tabs.
    var shell: String?
    var env: [String: String]?
    /// Starting directory for new tabs.
    var cwd: String?
    var linkTarget: LinkTarget?

    init(
        name: String, theme: String? = nil, fontFamily: String? = nil, fontSize: Double? = nil,
        shader: String? = nil, shell: String? = nil, env: [String: String]? = nil, cwd: String? = nil,
        linkTarget: LinkTarget? = nil
    ) {
        self.name = name
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.shader = shader
        self.shell = shell
        self.env = env
        self.cwd = cwd
        self.linkTarget = linkTarget
    }

    /// Whether the profile changes how the surface looks (needs its own config).
    var changesSurface: Bool {
        theme != nil || fontFamily != nil || fontSize != nil || shader != nil
    }

    /// What a new tab with this profile starts with; nil when it changes nothing.
    func launchSpec(merging base: LaunchSpec?) -> LaunchSpec? {
        guard shell != nil || cwd != nil || !(env ?? [:]).isEmpty else { return base }
        var spec = base ?? LaunchSpec()
        if spec.program == nil, let shell, !shell.isEmpty { spec.program = shell }
        if spec.cwd == nil, let cwd, !cwd.isEmpty { spec.cwd = (cwd as NSString).expandingTildeInPath }
        // The launch's own variables win over the profile's.
        spec.env = (env ?? [:]).merging(spec.env) { _, own in own }
        return spec
    }
}

struct ProfileFile: Codable, Equatable {
    var profiles: [Profile]

    /// Parses `{"profiles": [...]}`. Unnamed and duplicate profiles are dropped
    /// and reported.
    static func parse(_ data: Data) throws -> (profiles: [Profile], problems: [String]) {
        let file = try JSONDecoder().decode(ProfileFile.self, from: data)
        var seen = Set<String>()
        var problems: [String] = []
        var profiles: [Profile] = []
        for (index, profile) in file.profiles.enumerated() {
            let name = profile.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                problems.append("profile #\(index + 1): missing \"name\"")
                continue
            }
            guard seen.insert(name).inserted else {
                problems.append("profile \"\(name)\": duplicate name, ignored")
                continue
            }
            if let size = profile.fontSize, !(4...200).contains(size) {
                problems.append("profile \"\(name)\": \"fontSize\" must be between 4 and 200")
                continue
            }
            var p = profile
            p.name = name
            profiles.append(p)
        }
        return (profiles, problems)
    }
}

/// Profiles from `~/.boo/profiles.json`, reloaded when the file changes. A
/// file that fails to parse keeps the last good profiles.
@MainActor
final class ProfileStore {
    static let shared = ProfileStore(path: BooPaths.profilesFile)

    let path: String
    private(set) var profiles: [Profile] = []
    /// Why the file (or some of its entries) couldn't be used; empty when fine.
    private(set) var problems: [String] = []
    private let file: WatchedFile
    private var started = false
    /// Tab accents by profile name; tab bars read them on every draw.
    private var accents: [String: NSColor?] = [:]
    nonisolated(unsafe) private var themeObserver: Any?

    init(path: String) {
        self.path = path
        self.file = WatchedFile(path: path)
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
        file.start { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Custom themes can be edited under a profile that names them.
        themeObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["topic"] as? String == SettingsTopic.theme.rawValue else { return }
            MainActor.assumeIsolated { self?.accents.removeAll() }
        }
    }

    /// The accent of the profile's theme, for the tab bar; nil without a theme.
    func accent(forProfile name: String) -> NSColor? {
        if let cached = accents[name] { return cached }
        let color = profile(named: name)?.theme.flatMap { AppSettings.shared.theme(named: $0) }?.accentColor
        accents[name] = color
        return color
    }

    var names: [String] { profiles.map(\.name) }

    func profile(named name: String?) -> Profile? {
        guard let name else { return nil }
        return profiles.first { $0.name == name }
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: path) else {
            update(profiles: [], problems: [])
            return
        }
        do {
            let parsed = try ProfileFile.parse(data)
            update(profiles: parsed.profiles, problems: parsed.problems)
        } catch {
            // Keep what worked last time; the settings page shows why.
            update(profiles: profiles, problems: ["the file is not valid profiles JSON: \(Self.describe(error))"])
        }
    }

    /// Writes `profiles` to the file and applies them.
    func save(_ profiles: [Profile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ProfileFile(profiles: profiles))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        file.noteOwnWrite()
        reload()
    }

    private func update(profiles: [Profile], problems: [String]) {
        let changed = profiles != self.profiles || problems != self.problems
        accents.removeAll()
        self.profiles = profiles
        self.problems = problems
        if !problems.isEmpty { booLog(.warning, .app, "[Profiles] \(problems.joined(separator: "; "))") }
        if changed { NotificationCenter.default.post(name: .profilesChanged, object: nil) }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return ctx.codingPath.map(\.stringValue).joined(separator: ".") + ": wrong type"
        case DecodingError.dataCorrupted: return "not JSON"
        default: return error.localizedDescription
        }
    }
}
