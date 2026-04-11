import Foundation

extension TerminalBridge {
    /// Common shell names to filter out from process display.
    static var shellNames: Set<String> { ProcessIcon.shells }

    /// All remote tool command names recognized in terminal titles.
    private static let remoteCommandNames: Set<String> = {
        var names: Set<String> = ["ssh", "mosh"]
        for tool in ContainerTool.all {
            for name in tool.processNames {
                names.insert(name)
            }
        }
        return names
    }()

    /// Git forge hosts that use SSH transport but are not interactive sessions.
    /// Connections to these hosts should not trigger remote session detection.
    private static let gitForgeHosts: Set<String> = [
        "github.com", "gitlab.com", "bitbucket.org", "codeberg.org",
        "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
        "source.developers.google.com", "ssh.gitlab.gnome.org"
    ]

    /// Whether a host is a known git forge (non-interactive SSH).
    private static func isGitForgeHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        // Strip "user@" prefix if present (e.g. "git@github.com" → "github.com")
        let hostname: String
        if let atIdx = lower.firstIndex(of: "@") {
            hostname = String(lower[lower.index(after: atIdx)...])
        } else {
            hostname = lower
        }
        return gitForgeHosts.contains(hostname)
    }

    /// Detect remote sessions from terminal title and working directory.
    /// Uses title heuristics (user@host, ssh, docker, kubectl, etc.) rather than
    /// filesystem checks, since paths like `/tmp` exist on both local and remote systems.
    /// Only matches interactive shell sessions (e.g. `docker exec -it`, not `docker logs`).
    static func detectRemoteFromHeuristics(title: String, cwd: String) -> RemoteSessionType? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let parts = trimmed.split(separator: " ").map(String.init)
        let lowerParts = lower.split(separator: " ").map(String.init)

        // Container/VM tool detection: title must contain tool name + interactive subcommand.
        // This excludes non-interactive commands like `docker logs`, `docker build`, etc.
        for tool in ContainerTool.all {
            for processName in tool.processNames {
                guard
                    lowerParts.first == processName
                        || lower.hasPrefix("/") && (lowerParts.first?.hasSuffix("/\(processName)") == true)
                else {
                    continue
                }
                if let target = tool.interactiveTarget(from: parts) {
                    return .container(target: target, tool: tool)
                }
            }
        }

        if let hexContainerID = detectDockerHexPromptTarget(from: trimmed) {
            return .container(target: hexContainerID, tool: .docker)
        }

        // SSH detection: require the shell-prompt pattern "user@host:path".
        // Real SSH (and container) shell prompts always include a colon after the hostname
        // followed by a path, e.g. "user@host:~$", "user@host: ~/dir", "user@host:/app#".
        // This PS1 pattern is the definitive marker — it is absent from:
        //   - npm version specifiers  ("npx pkg@latest", "bunx @scope/tool")
        //   - bare command arguments  ("cmd user@host")
        //   - git remote URLs         ("git@github.com:org/repo") ← also caught by gitForgeHosts
        // Without the colon we cannot reliably distinguish `word@word` from SSH.
        //
        // Matching strategy: find the first occurrence of "@" in the title and check
        // that a ":" appears immediately after the host token (before any space).
        // "user@host: ~/dir" (space after colon) is handled by requiring ":" anywhere
        // between the "@" and the next space boundary of the host portion.
        if let atRange = trimmed.range(of: "@") {
            let user = String(trimmed[..<atRange.lowerBound])
            let afterAt = String(trimmed[atRange.upperBound...])

            // Split host from path at the first ":"
            guard let colonIdx = afterAt.firstIndex(of: ":") else {
                // No colon → not a shell prompt pattern; skip SSH detection
                return nil
            }
            let rawHost = String(afterAt[..<colonIdx])
            // Host must not contain spaces (it's a single token before the colon)
            guard !rawHost.contains(" "),
                !rawHost.isEmpty,
                !user.contains(" "),  // user is also a single token
                !user.isEmpty,
                !rawHost.contains("/"),  // path separators are not valid in hostnames
                !isLocalHost(rawHost),
                !isGitForgeHost(rawHost),
                // "git" is the SSH user for git transports (git clone git@host:org/repo),
                // never an interactive shell session.
                user.lowercased() != "git"
            else {
                return nil
            }
            return .ssh(host: "\(user)@\(rawHost)", alias: nil)
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

        // When an "ssh" or "mosh" command is detected in the title, set alias = host so
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
        if let processDetection, case .mosh(let cmdHost) = processDetection {
            if detected == nil {
                detected = .mosh(host: cmdHost)
            }
        }

        // Nested container commands inside SSH should keep the outer SSH environment.
        if case .ssh = previous, case .container = detected {
            detected = previous
        }
        if case .mosh = previous, case .container = detected {
            detected = previous
        }

        // Container shell prompts show "root@abc123def456:~" which the heuristic
        // misidentifies as SSH. When we're already in a container session, keep it.
        if case .container = previous, case .ssh = detected {
            detected = previous
        }
        if case .container(_, let previousTool) = previous,
            case .container(let target, let detectedTool) = detected,
            previousTool == detectedTool,
            heuristic != nil, processDetection == nil,
            detectedTool == .docker,
            looksLikeHexContainerID(target)
        {
            detected = previous
        }

        // Preserve alias from previous session when the new detection doesn't have one.
        // This keeps the SSH config alias (e.g. "devbox") available for connection reuse
        // even as the title changes to "root@ubuntu-server:~".
        // CRITICAL: We must keep the *previous host* as the display name to avoid
        // breaking Equatable (which compares hosts). A host change would cause a
        // false session transition on every cd, tearing down and rebuilding the tree.
        // Stabilize SSH session host when the prompt shows a different hostname than
        // the original command target. E.g., "ssh devbox" → "root@ubuntu-server:~" or
        // "ssh root@1.2.3.4" → "root@hostname:~". The alias (set when detected from
        // a command title) marks sessions that should be stabilized. Prompt-to-prompt
        // transitions (no alias) like "user@host1:~" → "user@host2:~" are genuine
        // host switches and should NOT be stabilized.
        if case .ssh(let prevHost, let prevAlias) = previous, let alias = prevAlias,
            case .ssh = detected,
            heuristic != nil, processDetection == nil
        {
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
            let host = extractHost(after: afterAt) ?? afterAt
            return isLocalHost(host)
        }()
        if isLocalShellPrompt || isLocalUserAtHostPrompt {
            return nil
        }
        // Ambiguous title (command being typed, etc.) — keep previous session
        return previous
    }

    /// Extract the hostname from text containing "user@host:path" or "user@host rest".
    /// Strips the colon-delimited path and any trailing words, returning just the host.
    static func extractHost(after atSign: String) -> String? {
        let host =
            atSign
            .split(separator: ":").first
            .flatMap { $0.split(separator: " ").first }
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (host?.isEmpty == false) ? host : nil
    }

    /// Detect Docker's default prompt format where the hostname is the container ID.
    /// This covers cases where the first title seen after `docker exec` is already
    /// inside the container shell, before the original command title is observed.
    private static func detectDockerHexPromptTarget(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }

        let rawPath = String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "#$ "))
            .trimmingCharacters(in: .whitespaces)
        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("~") else { return nil }

        let prefix = String(trimmed[..<colonIndex])
        if let atIndex = prefix.firstIndex(of: "@") {
            let host = String(prefix[prefix.index(after: atIndex)...])
            return looksLikeHexContainerID(host) ? host : nil
        }

        return looksLikeHexContainerID(prefix) ? prefix : nil
    }

    private static func looksLikeHexContainerID(_ value: String) -> Bool {
        value.count >= 12 && value.allSatisfy { $0.isHexDigit }
    }

    /// Detect remote session from the process/command shown in the terminal title.
    /// This catches cases where the title is "ssh user@host", "mosh host",
    /// "docker exec container", "kubectl exec pod", etc.
    static func detectRemoteFromProcessName(title: String) -> RemoteSessionType? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return nil }
        let cmdBase = cmd.lastPathComponent.lowercased()

        // SSH: title starts with "ssh" followed by a host
        if cmdBase == "ssh" {
            var skipNext = false
            let valueOpts: Set<String> = [
                "-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-w", "-E"
            ]
            for arg in parts.dropFirst() {
                if skipNext {
                    skipNext = false
                    continue
                }
                if arg.hasPrefix("-") {
                    if valueOpts.contains(arg) { skipNext = true }
                    continue
                }
                // Skip git transport targets: "git@host" is a non-interactive git SSH user
                let isGitUser = arg.lowercased().hasPrefix("git@")
                if arg != "localhost" && arg != "127.0.0.1" && !isGitForgeHost(arg) && !isGitUser {
                    return .ssh(host: arg)
                }
                break
            }
        }

        // Mosh: title starts with "mosh" followed by a host
        if cmdBase == "mosh" || cmdBase == "mosh-client" {
            var skipNext = false
            let valueOpts: Set<String> = ["-p", "--port", "--ssh", "--predict", "--predict-overwrite"]
            for arg in parts.dropFirst() {
                if skipNext {
                    skipNext = false
                    continue
                }
                if arg.hasPrefix("-") {
                    if valueOpts.contains(arg) { skipNext = true }
                    continue
                }
                if arg != "localhost" && arg != "127.0.0.1" {
                    return .mosh(host: arg)
                }
                break
            }
        }

        // Container/VM tools: title starts with tool name followed by an interactive subcommand
        if let tool = ContainerTool.byProcessName[cmdBase], parts.count >= 2 {
            if let target = tool.interactiveTarget(from: parts) {
                return .container(target: target, tool: tool)
            }
        }

        return nil
    }

    /// Extract a remote CWD from a terminal title like "user@host:~/dir", "user@host:/path",
    /// or container prompts like "195cad4b6562:/app#", "my-container:~#".
    /// Returns the path portion, expanding ~ to /root or /home/user as appropriate.
    /// When `session` is a container, only matches container-style prompts (not SSH user@host:path).
    static func extractRemoteCwd(from title: String, session: RemoteSessionType? = nil) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let isContainerSession = session?.isContainer ?? false

        // Match "user@host:path" pattern (SSH prompts and container prompts with user@)
        if let atIdx = trimmed.firstIndex(of: "@") {
            let afterAt = trimmed[trimmed.index(after: atIdx)...]
            if let colonIdx = afterAt.firstIndex(of: ":") {
                // Extract the hostname between @ and :
                let hostPart = String(afterAt[..<colonIdx])
                let rawPath = String(afterAt[afterAt.index(after: colonIdx)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#$ "))
                    .trimmingCharacters(in: .whitespaces)
                if !rawPath.isEmpty {
                    // For container sessions, only match if the host looks like a container ID
                    // (hex, 12+ chars) — reject SSH-style hostnames like "157.90.31.161".
                    if isContainerSession {
                        let isContainerID = hostPart.count >= 12 && hostPart.allSatisfy { $0.isHexDigit }
                        if !isContainerID {  // fall through to container prompt branch
                        } else {
                            let user = String(trimmed[..<atIdx])
                            return expandTildePath(rawPath, user: user)
                        }
                    } else {
                        let user = String(trimmed[..<atIdx])
                        return expandTildePath(rawPath, user: user)
                    }
                }
            }
        }

        // Container/hostname prompt: "hostname:path#" or "hostname:path$"
        // Matches both hex container IDs (195cad4b6562:/app#) and named containers
        // (my-service:/app#). Only match if the path part looks like a filesystem path.
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let before = String(trimmed[..<colonIdx])
            let rawPath = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "#$ "))
                .trimmingCharacters(in: .whitespaces)
            // Path must start with / or ~ to be a filesystem path (not a port number etc.)
            if !rawPath.isEmpty && !before.isEmpty
                && (rawPath.hasPrefix("/") || rawPath.hasPrefix("~"))
            {
                // Match hex container IDs (12+ chars) or hostnames that look like
                // container/pod names (contain a hyphen/digit, at least 4 chars).
                // Avoids matching short words like "vim:/tmp" or "foo:/bar".
                let isHexID = before.count >= 12 && before.allSatisfy { $0.isHexDigit }
                let isContainerHostname =
                    before.count >= 4
                    && before.contains(where: { $0 == "-" || $0 == "_" || $0.isNumber })
                    && before.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
                if isHexID || isContainerHostname {
                    // For container prompts without user@, assume root for ~ expansion
                    return expandTildePath(rawPath, user: "root")
                }
            }
        }

        return nil
    }

    /// Expand a tilde-prefixed path using the given username.
    private static func expandTildePath(_ path: String, user: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let rest = String(path.dropFirst())
        if user == "root" {
            return "/root" + rest
        }
        return "/home/\(user)" + rest
    }

    /// Extract a short process name from a terminal title.
    /// Returns empty for shell prompts, local user@host patterns, and path-only titles.
    static func extractProcessName(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        // Check for known app title patterns (e.g. "✳ Claude Code" → "claude")
        if let matched = ProcessIcon.matchTitle(trimmed) {
            return matched
        }

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
            // "command: args" — return command name (first word only)
            let cmd = before.split(separator: " ").first.map(String.init) ?? before
            if shellNames.contains(cmd.lowercased()) { return "" }
            if looksLikePath(cmd) { return "" }
            return cmd
        }

        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if shellNames.contains(firstWord.lowercased()) { return "" }
        // Reject path-only titles (e.g. "~/dev/project", "/Users/jane/project",
        // "…/dev/project") — these are CWD titles set by shell prompts, not process names.
        if looksLikePath(firstWord) { return "" }
        return firstWord
    }

    /// True when the string looks like a filesystem path rather than a process name.
    private static func looksLikePath(_ s: String) -> Bool {
        s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("~") || s.hasPrefix("…/")
            || s.hasPrefix("./") || s.hasPrefix("../")
    }

    /// Check if a terminal title has any remote indicators (user@host, ssh, docker, kubectl, etc.).
    /// Titles matching the local hostname (e.g. "user@localmachine:~") are NOT remote.
    static func titleLooksRemote(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()
        // Starts with a known remote command
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? ""
        if remoteCommandNames.contains(firstWord) { return true }
        // Contains user@host pattern — check if host is local
        if let atRange = trimmed.range(of: "@") {
            let afterAt = String(trimmed[atRange.upperBound...])
            let host = extractHost(after: afterAt) ?? afterAt
            if isLocalHost(host) { return false }
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
        let host = extractHost(after: afterAt) ?? afterAt
        return isLocalHost(host)
    }
}
