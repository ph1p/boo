import Combine
import Foundation

/// Snapshot of the active terminal's state.
struct TerminalState: Equatable {
    var paneID: UUID
    var workspaceID: UUID
    var workingDirectory: String
    var terminalTitle: String
    var foregroundProcess: String
    var remoteSession: RemoteSessionType?
    var isDockerAvailable: Bool

    static let empty = TerminalState(
        paneID: UUID(),
        workspaceID: UUID(),
        workingDirectory: "",
        terminalTitle: "",
        foregroundProcess: "",
        remoteSession: nil,
        isDockerAvailable: false
    )
}

/// Discrete terminal events for subscribers that care about transitions, not snapshots.
enum TerminalEvent: Equatable {
    case directoryChanged(path: String)
    case titleChanged(title: String)
    case processChanged(name: String)
    case remoteSessionChanged(session: RemoteSessionType?)
    case focusChanged(paneID: UUID)
    case workspaceSwitched(workspaceID: UUID)
}

/// Centralized event bus and state holder for terminal events.
/// One instance per MainWindowController.
final class TerminalBridge {
    @Published private(set) var state: TerminalState
    let events = PassthroughSubject<TerminalEvent, Never>()

    init(paneID: UUID, workspaceID: UUID, workingDirectory: String) {
        self.state = TerminalState(
            paneID: paneID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            isDockerAvailable: false
        )
    }

    // MARK: - Input Methods

    func handleFocus(paneID: UUID, workingDirectory: String) {
        state.paneID = paneID
        if !workingDirectory.isEmpty {
            state.workingDirectory = workingDirectory
        }
        events.send(.focusChanged(paneID: paneID))
    }

    func handleDirectoryChange(path: String, paneID: UUID) {
        guard paneID == state.paneID else { return }
        guard path != state.workingDirectory else { return }
        state.workingDirectory = path

        let previousRemote = state.remoteSession
        state.remoteSession = TerminalBridge.detectRemoteFromHeuristics(
            title: state.terminalTitle, cwd: path
        )
        if state.remoteSession != previousRemote {
            events.send(.remoteSessionChanged(session: state.remoteSession))
        }

        events.send(.directoryChanged(path: path))
    }

    func handleTitleChange(title: String, paneID: UUID) {
        guard paneID == state.paneID else { return }
        state.terminalTitle = title

        let process = TerminalBridge.extractProcessName(from: title)
        let processChanged = process != state.foregroundProcess
        state.foregroundProcess = process

        let previousRemote = state.remoteSession
        state.remoteSession = TerminalBridge.detectRemoteFromHeuristics(
            title: title, cwd: state.workingDirectory
        )

        events.send(.titleChanged(title: title))
        if processChanged {
            events.send(.processChanged(name: process))
        }
        if state.remoteSession != previousRemote {
            events.send(.remoteSessionChanged(session: state.remoteSession))
        }
    }

    func handleProcessExit(paneID: UUID) {
        guard paneID == state.paneID else { return }
        let hadRemote = state.remoteSession != nil
        state.remoteSession = nil
        state.foregroundProcess = ""
        state.terminalTitle = ""
        if hadRemote {
            events.send(.remoteSessionChanged(session: nil))
        }
    }

    func switchContext(paneID: UUID, workspaceID: UUID, workingDirectory: String) {
        state = TerminalState(
            paneID: paneID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            isDockerAvailable: state.isDockerAvailable
        )
        events.send(.workspaceSwitched(workspaceID: workspaceID))
    }

    // MARK: - Heuristics

    /// Detect remote sessions from terminal title and working directory.
    /// If the title contains a user@host pattern and the CWD doesn't exist locally,
    /// it's likely an SSH session. Docker is detected from title keywords.
    static func detectRemoteFromHeuristics(title: String, cwd: String) -> RemoteSessionType? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Check if CWD exists locally — if it does, we're not remote
        if !cwd.isEmpty && FileManager.default.fileExists(atPath: cwd) {
            return nil
        }

        // Docker detection: title contains "docker" keyword
        let lower = trimmed.lowercased()
        if lower.contains("docker exec") || lower.contains("docker run") ||
           lower.hasPrefix("docker") {
            // Try to extract container name from title
            let parts = trimmed.split(separator: " ")
            if let execIdx = parts.firstIndex(where: { $0 == "exec" || $0 == "run" }),
               execIdx + 1 < parts.endIndex {
                // Skip flags (starting with -)
                var i = parts.index(after: execIdx)
                while i < parts.endIndex && parts[i].hasPrefix("-") {
                    i = parts.index(after: i)
                }
                if i < parts.endIndex {
                    return .docker(container: String(parts[i]))
                }
            }
            return .docker(container: "unknown")
        }

        // SSH detection: user@host pattern in title
        let atPattern = trimmed.split(separator: " ").first(where: { $0.contains("@") })
        if let match = atPattern {
            let components = match.split(separator: "@", maxSplits: 1)
            if components.count == 2 {
                let host = String(components[1]).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if !host.isEmpty && host != "localhost" && host != "127.0.0.1" {
                    return .ssh(host: String(match))
                }
            }
        }

        return nil
    }

    /// Detect remote session from the process/command shown in the terminal title.
    /// This catches cases where the title is "ssh user@host" or "docker exec container"
    /// even when the CWD still looks local.
    static func detectRemoteFromProcessName(title: String) -> RemoteSessionType? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return nil }
        let cmdBase = (cmd as NSString).lastPathComponent

        // SSH: title starts with "ssh" followed by a host
        if cmdBase == "ssh" {
            // Find first non-option argument as host
            var skipNext = false
            for arg in parts.dropFirst() {
                if skipNext { skipNext = false; continue }
                if arg.hasPrefix("-") {
                    let valueOpts: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-w", "-E"]
                    if valueOpts.contains(arg) { skipNext = true }
                    continue
                }
                let host = arg
                if host != "localhost" && host != "127.0.0.1" {
                    return .ssh(host: host)
                }
                break
            }
        }

        // Docker: title starts with "docker" followed by "exec"
        if cmdBase == "docker" && parts.count >= 3 {
            if let execIdx = parts.firstIndex(of: "exec"), execIdx + 1 < parts.count {
                var i = execIdx + 1
                while i < parts.count && parts[i].hasPrefix("-") { i += 1 }
                if i < parts.count {
                    return .docker(container: parts[i])
                }
            }
        }

        return nil
    }

    /// Extract a remote CWD from a terminal title like "user@host:~/dir" or "user@host:/path".
    /// Returns the path portion, expanding ~ to /root or /home/user as appropriate.
    static func extractRemoteCwd(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // Match "user@host:path" pattern
        guard let atIdx = trimmed.firstIndex(of: "@") else { return nil }
        let afterAt = trimmed[trimmed.index(after: atIdx)...]
        guard let colonIdx = afterAt.firstIndex(of: ":") else { return nil }
        let path = String(afterAt[afterAt.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        // Extract user for ~ expansion
        let user = String(trimmed[..<atIdx])

        if path.hasPrefix("~") {
            // Expand ~ to home directory
            let rest = String(path.dropFirst()) // remove ~
            if user == "root" {
                return "/root" + rest
            }
            return "/home/\(user)" + rest
        }
        return path
    }

    /// Local hostname, cached for comparing against remote titles.
    private static let localHostname: String = {
        ProcessInfo.processInfo.hostName
            .split(separator: ".").first.map(String.init) ?? ""
    }()

    /// Check if a terminal title has any remote indicators (user@host, ssh, docker).
    /// Titles matching the local hostname (e.g. "user@localmachine:~") are NOT remote.
    static func titleLooksRemote(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()
        // Starts with ssh or docker command
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? ""
        if firstWord == "ssh" || firstWord == "docker" { return true }
        // Contains user@host pattern — check if host is local
        if let atRange = trimmed.range(of: "@") {
            let afterAt = String(trimmed[atRange.upperBound...])
            // Extract hostname (before : or space or end)
            let host = afterAt.split(separator: ":").first
                .flatMap { $0.split(separator: " ").first }
                .map(String.init) ?? afterAt
            let hostLower = host.lowercased()
            // Not remote if it matches local hostname
            if hostLower == localHostname.lowercased()
                || hostLower == "localhost"
                || hostLower == "127.0.0.1" {
                return false
            }
            return true
        }
        return false
    }

    /// Extract a short process name from a terminal title.
    /// Shells typically set title to "user@host: cwd" or "command".
    static func extractProcessName(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        // Common patterns: "user@host: ~/dir", "vim file.txt", "zsh"
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let before = String(trimmed[..<colonIdx])
            // "user@host" pattern → return just the command part or host
            if before.contains("@") { return before }
            return before
        }

        // Just the command/process name
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return firstWord
    }
}
