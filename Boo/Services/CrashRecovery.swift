import Foundation

/// The agent a terminal tab ran when the session was saved: enough to start
/// the same conversation again in a restored tab.
struct AgentResumePoint: Codable, Sendable, Equatable {
    /// `AgentKind.rawValue`.
    let kind: String
    let sessionID: String
    /// The agent's working directory; agents look sessions up per project.
    let cwd: String?

    init(kind: AgentKind, sessionID: String, cwd: String?) {
        self.kind = kind.rawValue
        self.sessionID = sessionID
        self.cwd = cwd
    }

    /// The shell command that reopens this session; nil for agents Boo can't resume.
    var command: String? {
        AgentKind(rawValue: kind)?.resumeCommand(sessionID: sessionID)
    }
}

extension AgentKind {
    /// The command that reopens session `sessionID`; nil for `.custom`.
    func resumeCommand(sessionID: String) -> String? {
        let id = shellEscape(sessionID)
        switch self {
        case .claudeCode: return "claude --resume \(id)"
        case .codex: return "codex resume \(id)"
        case .openCode: return "opencode --session \(id)"
        case .custom: return nil
        }
    }
}

/// Tells a crash from a normal quit. Each running Boo keeps a file named
/// after its PID in `~/.boo/run/` and deletes it on a normal quit; a file
/// whose process is gone at launch means that run crashed or was killed.
/// Per-PID files keep a second Boo (a dev build) from looking like a crash.
enum CrashRecovery {
    nonisolated(unsafe) static var _testDirectory: String?
    static var directory: String {
        _testDirectory ?? (BooPaths.configDir as NSString).appendingPathComponent("run")
    }

    /// Where Ghostty's crash handler writes its reports.
    static let ghosttyCrashDirectory = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/state/ghostty/crash")

    /// Set by `markLaunch`: the previous run ended without a normal quit.
    nonisolated(unsafe) private(set) static var previousRunCrashed = false

    /// Records this run and reports whether an earlier one crashed. Call once, early.
    @discardableResult
    static func markLaunch(pid: pid_t = getpid(), isAlive: (pid_t) -> Bool = processIsAlive) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var crashedAt: Date?
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
            guard let other = pid_t(name), other != pid, !isAlive(other) else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            let started = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            crashedAt = max(crashedAt ?? started, started)
            try? fm.removeItem(atPath: path)
        }
        fm.createFile(atPath: path(for: pid), contents: Data())
        previousRunCrashed = crashedAt != nil
        if let crashedAt {
            let report = latestGhosttyCrashReport(since: crashedAt)
            booLog(
                .warning, .app,
                "Previous run ended without quitting (crash or force quit)"
                    + (report.map { "; crash report: \($0)" } ?? ""))
        }
        return previousRunCrashed
    }

    /// Call on a normal quit, after the session is saved.
    static func markCleanExit(pid: pid_t = getpid()) {
        try? FileManager.default.removeItem(atPath: path(for: pid))
    }

    /// Whether agents saved in the session should start again at this launch.
    static func shouldResumeAgents(settings: AppSettings = .shared) -> Bool {
        guard settings.agentRecovery != .off else { return false }
        return previousRunCrashed || settings.resumeAgentsAfterQuit
    }

    // MARK: - Resume

    /// Set while the launch session restores: tabs start their saved agent again.
    nonisolated(unsafe) static var resumeOnRestore = false
    /// Restored tab ID → how its terminal starts the agent, consumed when the surface is created.
    nonisolated(unsafe) private static var pendingResumes: [UUID: LaunchSpec] = [:]
    private static let lock = NSLock()

    /// Starts `agent` in restored tab `tabID` once its terminal opens.
    /// Returns false when `resumeOnRestore` is off or the agent can't be resumed.
    @discardableResult
    static func scheduleResume(_ agent: AgentResumePoint, for tabID: UUID) -> Bool {
        guard resumeOnRestore, let command = agent.command else { return false }
        var isDirectory: ObjCBool = false
        let cwd = agent.cwd.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil
        }
        lock.withLock { pendingResumes[tabID] = LaunchSpec(command: command, cwd: cwd) }
        return true
    }

    static func takeResume(for tabID: UUID) -> LaunchSpec? {
        lock.withLock { pendingResumes.removeValue(forKey: tabID) }
    }

    /// The newest Ghostty crash report written after `date`.
    static func latestGhosttyCrashReport(since date: Date) -> String? {
        let fm = FileManager.default
        let dir = ghosttyCrashDirectory
        let reports = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".ghosttycrash") }
            .map { (dir as NSString).appendingPathComponent($0) }
            .compactMap { path -> (String, Date)? in
                guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                    modified >= date
                else { return nil }
                return (path, modified)
            }
        return reports.max { $0.1 < $1.1 }?.0
    }

    private static func path(for pid: pid_t) -> String {
        (directory as NSString).appendingPathComponent(String(pid))
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
