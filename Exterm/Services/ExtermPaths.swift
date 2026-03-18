import Foundation

/// Central path management. All Exterm data lives in ~/.exterm/
enum ExtermPaths {
    /// Base config directory: ~/.exterm/
    static let configDir: String = {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".exterm")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Settings file: ~/.exterm/settings.json
    static let settingsFile = (configDir as NSString).appendingPathComponent("settings.json")

    /// Bookmarks file: ~/.exterm/bookmarks.json
    static let bookmarksFile = (configDir as NSString).appendingPathComponent("bookmarks.json")

    /// Ghostty config override: ~/.exterm/ghostty.conf
    static let ghosttyConfigFile = (configDir as NSString).appendingPathComponent("ghostty.conf")

    /// Themes directory: ~/.exterm/themes/
    static let themesDir: String = {
        let path = (configDir as NSString).appendingPathComponent("themes")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Logs directory: ~/.exterm/logs/
    static let logsDir: String = {
        let path = (configDir as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Shell integration directory: ~/.exterm/shell-integration/
    static let shellIntegrationDir: String = {
        let path = (configDir as NSString).appendingPathComponent("shell-integration")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()
}
