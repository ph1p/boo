import Darwin
import Foundation

/// Local process-tree introspection: child enumeration, name resolution, and foreground-process
/// detection for a known shell PID.
///
/// Split out of `RemoteExplorer`, which mixes this with SSH/container exploration. Nothing here
/// knows about remote sessions — `TerminalBridge`, `MainWindowController`, `GhosttyView` and the
/// sidebar consume it purely for "what is running in this pane".
enum ProcessTree {

    // MARK: - Child enumeration

    /// Return all child PIDs of a given parent process.
    /// Note: `proc_listchildpids` returns the count of children (not bytes).
    static func childPIDs(of parent: pid_t) -> [pid_t] {
        // First call with nil buffer returns estimated child count
        let estimate = proc_listchildpids(parent, nil, 0)
        guard estimate > 0 else { return [] }
        // Allocate buffer; pass buffer size in bytes
        let bufCount = max(Int(estimate), 16)
        var pids = [pid_t](repeating: 0, count: bufCount)
        let bufSize = Int32(bufCount * MemoryLayout<pid_t>.size)
        let actual = proc_listchildpids(parent, &pids, bufSize)
        guard actual > 0 else { return [] }
        // Return value is count of children written
        return Array(pids.prefix(Int(actual)))
    }

    /// Get the process name for a PID, stripping the login-shell "-" prefix.
    static func processName(pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    /// Walk from a process down single-child chains to find the actual shell.
    /// Ghostty forks: Boo → login → shell. This walks login → shell.
    /// Stops when: the process has 0 children, >1 children, or is a known shell.
    static func walkToLeafShell(from pid: pid_t) -> pid_t {
        let shellNames = ProcessIcon.shells
        var current = pid
        for _ in 0..<5 {  // safety limit
            let cleanName = processName(pid: current)
            if shellNames.contains(cleanName) { return current }

            let children = childPIDs(of: current)
            if children.count == 1 {
                current = children[0]
            } else {
                break
            }
        }
        return current
    }

    // MARK: - Ancestry

    /// Get the parent PID of a process.
    /// Returns -1 if the process doesn't exist or on error.
    static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }

    /// Check if a PID is a descendant of another PID by walking the process tree.
    /// Walks up to 64 levels to prevent infinite loops in case of cycles.
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            if current <= 1 { return false }
            let parent = parentPID(of: current)
            if parent == current || parent <= 0 { return false }
            current = parent
        }
        return false
    }

    // MARK: - Foreground process

    /// Returns the foreground non-shell process running under a known shell PID, or nil
    /// when the shell itself is the foreground process (idle prompt).
    /// Prefers the single direct child; otherwise searches a few levels down for an AI agent.
    /// Reading the real process tree avoids false positives from folder names in the terminal
    /// title that contain tool keywords like "opencode" or "claude".
    /// When the child is a runtime (node, bun, deno, python…), inspects its argv to
    /// remap shim-launched agents (e.g. `node codex.js` → "codex").
    ///
    /// Results are cached briefly because each resolution costs a `KERN_PROCARGS2`
    /// sysctl per child PID. Pass `maxAge: 0` where the caller already knows the
    /// process may have just changed (e.g. a terminal title change).
    static func foregroundProcess(
        shellPID: pid_t, maxAge: TimeInterval = ForegroundProcessCache.defaultMaxAge
    ) -> String? {
        let cached = ForegroundProcessCache.shared.value(for: shellPID, maxAge: maxAge)
        if cached.hit { return cached.name }
        let name = resolveForegroundProcess(shellPID: shellPID)
        ForegroundProcessCache.shared.store(name, for: shellPID)
        return name
    }

    private static func resolveForegroundProcess(shellPID: pid_t) -> String? {
        let children = childPIDs(of: shellPID)
        guard !children.isEmpty else { return nil }
        // With exactly one child, it's unambiguously the foreground process.
        if children.count == 1, let name = resolvedProcessName(pid: children[0]) {
            return name
        }
        // Otherwise look for an AI agent. Agents fork helper shells (Claude Code runs tool
        // calls as `zsh -c …` children), so a direct-child scan sees only shells and reports
        // nothing — walk a few levels down instead of giving up at depth 1.
        return agentDescendant(of: children)
    }

    /// Breadth-first search for an AI agent beneath `frontier`, returning its process name.
    ///
    /// Bounded because each `resolvedProcessName` costs a `KERN_PROCARGS2` sysctl and this
    /// runs whenever a terminal title changes. Shells resolve to nil and are walked through,
    /// so a helper shell between the prompt and the agent does not hide it.
    private static func agentDescendant(of frontier: [pid_t], maxDepth: Int = 3) -> String? {
        var frontier = frontier
        var budget = 32
        for depth in 0..<maxDepth {
            if frontier.isEmpty { return nil }
            var next: [pid_t] = []
            for pid in frontier {
                if budget == 0 { return nil }
                budget -= 1
                if let name = resolvedProcessName(pid: pid), ProcessIcon.category(for: name) == "ai" {
                    return name
                }
                // The last level's children are never examined, so don't pay to list them.
                if depth < maxDepth - 1 { next.append(contentsOf: childPIDs(of: pid)) }
            }
            frontier = next
        }
        return nil
    }

    // MARK: - Name resolution

    /// Resolve a canonical process name for `pid`.
    /// Some processes (e.g. Claude Code) set their progname to a version string via
    /// setprogname(), so proc_name() returns "2.1.117" instead of "claude".
    /// Falls back to argv[0] (KERN_PROCARGS2) to get the real binary name.
    private static func resolvedProcessName(pid: pid_t) -> String? {
        let raw = processName(pid: pid).lowercased()
        let argv0 = argv0Name(pid: pid)
        if ProcessIcon.shells.contains(raw) || ignoredForegroundProcesses.contains(raw) { return nil }
        if !raw.isEmpty {
            // If proc_name gave us a recognizable name (not a version string), use it.
            if !raw.first!.isNumber && !raw.contains(".") {
                if scriptRuntimes.contains(raw) { return agentFromArgs(pid: pid) }
                return raw
            }
        }
        // proc_name returned empty or a version string — fall back to argv[0].
        if let argv0 {
            if ProcessIcon.shells.contains(argv0) || ignoredForegroundProcesses.contains(argv0) { return nil }
            if scriptRuntimes.contains(argv0) { return agentFromArgs(pid: pid) }
            return argv0
        }
        return raw.isEmpty ? nil : raw
    }

    /// Extract the binary name from the exec path in KERN_PROCARGS2.
    /// getProcessArgs() skips the exec path and returns args only; this reads the exec path directly.
    private static func argv0Name(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        // Skip argc (4 bytes), then read the null-terminated exec path.
        let execPath = buffer.withUnsafeBufferPointer { buf -> String? in
            var offset = MemoryLayout<Int32>.size
            var pathBytes: [UInt8] = []
            while offset < size && buf[offset] != 0 {
                pathBytes.append(buf[offset])
                offset += 1
            }
            return pathBytes.isEmpty ? nil : String(bytes: pathBytes, encoding: .utf8)
        }
        guard let path = execPath else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name.isEmpty ? nil : name
    }

    /// Runtimes that commonly wrap agent CLIs via a JS/PY script shim.
    private static let scriptRuntimes: Set<String> = [
        // JS runtimes
        "node", "bun", "deno",
        // JS package manager launchers (npx codex, bunx codex, pnpm exec codex, yarn dlx codex)
        "npx", "bunx", "pnpx", "yarn", "pnpm",
        // Python runtimes and launchers (uv run aider, uvx aider, pipx run aider)
        "python", "python3", "uv", "uvx", "pipx",
        // Ruby (ruby -e / gem-installed agents)
        "ruby"
    ]

    /// Development/test host processes that may appear in the PTY parent-child chain
    /// but are never meaningful terminal foreground commands.
    private static let ignoredForegroundProcesses: Set<String> = [
        "xctest", "xctestbootstrap"
    ]

    /// Maps substrings found in process argv to canonical agent process names.
    private static let argAgentPatterns: [(substring: String, canonical: String)] = [
        ("codex", "codex"),
        ("opencode", "opencode"),
        ("claude", "claude"),
        ("aider", "aider"),
        ("goose", "goose")
    ]

    /// Inspects the process argv for known agent script patterns, returns canonical name or nil.
    private static func agentFromArgs(pid: pid_t) -> String? {
        guard let args = processArgs(pid: pid) else { return nil }
        let lower = args.lowercased()
        for (substring, canonical) in argAgentPatterns {
            if lower.contains(substring) { return canonical }
        }
        return nil
    }

    // MARK: - argv

    /// Get process command line arguments using sysctl (no subprocess).
    /// Reads only argv — stops before environment variables to avoid false matches
    /// on system PATH entries like `/var/run/com.apple.security.cryptexd/codex.system/...`.
    static func processArgs(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // KERN_PROCARGS2 layout: argc (int32) | exec_path (NUL) | padding (NULs) | argv[0] (NUL) | ... | argv[argc-1] (NUL) | env[0] ...
        guard size > MemoryLayout<Int32>.size else { return nil }
        let args = buffer.withUnsafeBufferPointer { buf -> String? in
            // Read argc so we can stop before environment variables.
            var argc: Int32 = 0
            withUnsafeMutableBytes(of: &argc) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: buf.baseAddress, count: MemoryLayout<Int32>.size))
            }
            let argCount = max(0, Int(argc))

            var offset = MemoryLayout<Int32>.size
            // Skip exec path (null-terminated)
            while offset < size && buf[offset] != 0 { offset += 1 }
            // Skip padding nulls
            while offset < size && buf[offset] == 0 { offset += 1 }
            // Read exactly argc null-terminated argv strings (argv[0] is the binary path)
            var result: [String] = []
            while offset < size && result.count < argCount {
                var argBytes: [UInt8] = []
                while offset < size && buf[offset] != 0 {
                    argBytes.append(buf[offset])
                    offset += 1
                }
                result.append(String(bytes: argBytes, encoding: .utf8) ?? "")
                if offset < size { offset += 1 }
            }
            return result.joined(separator: " ")
        }
        return args
    }
}

/// Short-lived cache for `ProcessTree.foregroundProcess`.
///
/// Resolving a foreground process costs a `KERN_PROCARGS2` sysctl per child PID.
/// The sidebar's workspace-agent-session enumeration calls it once per background
/// tab on every rebuild cycle, on the main thread — with several tabs open that is
/// a syscall storm for data that changes on human timescales.
final class ForegroundProcessCache: @unchecked Sendable {
    static let shared = ForegroundProcessCache()

    /// Long enough to collapse a rebuild burst, short enough that starting an agent
    /// shows up on the next sidebar cycle rather than feeling stuck.
    static let defaultMaxAge: TimeInterval = 1.5

    private let lock = NSLock()
    private var entries: [pid_t: (name: String?, at: TimeInterval)] = [:]

    /// `hit: true` with a nil name is a real answer — "we looked and there is no
    /// foreground process" is cacheable, so it must not read as a miss.
    /// `maxAge` is the caller's freshness bound; 0 always misses.
    func value(for pid: pid_t, maxAge: TimeInterval) -> (hit: Bool, name: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[pid], booUptime() - entry.at < maxAge else {
            return (false, nil)
        }
        return (true, entry.name)
    }

    func store(_ name: String?, for pid: pid_t) {
        let now = booUptime()
        lock.lock()
        defer { lock.unlock() }
        entries[pid] = (name, now)
        // Bound growth: tabs close and PIDs are recycled, so drop anything stale.
        if entries.count > 64 {
            entries = entries.filter { now - $0.value.at < Self.defaultMaxAge }
        }
    }
}
