import Foundation

/// The agent a terminal tab ran when the session was saved: enough to start
/// the same conversation again in a restored tab.
struct AgentResumePoint: Codable, Sendable, Equatable {
    /// `AgentKind.rawValue`.
    let kind: String
    let sessionID: String
    /// The agent's working directory; agents look sessions up per project.
    let cwd: String?
    /// The agent was working on a turn, not waiting for input. Optional so
    /// sessions saved before this field decode.
    let wasRunning: Bool?

    init(kind: AgentKind, sessionID: String, cwd: String?, wasRunning: Bool = false) {
        self.kind = kind.rawValue
        self.sessionID = sessionID
        self.cwd = cwd
        self.wasRunning = wasRunning
    }

    /// The shell command that reopens this session; nil for agents Boo can't resume.
    /// `prompt` is sent as the first message of the reopened session.
    func command(prompt: String? = nil) -> String? {
        AgentKind(rawValue: kind)?.resumeCommand(sessionID: sessionID, prompt: prompt)
    }
}

extension AgentKind {
    /// The command that reopens session `sessionID`, optionally sending `prompt`; nil for `.custom`.
    func resumeCommand(sessionID: String, prompt: String? = nil) -> String? {
        let id = shellEscape(sessionID)
        let base: String
        switch self {
        case .claudeCode: base = "claude --resume \(id)"
        case .codex: base = "codex resume \(id)"
        case .openCode: base = "opencode --session \(id)"
        case .custom: return nil
        }
        guard let prompt, !prompt.isEmpty else { return base }
        return base + promptArgument(prompt)
    }

    /// `prompt` as the first-message argument of this agent's CLI, with a leading space.
    func promptArgument(_ prompt: String) -> String {
        (self == .openCode ? " --prompt " : " ") + shellEscape(prompt)
    }
}

/// Tells a crash from a normal quit. Each running Boo keeps a file named
/// after its PID in `~/.boo/run/` and deletes it on a normal quit; a file
/// whose process is gone at launch means that run crashed or was killed.
/// Per-PID files keep a second Boo (a dev build) from looking like a crash.
enum CrashRecovery {
    /// How the previous run ended when it did not quit normally.
    enum UnexpectedEnd: Equatable {
        /// A crash report was written after that run started.
        case crashed(report: String)
        /// No crash report: force quit, killed, or the Mac lost power.
        case killed

        /// What ended the run, for "Recovered from …".
        var cause: String {
            switch self {
            case .crashed: return "a crash"
            case .killed: return "a force quit"
            }
        }

        /// Title of the resume prompt.
        var title: String {
            switch self {
            case .crashed: return "Boo quit unexpectedly"
            case .killed: return "Boo was closed without quitting"
            }
        }
    }

    /// Sent to agents that were mid-turn when Boo went down.
    static let continuePrompt =
        "Boo restarted after your session was interrupted. Check where you left off and continue the task."

    nonisolated(unsafe) static var _testDirectory: String?
    nonisolated(unsafe) static var _testCrashDirectories: [String]?
    static var directory: String {
        _testDirectory ?? (BooPaths.configDir as NSString).appendingPathComponent("run")
    }

    /// Where crash reports land: Ghostty's handler, then macOS's.
    static var crashDirectories: [String] {
        _testCrashDirectories ?? [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/ghostty/crash"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
        ]
    }

    /// Set by `markLaunch`: how the previous run ended, nil after a normal quit.
    nonisolated(unsafe) private(set) static var previousRunEnd: UnexpectedEnd?

    /// Records this run and sets `previousRunEnd`. Call once, early.
    static func markLaunch(pid: pid_t = getpid(), isAlive: (pid_t) -> Bool = processIsAlive) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var startedAt: Date?
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
            guard let other = pid_t(name), other != pid, !isAlive(other) else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            let started = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            startedAt = min(startedAt ?? started, started)
            try? fm.removeItem(atPath: path)
        }
        fm.createFile(atPath: path(for: pid), contents: Data())
        previousRunEnd = startedAt.map { start in
            latestCrashReport(since: start).map { .crashed(report: $0) } ?? .killed
        }
        switch previousRunEnd {
        case .crashed(let report)?:
            booLog(.warning, .app, "Previous run crashed; crash report: \(report)")
        case .killed?:
            booLog(.warning, .app, "Previous run ended without quitting (force quit or killed)")
        case nil:
            break
        }
    }

    /// Call on a normal quit, after the session is saved.
    static func markCleanExit(pid: pid_t = getpid()) {
        try? FileManager.default.removeItem(atPath: path(for: pid))
    }

    /// Whether agents saved in the session should start again at this launch.
    static func shouldResumeAgents(settings: AppSettings = .shared) -> Bool {
        guard settings.agentRecovery != .off else { return false }
        return previousRunEnd != nil || settings.resumeAgentsAfterQuit
    }

    // MARK: - Resume

    /// Set while the launch session restores: tabs start their saved agent again.
    nonisolated(unsafe) static var resumeOnRestore = false
    /// Restored tab ID → the agent its terminal starts, consumed when the surface is created.
    nonisolated(unsafe) private static var pendingResumes: [UUID: AgentResumePoint] = [:]
    private static let lock = NSLock()

    /// Starts `agent` in restored tab `tabID` once its terminal opens.
    /// Returns false when `resumeOnRestore` is off or the agent can't be resumed.
    @discardableResult
    static func scheduleResume(_ agent: AgentResumePoint, for tabID: UUID) -> Bool {
        guard resumeOnRestore, agent.command() != nil else { return false }
        lock.withLock { pendingResumes[tabID] = agent }
        return true
    }

    /// How tab `tabID`'s terminal starts its agent; nil when none is pending.
    /// `continueWork` sends `continuePrompt` to an agent that was mid-turn;
    /// nil reads `AppSettings.continueInterruptedAgents`.
    static func takeResume(for tabID: UUID, continueWork: Bool? = nil) -> LaunchSpec? {
        guard let agent = lock.withLock({ pendingResumes.removeValue(forKey: tabID) }) else { return nil }
        let continueWork = continueWork ?? AppSettings.shared.continueInterruptedAgents
        let prompt = continueWork && agent.wasRunning == true ? continuePrompt : nil
        guard let command = agent.command(prompt: prompt) else { return nil }
        var isDirectory: ObjCBool = false
        let cwd = agent.cwd.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil
        }
        return LaunchSpec(command: command, cwd: cwd)
    }

    /// Agents scheduled but not started yet: their tabs were never opened.
    /// Session saves keep these so a second crash doesn't lose them.
    static var pendingResumePoints: [UUID: AgentResumePoint] {
        lock.withLock { pendingResumes }
    }

    /// The newest crash report from Boo or Ghostty written after `date`.
    static func latestCrashReport(since date: Date) -> String? {
        let fm = FileManager.default
        let reports = crashDirectories.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".ghosttycrash") || ($0.hasPrefix("Boo") && $0.hasSuffix(".ips")) }
                .map { (dir as NSString).appendingPathComponent($0) }
        }
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
