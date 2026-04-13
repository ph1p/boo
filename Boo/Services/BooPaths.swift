import Cocoa
import Foundation

// MARK: - Semantic Colors

/// Named semantic colors used across status bar, tab bar, and other chrome.
/// Avoids repeating hardcoded NSColor(calibratedRed:...) values.
extension NSColor {
    /// SSH / remote session indicator (warm orange).
    static let booRemote = NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0)
    /// Docker / container indicator (blue).
    static let booDocker = NSColor(calibratedRed: 0.13, green: 0.59, blue: 0.95, alpha: 1.0)
    /// Local / success / added indicator (green).
    static let booLocal = NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.31, alpha: 1.0)
    /// Deleted / destructive (red).
    static let booDeleted = NSColor(calibratedRed: 0.97, green: 0.32, blue: 0.29, alpha: 1.0)
    /// Neutral / unknown state (gray).
    static let booNeutral = NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
}

// MARK: - String Path Helpers

extension String {
    /// Last path component without NSString bridging at the call site.
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }

    /// Parent directory without NSString bridging at the call site.
    var deletingLastPathComponent: String {
        (self as NSString).deletingLastPathComponent
    }

    /// Append a path component without NSString bridging at the call site.
    func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}

// MARK: - Path Abbreviation

private let _homeDir = FileManager.default.homeDirectoryForCurrentUser.path

/// Abbreviate a path by replacing the home directory with `~`.
func abbreviatePath(_ path: String) -> String {
    if path.hasPrefix(_homeDir) {
        return "~" + path.dropFirst(_homeDir.count)
    }
    return path
}

// MARK: - BooPaths

/// Central path management. All Boo data lives in ~/.boo/
enum BooPaths {
    /// Base config directory: ~/.boo/
    static let configDir: String = {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".boo")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Settings file: ~/.boo/settings.json
    static let settingsFile = (configDir as NSString).appendingPathComponent("settings.json")

    /// Bookmarks file: ~/.boo/bookmarks.json
    static let bookmarksFile = (configDir as NSString).appendingPathComponent("bookmarks.json")

    /// Ghostty config override: ~/.boo/ghostty.conf
    static let ghosttyConfigFile = (configDir as NSString).appendingPathComponent("ghostty.conf")

    /// Themes directory: ~/.boo/themes/
    static let themesDir: String = {
        let path = (configDir as NSString).appendingPathComponent("themes")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Logs directory: ~/.boo/logs/
    static let logsDir: String = {
        let path = (configDir as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Shell integration scripts directory: ~/.boo/shell-integration/
    static let shellIntegrationDir: String = {
        let path = (configDir as NSString).appendingPathComponent("shell-integration")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// SSH sockets directory: ~/.boo/ssh-sockets/
    static let sshSocketsDir: String = {
        let path = (configDir as NSString).appendingPathComponent("ssh-sockets")
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }()

    /// Copy bundled shell-integration scripts to ~/.boo/shell-integration/.
    /// Called once at startup. Overwrites stale copies so scripts stay up-to-date.
    static func installShellIntegration() {
        guard let resourcesDir = Bundle.main.resourcePath else { return }
        let sourceDir = (resourcesDir as NSString).appendingPathComponent("shell-integration")
        let fm = FileManager.default
        guard let scripts = try? fm.contentsOfDirectory(atPath: sourceDir) else { return }
        for script in scripts {
            let src = (sourceDir as NSString).appendingPathComponent(script)
            let dst = (shellIntegrationDir as NSString).appendingPathComponent(script)
            try? fm.removeItem(atPath: dst)
            try? fm.copyItem(atPath: src, toPath: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
        }
    }

    /// Verify that all critical directories exist and are writable.
    /// Call once at startup; throws on the first directory that cannot be created.
    static func ensureDirectories() throws {
        let fm = FileManager.default
        let dirs = [configDir, themesDir, logsDir, sshSocketsDir, shellIntegrationDir]
        for dir in dirs {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                // Verify writable.
                if !fm.isWritableFile(atPath: dir) {
                    throw CocoaError(
                        .fileWriteNoPermission,
                        userInfo: [NSFilePathErrorKey: dir])
                }
                continue
            }
            // Attempt creation (the lazy lets already tried, but may have silently failed).
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}
