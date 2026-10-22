import Foundation

/// Terminal post-processing shaders: the bundled presets and user GLSL files.
enum ShaderLibrary {
    /// Bundled presets, by name (`Resources/Shaders/<name>.glsl`).
    static let presets = ["crt", "bloom", "scanlines"]

    static func displayName(_ preset: String) -> String {
        switch preset {
        case "crt": return "CRT"
        case "bloom": return "Bloom"
        case "scanlines": return "Scanlines"
        default: return preset
        }
    }

    /// The GLSL file for `value`: a preset name or a path to a file. nil when
    /// empty or not found.
    static func path(for value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if presets.contains(value) {
            return BooResourceBundle.bundle.url(forResource: value, withExtension: "glsl", subdirectory: "Shaders")?
                .path
        }
        let path = (value as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            booLog(.warning, .app, "[Shader] not found: \(path)")
            return nil
        }
        return path
    }
}
