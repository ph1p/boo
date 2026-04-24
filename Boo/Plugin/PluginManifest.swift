import Foundation

/// Parsed plugin manifest from plugin.json.
/// ADR-4: Strict JSON Schema manifest validation.
struct PluginManifest: Codable {
    let id: String
    let name: String
    let version: String
    let icon: String
    let description: String?
    let when: String?
    let runtime: PluginRuntime?
    var capabilities: Capabilities?
    let statusBar: StatusBarManifest?
    let settings: [SettingManifest]?
    var menus: [MenuManifest]? = nil

    /// True for plugins loaded from ~/.boo/plugins/ (not decoded from JSON).
    var isExternal: Bool = false
    /// The folder name inside ~/.boo/plugins/ for external plugins (e.g. "my-plugin").
    var folderName: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, version, icon, description, when, runtime, capabilities, statusBar, settings, menus
    }

    struct Capabilities: Codable, Equatable {
        let statusBarSegment: Bool?
        var sidebarTab: Bool? = nil
    }

    enum PluginRuntime: String, Codable, Equatable {
        case js
    }

    struct StatusBarManifest: Codable, Equatable {
        let position: String?
        let priority: Int?
        let template: String?
        /// Click behavior: "showTab" (default) focuses the plugin's sidebar tab.
        var onClick: String? = nil
    }

    struct SettingManifest: Codable, Equatable {
        let key: String
        let type: SettingType
        let label: String
        var description: String? = nil
        let defaultValue: AnyCodableValue?
        let options: String?
        /// Optional section group label. Settings with the same group are rendered together
        /// under a shared section header in the plugin's settings page.
        var group: String? = nil
        var min: Double? = nil
        var max: Double? = nil
        var step: Double? = nil

        enum CodingKeys: String, CodingKey {
            case key, type, label, description, options, group, min, max, step
            case defaultValue = "default"
        }

        enum SettingType: String, Codable, Equatable {
            case bool
            case string
            case int
            case double
        }
    }

    /// A menu item or separator contributed by a plugin.
    struct MenuManifest: Codable, Equatable {
        let label: String?
        let action: String?
        let shortcut: String?
        let icon: String?
        var separator: Bool? = nil
    }
}

extension PluginManifest {
    /// Settings to show on the plugin's settings page. Bool settings are excluded for
    /// statusBarSegment plugins because they appear in Status Bar settings instead.
    var visibleSettings: [SettingManifest] {
        guard let settings else { return [] }
        if capabilities?.statusBarSegment == true {
            return settings.filter { $0.type != .bool }
        }
        return settings
    }
}

extension PluginManifest: Equatable {
    static func == (lhs: PluginManifest, rhs: PluginManifest) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.version == rhs.version
            && lhs.icon == rhs.icon && lhs.description == rhs.description
            && lhs.when == rhs.when && lhs.runtime == rhs.runtime
            && lhs.capabilities == rhs.capabilities && lhs.statusBar == rhs.statusBar
            && lhs.settings == rhs.settings && lhs.menus == rhs.menus
    }
}

/// Type-erased Codable value for settings defaults.
struct AnyCodableValue: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported setting value type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let b = value as? Bool {
            try container.encode(b)
        } else if let i = value as? Int {
            try container.encode(i)
        } else if let d = value as? Double {
            try container.encode(d)
        } else if let s = value as? String {
            try container.encode(s)
        }
    }

    static func == (lhs: AnyCodableValue, rhs: AnyCodableValue) -> Bool {
        if let l = lhs.value as? Bool, let r = rhs.value as? Bool { return l == r }
        if let l = lhs.value as? Int, let r = rhs.value as? Int { return l == r }
        if let l = lhs.value as? Double, let r = rhs.value as? Double { return l == r }
        if let l = lhs.value as? String, let r = rhs.value as? String { return l == r }
        return false
    }
}

// MARK: - Validation

extension PluginManifest {

    struct ValidationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Parse and validate a manifest from JSON data.
    static func parse(from data: Data) throws -> PluginManifest {
        let decoder = JSONDecoder()
        let manifest: PluginManifest
        do {
            manifest = try decoder.decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            throw ValidationError(message: formatDecodingError(error))
        }

        // Validate required fields
        if manifest.id.isEmpty {
            throw ValidationError(message: "Missing required field 'id'")
        }
        if manifest.name.isEmpty {
            throw ValidationError(message: "Missing required field 'name'")
        }
        if manifest.version.isEmpty {
            throw ValidationError(message: "Missing required field 'version'")
        }
        if manifest.icon.isEmpty {
            throw ValidationError(message: "Missing required field 'icon'")
        }

        return manifest
    }

    /// Parse from a JSON string.
    static func parse(from jsonString: String) throws -> PluginManifest {
        guard let data = jsonString.data(using: .utf8) else {
            throw ValidationError(message: "Invalid UTF-8 in manifest")
        }
        return try parse(from: data)
    }

    private static func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "Missing required field '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Type mismatch for '\(path)': expected \(type)"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Null value for '\(path)': expected \(type)"
        case .dataCorrupted(let context):
            return "Malformed JSON: \(context.debugDescription)"
        @unknown default:
            return "Parse error: \(error.localizedDescription)"
        }
    }
}
