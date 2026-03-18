import Foundation

extension TerminalBridge {
    /// Common shell names to filter out from process display.
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "elvish"]

    /// Detect remote sessions from terminal title and working directory.
    /// Uses title heuristics (user@host, ssh, docker) rather than filesystem checks,
    /// since paths like `/tmp` exist on both local and remote systems.
    static func detectRemoteFromHeuristics(title: String, cwd: String) -> RemoteSessionType? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

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
                    return .docker(container: stripShellQuotes(String(parts[i])))
                }
            }
            return .docker(container: "unknown")
        }

        // SSH detection: user@host pattern in title
        let atPattern = trimmed.split(separator: " ").first(where: { $0.contains("@") })
        if let match = atPattern {
            let components = match.split(separator: "@", maxSplits: 1)
            if components.count == 2 {
                let host = components[1]
                    .split(separator: ":").first
                    .flatMap { $0.split(separator: " ").first }
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !host.isEmpty && !isLocalHost(host) {
                    return .ssh(host: "\(components[0])@\(host)", alias: nil)
                }
            }
        }

        return nil
    }

    /// Reconcile remote session state across imperfect title/CWD signals.
    /// Blank titles and remote-looking prompts are not enough evidence to clear an
    /// existing remote session because remote shells may keep common paths like `/tmp`.
    static func resolveRemoteSession(
        title: String,
        cwd: String,
        previous: RemoteSessionType?,
        preferPreviousForCwdEvent: Bool = false
    ) -> RemoteSessionType? {
        let heuristic = detectRemoteFromHeuristics(title: title, cwd: cwd)
        let processDetection = detectRemoteFromProcessName(title: title)
        var detected = heuristic ?? processDetection

        // When a "ssh" command is detected in the title, set alias = host so
        // subsequent prompt-based detections can stabilize on it. This fires
        // regardless of whether the heuristic also matched (titles like
        // "ssh -i key root@host" trigger both the heuristic and process detection).
        if let processDetection, case .ssh(let cmdHost, _) = processDetection {
            if case .ssh(_, let existingAlias) = detected, existingAlias == nil {
                detected = .ssh(host: cmdHost, alias: cmdHost)
            } else if detected == nil {
                detected = .ssh(host: cmdHost, alias: cmdHost)
            }
        }

        // Nested docker commands inside SSH should keep the outer SSH environment.
        if case .ssh = previous, case .docker = detected {
            detected = previous
        }

        // Docker container shell prompts show "root@abc123def456:~" which the heuristic
        // misidentifies as SSH. When we're already in a Docker session, keep it.
        if case .docker = previous, case .ssh = detected {
            detected = previous
        }

        // Preserve alias from previous session when the new detection doesn't have one.
        // This keeps the SSH config alias (e.g. "het") available for connection reuse
        // even as the title changes to "root@ubuntu-server:~".
        // CRITICAL: We must keep the *previous host* as the display name to avoid
        // breaking Equatable (which compares hosts). A host change would cause a
        // false session transition on every cd, tearing down and rebuilding the tree.
        // Stabilize SSH session host when the prompt shows a different hostname than
        // the original command target. E.g., "ssh het" → "root@ubuntu-server:~" or
        // "ssh root@1.2.3.4" → "root@hostname:~". The alias (set when detected from
        // a command title) marks sessions that should be stabilized. Prompt-to-prompt
        // transitions (no alias) like "user@host1:~" → "user@host2:~" are genuine
        // host switches and should NOT be stabilized.
        if case .ssh(let prevHost, let prevAlias) = previous, let alias = prevAlias,
           case .ssh = detected,
           heuristic != nil, processDetection == nil {
            detected = .ssh(host: prevHost, alias: alias)
        }

        if let detected {
            return detected
        }
        guard let previous else {
            return nil
        }

        // A directory change originating from an already-remote session is stronger
        // evidence than a stale title. Keep the previous remote session until a
        // title/process transition explicitly moves us back to local.
        if preferPreviousForCwdEvent {
            return previous
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return previous
        }
        if titleLooksRemote(title) {
            return previous
        }
        // Only a known local shell name (e.g. "zsh", "bash") or a local user@host
        // prompt is strong enough evidence to clear a remote session.
        // Transient command titles like "cd /tmp", "vim file.txt", "ls -la" should
        // NOT clear the session — they appear briefly as the command is typed.
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        let isLocalShellPrompt = shellNames.contains(firstWord.lowercased())
        let isLocalUserAtHostPrompt: Bool = {
            guard trimmed.contains("@"), let atRange = trimmed.range(of: "@") else { return false }
            let afterAt = String(trimmed[atRange.upperBound...])
            let host = afterAt.split(separator: ":").first
                .flatMap { $0.split(separator: " ").first }
                .map(String.init) ?? afterAt
            return isLocalHost(host)
        }()
        if isLocalShellPrompt || isLocalUserAtHostPrompt {
            return nil
        }
        // Ambiguous title (command being typed, etc.) — keep previous session
        return previous
    }

    /// Strip shell quoting from a string: 'foo' → foo, "foo" → foo, foo → foo.
    static func stripShellQuotes(_ s: String) -> String {
        var r = s
        if (r.hasPrefix("'") && r.hasSuffix("'")) || (r.hasPrefix("\"") && r.hasSuffix("\"")) {
            r = String(r.dropFirst().dropLast())
        }
        return r
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
                    return .docker(container: stripShellQuotes(parts[i]))
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
        if let atIdx = trimmed.firstIndex(of: "@") {
            let afterAt = trimmed[trimmed.index(after: atIdx)...]
            if let colonIdx = afterAt.firstIndex(of: ":") {
                let path = String(afterAt[afterAt.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    let user = String(trimmed[..<atIdx])
                    if path.hasPrefix("~") {
                        let rest = String(path.dropFirst())
                        if user == "root" {
                            return "/root" + rest
                        }
                        return "/home/\(user)" + rest
                    }
                    return path
                }
            }
        }

        // Docker container prompt: "containerid:/path#" or "containerid:/path$"
        // No user@ prefix, just hex-like ID followed by colon and path.
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let before = String(trimmed[..<colonIdx])
            let afterColon = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "#$ "))
            // Container IDs are typically 12+ hex chars
            let isContainerID = before.count >= 12 && before.allSatisfy { $0.isHexDigit }
            if isContainerID && !afterColon.isEmpty && afterColon.hasPrefix("/") {
                return afterColon
            }
        }

        return nil
    }

    /// Extract a short process name from a terminal title.
    /// Returns empty for shell prompts and local user@host patterns.
    static func extractProcessName(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        // "user@host: ~/dir" — local shell prompt, not a process
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let before = String(trimmed[..<colonIdx])
            if before.contains("@") {
                // Check if this is the local hostname
                let host = before.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
                if isLocalHost(host) {
                    return ""
                }
                return before
            }
            // "command: args" — return command name
            if shellNames.contains(before.lowercased()) { return "" }
            return before
        }

        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if shellNames.contains(firstWord.lowercased()) { return "" }
        return firstWord
    }

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
            // Not remote if it matches any local hostname
            if isLocalHost(host) {
                return false
            }
            return true
        }
        return false
    }

    /// True when `user@host` looks like the local machine.
    /// Matches if host is any known local hostname, OR if both user and host
    /// match local identity (covers cases where the hostname source differs).
    /// True when the title contains a user@host pattern where host is the local machine.
    static func titleIsLocalUserAtHost(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let atRange = trimmed.range(of: "@") else { return false }
        let afterAt = String(trimmed[atRange.upperBound...])
        let host = afterAt.split(separator: ":").first
            .flatMap { $0.split(separator: " ").first }
            .map(String.init) ?? afterAt
        return isLocalHost(host)
    }
}
