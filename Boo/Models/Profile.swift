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
    /// "block", "beam", "underline" or "outline".
    var cursorStyle: String?
    /// "#RRGGBB" for the tab's accent line and badge; replaces the theme's accent.
    var tabColor: String?
    /// A short label shown next to the tab title.
    var badge: String?
    /// The profile whose fields fill the ones this profile leaves out.
    var basedOn: String?

    init(
        name: String, theme: String? = nil, fontFamily: String? = nil, fontSize: Double? = nil,
        shader: String? = nil, shell: String? = nil, env: [String: String]? = nil, cwd: String? = nil,
        linkTarget: LinkTarget? = nil, cursorStyle: String? = nil, tabColor: String? = nil,
        badge: String? = nil, basedOn: String? = nil
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
        self.cursorStyle = cursorStyle
        self.tabColor = tabColor
        self.badge = badge
        self.basedOn = basedOn
    }

    /// This profile with `parent`'s values in every field it leaves out.
    /// `env` merges per key; this profile's variables win.
    func filling(from parent: Profile) -> Profile {
        var p = self
        p.theme = theme ?? parent.theme
        p.fontFamily = fontFamily ?? parent.fontFamily
        p.fontSize = fontSize ?? parent.fontSize
        p.shader = shader ?? parent.shader
        p.shell = shell ?? parent.shell
        p.cwd = cwd ?? parent.cwd
        p.linkTarget = linkTarget ?? parent.linkTarget
        p.cursorStyle = cursorStyle ?? parent.cursorStyle
        p.tabColor = tabColor ?? parent.tabColor
        p.badge = badge ?? parent.badge
        if env != nil || parent.env != nil {
            p.env = (parent.env ?? [:]).merging(env ?? [:]) { _, own in own }
        }
        return p
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

/// Why a tab runs its profile.
enum ProfileSource: Equatable, Sendable {
    /// Picked by hand for the tab.
    case manual
    /// The rule with this id matched.
    case rule(String)
    case workspaceDefault
    case globalDefault
}

struct ProfileResolution: Equatable {
    var profile: Profile
    var source: ProfileSource
}

enum ProfileResolver {
    /// The profile a tab runs: its own pick, else the first matching rule,
    /// else the workspace default, else the global default. A name without a
    /// profile is skipped, so a deleted profile falls through to the next step.
    static func resolve(
        override: String?, ruleMatches: [RuleMatcher.ProfileMatch], workspaceDefault: String?,
        globalDefault: String?, profiles: [Profile]
    ) -> ProfileResolution? {
        var candidates: [(String, ProfileSource)] = []
        if let override { candidates.append((override, .manual)) }
        candidates += ruleMatches.map { ($0.name, .rule($0.ruleID)) }
        if let workspaceDefault { candidates.append((workspaceDefault, .workspaceDefault)) }
        if let globalDefault { candidates.append((globalDefault, .globalDefault)) }
        for (name, source) in candidates {
            if let profile = profiles.first(where: { $0.name == name }) {
                return ProfileResolution(profile: profile, source: source)
            }
        }
        return nil
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
            // A bad look value costs only that field, not the whole profile.
            if let style = p.cursorStyle, CursorStyle(profileValue: style) == nil {
                problems.append(
                    "profile \"\(name)\": \"cursorStyle\" must be block, beam, underline or outline, ignored")
                p.cursorStyle = nil
            }
            if let color = p.tabColor, NSColor(hex: color) == nil {
                problems.append("profile \"\(name)\": \"tabColor\" must look like \"#RRGGBB\", ignored")
                p.tabColor = nil
            }
            if p.badge?.trimmingCharacters(in: .whitespaces).isEmpty == true { p.badge = nil }
            profiles.append(p)
        }
        return (profiles, problems)
    }

    /// Fills every profile from its `basedOn` chain. A missing parent or a
    /// cycle is reported and that profile is used as written.
    static func resolve(_ profiles: [Profile]) -> (profiles: [Profile], problems: [String]) {
        let byName = Dictionary(profiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var problems: [String] = []
        var done: [String: Profile] = [:]
        // Profiles whose chain runs into a loop; none of them can be merged.
        var looped = Set<String>()

        func resolved(_ profile: Profile, path: [String]) -> Profile? {
            if looped.contains(profile.name) {
                looped.formUnion(path)
                return nil
            }
            if let hit = done[profile.name] { return hit }
            guard let parentName = profile.basedOn, !parentName.isEmpty else {
                done[profile.name] = profile
                return profile
            }
            // nil: the chain loops back, so nothing on it can be merged.
            guard !path.contains(parentName), parentName != profile.name else {
                looped.formUnion(path + [profile.name])
                return nil
            }
            guard let parent = byName[parentName] else {
                problems.append(
                    "profile \"\(profile.name)\": \"basedOn\" names \"\(parentName)\", which does not exist")
                done[profile.name] = profile
                return profile
            }
            guard let base = resolved(parent, path: path + [profile.name]) else { return nil }
            let merged = profile.filling(from: base)
            done[profile.name] = merged
            return merged
        }

        let result = profiles.map { profile -> Profile in
            if let merged = resolved(profile, path: []) { return merged }
            problems.append("profile \"\(profile.name)\": \"basedOn\" runs into a loop, ignored")
            return profile
        }
        return (result, problems)
    }
}

extension CursorStyle {
    /// The names a profile's `cursorStyle` accepts.
    static let profileValues: [(name: String, style: CursorStyle)] = [
        ("block", .block), ("beam", .beam), ("underline", .underline), ("outline", .blockOutline)
    ]

    init?(profileValue: String) {
        guard let hit = Self.profileValues.first(where: { $0.name == profileValue.lowercased() }) else { return nil }
        self = hit.style
    }
}

/// Profiles from `~/.boo/profiles.json`, reloaded when the file changes. A
/// file that fails to parse keeps the last good profiles.
@MainActor
final class ProfileStore {
    static let shared = ProfileStore(path: BooPaths.profilesFile)

    let path: String
    /// The profiles as written in the file; the editor works on these.
    private(set) var profiles: [Profile] = []
    /// The profiles with their `basedOn` chain filled in, by name.
    private var resolved: [String: Profile] = [:]
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

    /// The profile's `tabColor`, else the accent of its theme, for the tab
    /// bar; nil when it sets neither.
    func accent(forProfile name: String) -> NSColor? {
        if let cached = accents[name] { return cached }
        let profile = profile(named: name)
        let color =
            profile?.tabColor.flatMap { NSColor(hex: $0) }
            ?? profile?.theme.flatMap { AppSettings.shared.theme(named: $0) }?.accentColor
        accents[name] = color
        return color
    }

    var names: [String] { profiles.map(\.name) }

    /// A warning when the global default names a profile that is gone.
    var defaultProfileProblems: [String] {
        guard let name = AppSettings.shared.defaultProfile, profile(named: name) == nil else { return [] }
        return ["default profile \"\(name)\" does not exist, new tabs use the plain settings"]
    }

    /// Every profile with its `basedOn` chain filled in, in file order.
    var resolvedProfiles: [Profile] { profiles.compactMap { resolved[$0.name] } }

    /// The profile as tabs use it: `basedOn` filled in.
    func profile(named name: String?) -> Profile? {
        guard let name else { return nil }
        return resolved[name]
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

    private func update(profiles: [Profile], problems fileProblems: [String]) {
        let merged = ProfileFile.resolve(profiles)
        // A kept-after-parse-failure list already carries its chain problems.
        let problems = fileProblems + merged.problems.filter { !fileProblems.contains($0) }
        let changed = profiles != self.profiles || problems != self.problems
        accents.removeAll()
        self.profiles = profiles
        self.resolved = Dictionary(merged.profiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
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
