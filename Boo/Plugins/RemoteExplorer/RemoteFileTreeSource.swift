import Foundation

/// Decides whether a failed remote listing is worth retrying, and when.
///
/// A listing fails at the transport level (not "folder unreadable") mostly while the SSH
/// master is still coming up or after it died, so the decision follows the managed
/// connection's state: poll while it connects, rebuild a `.ready` master once, give up on
/// `.failed`. Non-SSH targets (containers) get a short fixed budget.
struct RemoteListingRetryPolicy: Equatable {
    static let initialBudget = 15

    private(set) var retriesLeft = Self.initialBudget
    /// Set once a rebuild of a dead `.ready` master was requested, so later attempts poll
    /// that rebuild instead of spawning a new one each tick.
    private(set) var requestedReconnect = false

    struct Step: Equatable {
        let delay: TimeInterval
        /// Ask `SSHControlManager` to rebuild the master before waiting.
        let reconnect: Bool
    }

    /// The next retry after a failed attempt, or nil to give up.
    mutating func next(isSSHBased: Bool, state: SSHControlManager.ConnectionState?) -> Step? {
        let shouldRetry: Bool
        let delay: TimeInterval
        var reconnect = false
        if isSSHBased {
            switch state {
            case .connecting:
                shouldRetry = retriesLeft > 0
                delay = 1
            case .failed:
                shouldRetry = false
                delay = 0
            case .ready:
                // The connection looked live but the command failed — the master likely
                // died (network blip, sleep, idle timeout). Rebuild once, then poll.
                shouldRetry = retriesLeft > 10
                delay = 1
                if shouldRetry && !requestedReconnect {
                    requestedReconnect = true
                    reconnect = true
                }
            case nil:
                shouldRetry = retriesLeft > 5
                delay = 2
            }
        } else {
            shouldRetry = retriesLeft > 10
            delay = 2
        }
        guard shouldRetry else { return nil }
        retriesLeft -= 1
        return Step(delay: delay, reconnect: reconnect)
    }
}

/// `FileTreeSource` for an SSH/mosh session or a container: every operation is one
/// remote shell round-trip through `RemoteExplorer.runRemoteCommand`.
///
/// Scripts are POSIX `sh` (wrapped in `sh -c`, so a fish/csh login shell doesn't matter)
/// and always `exit 0`: a non-zero exit is indistinguishable from "unreachable" in
/// `runRemoteCommand`, so per-item failures travel in-band as marker lines instead.
final class RemoteFileTreeSource: FileTreeSource, @unchecked Sendable {
    let session: RemoteSessionType

    init(session: RemoteSessionType) {
        self.session = session
    }

    var isLocal: Bool { false }

    private let stateLock = NSLock()
    private var unreachable = false
    /// True when the latest listing gave up because the target couldn't be reached
    /// (as opposed to a folder that exists but can't be read).
    var isUnreachable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unreachable
    }

    private func setUnreachable(_ value: Bool) {
        stateLock.lock()
        unreachable = value
        stateLock.unlock()
    }

    /// Separates the per-directory sections of a batched listing.
    static let sectionMarker = "\u{1E}"
    /// A section holding only this line is a directory that can't be read.
    static let unreadableMarker = "\u{15}"
    /// Prefix of the line a file operation prints when it failed (followed by stderr).
    static let failureMarker = "\u{1D}FAIL"

    // MARK: - Transport

    /// Run a POSIX script remotely. nil when the target couldn't be reached.
    func run(_ script: String) async -> String? {
        let session = session
        let command = "sh -c \(shellEscape(script))"
        return await withCheckedContinuation { continuation in
            RemoteExplorer.runRemoteCommand(session: session, command: command) { output in
                continuation.resume(returning: output)
            }
        }
    }

    /// `run`, retried per `RemoteListingRetryPolicy` while the connection settles.
    func runRetrying(_ script: String) async -> String? {
        var policy = RemoteListingRetryPolicy()
        while true {
            if let output = await run(script) { return output }
            // Tests stub out ssh: nothing will come up, so don't poll for it.
            if session.isSSHBased && RemoteExplorer.disableRealSSH { return nil }
            let target = session.sshConnectionTarget
            let state = session.isSSHBased ? SSHControlManager.shared.connectionState(for: target) : nil
            guard let step = policy.next(isSSHBased: session.isSSHBased, state: state) else {
                remoteLog("[RemoteFileTreeSource] giving up: target=\(target)")
                return nil
            }
            if step.reconnect {
                SSHControlManager.shared.ensureConnection(alias: target) { _ in }
            }
            try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
        }
    }

    // MARK: - FileTreeSource

    func list(_ paths: [String]) async -> [[FileTreeNode.Entry]?] {
        guard !paths.isEmpty else { return [] }
        guard let output = await runRetrying(Self.listScript(paths)) else {
            setUnreachable(true)
            return paths.map { _ in nil }
        }
        setUnreachable(false)
        return Self.parseListing(output, paths: paths)
    }

    func buildIndex(rootPath: String, showHidden: Bool) async -> [FileTreeIndexEntry] {
        guard let output = await run(Self.indexScript(rootPath)) else { return [] }
        return Self.parseIndex(output, showHidden: showHidden)
    }

    func gitStatus(rootPath: String) async -> FileTreeGitStatus? {
        guard let output = await run(Self.gitStatusScript(rootPath)) else { return nil }
        return Self.parseGitStatus(output, rootPath: rootPath)
    }

    /// Size and modification time for the row tooltip.
    func info(_ path: String) async -> String? {
        guard let output = await run(Self.infoScript(path)) else { return nil }
        return Self.parseInfo(output)
    }

    /// Run a file operation. Returns nil on success, else a message for the user.
    func perform(_ script: String) async -> String? {
        guard let output = await run(script) else { return "Remote host unreachable" }
        return Self.failureMessage(in: output)
    }

    /// Which of `names` already exist in `directory`.
    func existingNames(_ names: [String], in directory: String) async -> [String]? {
        let quoted = names.map(shellEscape).joined(separator: " ")
        let script =
            "cd \(RemoteExplorer.shellEscPath(directory)) 2>/dev/null || exit 0; "
            + "for n in \(quoted); do if [ -e \"$n\" ] || [ -L \"$n\" ]; then printf '%s\\n' \"$n\"; fi; done; exit 0"
        guard let output = await run(script) else { return nil }
        return output.split(separator: "\n").map(String.init)
    }

    // MARK: - Scripts

    static func listScript(_ paths: [String]) -> String {
        let quoted = paths.map(RemoteExplorer.shellEscPath).joined(separator: " ")
        return "for d in \(quoted); do printf '\\036\\n'; "
            + "if [ -d \"$d\" ] && [ -r \"$d\" ] && [ -x \"$d\" ]; then ls -1Ap \"$d\" 2>/dev/null; "
            + "else printf '\\025\\n'; fi; done; exit 0"
    }

    static func indexScript(_ rootPath: String) -> String {
        let prune = FileTreeIndex.skippedDirectories.sorted()
            .map { "-name \(shellEscape($0))" }.joined(separator: " -o ")
        return "cd \(RemoteExplorer.shellEscPath(rootPath)) 2>/dev/null || exit 0; "
            + "if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf 'G\\n'; "
            + "git ls-files -z --cached --others --exclude-standard 2>/dev/null; "
            + "else printf 'F\\n'; find . \\( \(prune) \\) -prune -o -type f -print 2>/dev/null | head -n 50000; fi; "
            + "exit 0"
    }

    static func gitStatusScript(_ rootPath: String) -> String {
        "cd \(RemoteExplorer.shellEscPath(rootPath)) 2>/dev/null || exit 0; "
            + "p=$(git rev-parse --show-prefix 2>/dev/null) || exit 0; printf '%s\\036' \"$p\"; "
            + "git --no-optional-locks status --porcelain=v1 -z --ignored=matching -- . 2>/dev/null; exit 0"
    }

    static func infoScript(_ path: String) -> String {
        let p = RemoteExplorer.shellEscPath(path)
        return "stat -c '%s %Y %F' \(p) 2>/dev/null || stat -f '%z %m %HT' \(p) 2>/dev/null; exit 0"
    }

    /// Wrap a file-operation body so a failure prints the marker plus stderr.
    static func operationScript(_ body: String) -> String {
        "err=$( { \(body) ; } 2>&1 >/dev/null ) || printf '\\035FAIL%s' \"$err\"; exit 0"
    }

    // MARK: - Parsing

    static func parseListing(_ output: String, paths: [String]) -> [[FileTreeNode.Entry]?] {
        var sections = output.components(separatedBy: sectionMarker + "\n")
        // Anything before the first marker is shell noise (motd, rc-file output).
        if !sections.isEmpty { sections.removeFirst() }
        return paths.enumerated().map { index, dir -> [FileTreeNode.Entry]? in
            guard index < sections.count else { return nil }
            let lines = sections[index].split(separator: "\n", omittingEmptySubsequences: true)
            if lines.first == Substring(unreadableMarker) { return nil }
            let entries = lines.compactMap { line -> FileTreeNode.Entry? in
                var name = String(line)
                let isDir = name.hasSuffix("/")
                if isDir { name.removeLast() }
                guard !name.isEmpty else { return nil }
                return FileTreeNode.Entry(name: name, path: childPath(dir, name), isDir: isDir)
            }
            return FileTreeNode.sorted(entries)
        }
    }

    static func parseIndex(_ output: String, showHidden: Bool) -> [FileTreeIndexEntry] {
        if output.hasPrefix("G\n") {
            let files = output.dropFirst(2).split(separator: "\0").map(String.init)
            return FileTreeIndex.entries(fromRelativeFiles: files, showHidden: showHidden, limit: 50_000)
        }
        guard output.hasPrefix("F\n") else { return [] }
        let files = output.dropFirst(2).split(separator: "\n").map { line -> String in
            line.hasPrefix("./") ? String(line.dropFirst(2)) : String(line)
        }
        return FileTreeIndex.entries(fromRelativeFiles: files, showHidden: showHidden, limit: 50_000)
    }

    static func parseGitStatus(_ output: String, rootPath: String) -> FileTreeGitStatus? {
        guard let marker = output.firstIndex(of: Character(sectionMarker)) else { return nil }
        let prefix = output[..<marker].trimmingCharacters(in: .whitespacesAndNewlines)
        var repoRoot = rootPath
        for _ in 0..<prefix.split(separator: "/").count {
            repoRoot = (repoRoot as NSString).deletingLastPathComponent
        }
        return FileTreeGitStatus(repoRoot: repoRoot, porcelainZ: String(output[output.index(after: marker)...]))
    }

    static func parseInfo(_ output: String) -> String? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
        guard parts.count == 3, let size = Int64(parts[0]), let mtime = TimeInterval(parts[1]) else { return nil }
        let isDir = parts[2].lowercased().hasPrefix("directory")
        return FileTreeInfo.summary(size: isDir ? nil : size, modified: Date(timeIntervalSince1970: mtime))
    }

    static func failureMessage(in output: String) -> String? {
        guard let range = output.range(of: failureMarker) else { return nil }
        let detail = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Remote command failed" : String(detail.prefix(200))
    }

    static func childPath(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }
}
