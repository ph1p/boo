import Foundation

/// Locates CLI binaries across common installation directories.
/// Used by plugins to check whether their external prerequisites are installed.
enum BinaryScanner {
    /// Search directories in order: process PATH first, then common fallbacks.
    /// Computed once at launch — nonisolated-safe, no actor state.
    static let searchPaths: [String] = {
        var dirs: [String] = []
        let home: String
        if let h = getenv("HOME"), !String(cString: h).isEmpty {
            home = String(cString: h)
        } else {
            home = NSHomeDirectory()
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        let extras: [String] = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/bin",
            "/bin",
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent(".cargo/bin"),
            (home as NSString).appendingPathComponent(".bun/bin"),
            (home as NSString).appendingPathComponent(".volta/bin"),
            (home as NSString).appendingPathComponent(".nvm/current/bin")
        ]
        for d in extras where !dirs.contains(d) {
            dirs.append(d)
        }
        return dirs
    }()

    /// Returns true if `binary` is found as an executable in any of `searchPaths`.
    static func isInstalled(_ binary: String) -> Bool {
        let fm = FileManager.default
        return searchPaths.contains { dir in
            fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(binary))
        }
    }
}
