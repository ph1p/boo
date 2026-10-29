import Cocoa
import Foundation

// MARK: - Semantic Colors

/// Named semantic colors used across status bar, tab bar, and other chrome.
/// Avoids repeating hardcoded NSColor(calibratedRed:...) values.
///
/// These are theme-INDEPENDENT identity hues (a container is always "docker
/// blue" regardless of theme). For theme-ADAPTIVE status colors use the
/// `TerminalTheme` tokens instead: `theme.success` / `.warning` / `.error` /
/// `.info` (derived from the theme's ANSI palette).
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
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
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

    /// Leader-key tables: ~/.boo/keytables.json (absent = off).
    static let keyTablesFile = (configDir as NSString).appendingPathComponent("keytables.json")

    /// Context and output rules: ~/.boo/rules.json (absent = no rules).
    static let rulesFile = (configDir as NSString).appendingPathComponent("rules.json")

    /// Terminal profiles: ~/.boo/profiles.json (absent = none).
    static let profilesFile = (configDir as NSString).appendingPathComponent("profiles.json")

    /// Command history database: ~/.boo/history.db
    static let historyDB = (configDir as NSString).appendingPathComponent("history.db")

    /// Workspace notes: ~/.boo/notes/
    static let notesDir: String = {
        let path = (configDir as NSString).appendingPathComponent("notes")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Hashes of the files at the last sync: ~/.boo/sync-state.json
    static let syncStateFile = (configDir as NSString).appendingPathComponent("sync-state.json")

    /// Workspace recipes: ~/.boo/recipes/
    static let recipesDir: String = {
        let path = (configDir as NSString).appendingPathComponent("recipes")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Session recordings (asciicast): ~/.boo/recordings/
    static let recordingsDir: String = {
        let path = (configDir as NSString).appendingPathComponent("recordings")
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
    /// Also injects a source line into the user's shell RC files if not already present.
    static func installShellIntegration() {
        installMCPLauncher()
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
        injectShellRCLines()
        installClaudeHook()
    }

    /// `boo-mcp`: stable path for agents' MCP config that starts this app's
    /// binary as an MCP server (`Boo --mcp`), wherever the app lives.
    static var mcpLauncherPath: String {
        (shellIntegrationDir as NSString).appendingPathComponent("boo-mcp")
    }

    private static func installMCPLauncher() {
        // Only from a bundled app: a `swift run` binary moves with every build.
        guard Bundle.main.bundlePath.hasSuffix(".app"), let binary = Bundle.main.executablePath else { return }
        let quoted = "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\n# Written by Boo on every launch.\nexec \(quoted) --mcp \"$@\"\n"
        try? script.write(toFile: mcpLauncherPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcpLauncherPath)
    }

    /// Append a source line to each shell RC file that doesn't already have it.
    /// Uses a sentinel comment so it's never injected twice.
    private static func injectShellRCLines() {
        let home = NSHomeDirectory()
        let sentinel = "# Boo shell integration"
        let entries: [(rc: String, script: String)] = [
            (".zshrc", "boo.zsh"),
            (".bashrc", "boo.bash"),
            (".bash_profile", "boo.bash"),
            (".config/fish/config.fish", "boo.fish")
        ]
        for (rc, script) in entries {
            let rcPath = home.appendingPathComponent(rc)
            let scriptPath = shellIntegrationDir.appendingPathComponent(script)
            guard FileManager.default.fileExists(atPath: rcPath) else { continue }
            guard let existing = try? String(contentsOfFile: rcPath, encoding: .utf8),
                !existing.contains(sentinel)
            else { continue }
            let line: String
            if script.hasSuffix(".fish") {
                line = "\n\(sentinel)\nif test -f \"\(scriptPath)\"; source \"\(scriptPath)\"; end\n"
            } else {
                line = "\n\(sentinel)\n[ -f \"\(scriptPath)\" ] && source \"\(scriptPath)\"\n"
            }
            try? (existing + line).write(toFile: rcPath, atomically: true, encoding: .utf8)
        }
    }

    /// Claude Code events the agent hook reports to Boo's agent inbox.
    static let claudeHookEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// Register the agent hook in ~/.claude/settings.json so Boo sees when Claude
    /// works, waits for permission and finishes. Merges safely with existing
    /// hooks — never overwrites user entries.
    static func installClaudeHook() {
        let hookScript = shellIntegrationDir.appendingPathComponent("boo-claude-hook")
        let settingsPath = NSHomeDirectory().appendingPathComponent(".claude/settings.json")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let merged = mergingClaudeHook(command: hookScript, into: root),
            let updated = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? updated.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// `root` with the hook added for every event in `claudeHookEvents` that
    /// lacks it; nil when nothing changes.
    static func mergingClaudeHook(command: String, into root: [String: Any]) -> [String: Any]? {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in claudeHookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let present = entries.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == command } ?? false
            }
            guard !present else { continue }
            entries.append(["hooks": [["type": "command", "command": command, "timeout": 5, "async": true]]])
            hooks[event] = entries
            changed = true
        }
        guard changed else { return nil }
        var root = root
        root["hooks"] = hooks
        return root
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
        restrictConfigDir()
    }

    /// Makes `configDir` owner-only (0700). It holds shell history, session
    /// scrollback, recordings and logs, all created 0644 under the default
    /// umask; closing the directory covers every file in it, existing ones too.
    static func restrictConfigDir(_ dir: String = configDir) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir),
            let mode = attrs[.posixPermissions] as? Int, mode & 0o077 != 0
        else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    }
}
