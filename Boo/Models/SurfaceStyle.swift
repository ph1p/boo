import Foundation

/// How one terminal surface differs from the global look. A profile's field
/// wins over the workspace's; a nil field follows `AppSettings`.
struct SurfaceStyle: Hashable, Sendable {
    var theme: String?
    /// Replaces `theme` while Boo follows a light system appearance.
    var lightTheme: String?
    var fontFamily: String?
    var fontSize: Double?
    /// A shader preset name or a path; "" turns the global shader off.
    var shader: String?

    init(profile: Profile?, workspace: WorkspaceSettings?) {
        theme = profile?.theme ?? workspace?.themeName
        // A profile's theme is one fixed theme, whatever the appearance.
        lightTheme = profile?.theme == nil ? workspace?.lightThemeName : nil
        fontFamily = profile?.fontFamily ?? workspace?.fontName
        fontSize = profile?.fontSize ?? workspace?.fontSize
        shader = profile?.shader
    }

    /// Nothing differs: the surface can share the global config.
    var isDefault: Bool { self == SurfaceStyle(profile: nil, workspace: nil) }

    func themeName(lightAppearance: Bool) -> String? {
        (lightAppearance ? lightTheme : nil) ?? theme
    }

    /// Names the config file written for this style.
    var cacheKey: String {
        [theme, lightTheme, fontFamily, fontSize.map { "\($0)" }, shader]
            .map { $0 ?? "\u{1}" }.joined(separator: "\u{0}")
    }
}
