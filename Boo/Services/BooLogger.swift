import Foundation
import os

/// Unified logging system for Boo.
///
/// Replaces the three-tier approach (NSLog, debugLog, os.log) with a single
/// interface that writes to both the system unified log and a rotating file log.
///
/// Usage:
/// ```swift
/// BooLogger.shared.log(.info, .terminal, "Shell PID discovered: \(pid)")
/// BooLogger.shared.log(.debug, .sidebar, "Section heights loaded")
/// BooLogger.shared.log(.warning, .git, "Branch detection failed, using fallback")
/// BooLogger.shared.log(.error, .socket, "Failed to bind socket: \(err)")
/// ```
final class BooLogger: @unchecked Sendable {
    static let shared = BooLogger()

    // MARK: - Types

    enum Category: String, CaseIterable {
        case app = "App"
        case terminal = "Terminal"
        case plugin = "Plugin"
        case sidebar = "Sidebar"
        case socket = "Socket"
        case git = "Git"
    }

    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var prefix: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO "
            case .warning: return "WARN "
            case .error: return "ERROR"
            }
        }

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    // MARK: - State

    /// Minimum level to log. Controlled by AppSettings.debugLogging.
    var minLevel: Level = .info

    private let subsystem = "com.boo"
    private let osLoggers: [String: Logger]
    private let fileWriter: LogFileWriter

    // MARK: - Initialization

    private init() {
        var loggers: [String: Logger] = [:]
        for category in Category.allCases {
            loggers[category.rawValue] = Logger(subsystem: "com.boo", category: category.rawValue)
        }
        self.osLoggers = loggers
        self.fileWriter = LogFileWriter(logsDir: BooPaths.logsDir)
    }

    // MARK: - Public API

    /// Log a message at the given level and category.
    func log(_ level: Level, _ category: Category, _ message: @autoclosure () -> String) {
        guard level >= minLevel else { return }
        let msg = message()
        let logger = osLoggers[category.rawValue]

        switch level {
        case .debug: logger?.debug("\(msg, privacy: .public)")
        case .info: logger?.info("\(msg, privacy: .public)")
        case .warning: logger?.warning("\(msg, privacy: .public)")
        case .error: logger?.error("\(msg, privacy: .public)")
        }

        let formatted = formatLine(level: level, category: category, message: msg)
        fileWriter.write(formatted)
    }

    // MARK: - Settings Integration

    /// Call when AppSettings.debugLogging changes.
    func applyDebugSetting(_ debugEnabled: Bool) {
        minLevel = debugEnabled ? .debug : .info
    }

    // MARK: - Private

    private func formatLine(level: Level, category: Category, message: String) -> String {
        let ts = LogFileWriter.timestamp()
        return "[\(ts)] [\(level.prefix)] [\(category.rawValue.uppercased())] \(message)\n"
    }
}

// MARK: - Log File Writer

/// Handles file I/O for BooLogger on a dedicated background queue.
/// Not actor-isolated — all mutable state is protected by the serial queue.
private final class LogFileWriter: @unchecked Sendable {
    private let logsDir: String
    private let queue = DispatchQueue(label: "com.boo.logger.file", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentDate: String = ""
    private let maxLogAgeDays = 7

    init(logsDir: String) {
        self.logsDir = logsDir
        queue.async { [weak self] in self?.rotateIfNeeded() }
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.rotateIfNeeded()
            self?.fileHandle?.write(data)
        }
    }

    private func rotateIfNeeded() {
        let today = Self.dateString()
        guard today != currentDate else { return }
        currentDate = today

        fileHandle?.closeFile()
        fileHandle = nil

        let filename = "boo-\(today).log"
        let path = (logsDir as NSString).appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()

        pruneOldLogs()
    }

    private func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDir) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxLogAgeDays, to: Date()) ?? Date()
        for file in files where file.hasPrefix("boo-") && file.hasSuffix(".log") {
            let fullPath = (logsDir as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                let modDate = attrs[.modificationDate] as? Date,
                modDate < cutoff
            {
                try? fm.removeItem(atPath: fullPath)
            }
        }
    }

    private static let timestampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func timestamp() -> String { timestampFmt.string(from: Date()) }
    private static func dateString() -> String { dateFmt.string(from: Date()) }
}

// MARK: - Convenience functions

/// Drop-in replacement for debugLog() — routes through BooLogger at .debug level.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String, category: BooLogger.Category = .app) {
    BooLogger.shared.log(.debug, category, message())
}

/// Log at a specific level and category. Drop-in for NSLog patterns.
@inline(__always)
func booLog(
    _ level: BooLogger.Level = .info, _ category: BooLogger.Category = .app, _ message: @autoclosure () -> String
) {
    BooLogger.shared.log(level, category, message())
}
