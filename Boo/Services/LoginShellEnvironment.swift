import Foundation

/// The environment the user's login shell sets up, for helper processes Boo spawns
/// itself (ssh for the remote explorer, kubectl for the Kube plugin).
///
/// A GUI app inherits launchd's environment, not the shell's: an `SSH_AUTH_SOCK`
/// pointing at 1Password / Secretive / gpg-agent, a `KUBECONFIG` list, or a PATH with
/// mise/asdf/nix shims are only exported from the shell rc files. Terminal tabs see
/// them; Boo's background ssh/kubectl did not, so key auth and credential plugins
/// failed there while working fine in the tab next to it.
///
/// Resolved lazily, once, by running `$SHELL -ilc` (like VS Code does). Only a few
/// variables are taken over; the rest of the shell's environment is ignored.
final class LoginShellEnvironment: @unchecked Sendable {
    static let shared = LoginShellEnvironment()

    /// Variables copied from the login shell when it sets them.
    static let importedKeys = ["SSH_AUTH_SOCK", "KUBECONFIG", "PATH"]

    private let lock = NSLock()
    private var resolved: [String: String]?
    private var resolving = false
    private var waiters: [DispatchSemaphore] = []
    /// Failed captures so far and when the last one ended. A slow cold rc file
    /// (nvm, conda) can miss the timeout once; caching `[:]` for the whole
    /// session would strip SSH_AUTH_SOCK/KUBECONFIG/PATH from every spawn.
    private var failures = 0
    private var lastFailure: TimeInterval = 0
    static let maxAttempts = 3

    /// No login shell under XCTest: rc files are slow and machine-specific.
    nonisolated(unsafe) static var disabled = NSClassFromString("XCTestCase") != nil

    private let capturer: @Sendable (TimeInterval) -> [String: String]?
    private let isDisabled: Bool
    private let retryDelay: TimeInterval

    init(
        disabled: Bool = LoginShellEnvironment.disabled,
        retryDelay: TimeInterval = 10,
        capture: @escaping @Sendable (TimeInterval) -> [String: String]? = LoginShellEnvironment.capture
    ) {
        self.isDisabled = disabled
        self.retryDelay = retryDelay
        self.capturer = capture
    }

    /// Starts resolving in the background; cheap to call repeatedly.
    func prewarm() {
        lock.lock()
        let backoff = TimeInterval(failures) * retryDelay
        let start =
            resolved == nil && !resolving && !isDisabled && failures < Self.maxAttempts
            && booUptime() - lastFailure >= backoff
        if start { resolving = true }
        // Later attempts get more time: the first one may have raced a cold disk.
        let timeout: TimeInterval = failures == 0 ? 5 : 15
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { self.finish(self.capturer(timeout)) }
    }

    /// The imported variables, or nil while not resolved yet. Never blocks.
    var snapshot: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    /// The imported variables, waiting up to `timeout` for the first resolution.
    /// Call off the main thread only.
    func values(timeout: TimeInterval = 6) -> [String: String] {
        if isDisabled { return [:] }
        prewarm()
        lock.lock()
        if let resolved {
            lock.unlock()
            return resolved
        }
        guard resolving else {
            // Failed and backing off: nothing in flight to wait for.
            lock.unlock()
            return [:]
        }
        let sem = DispatchSemaphore(value: 0)
        waiters.append(sem)
        lock.unlock()
        _ = sem.wait(timeout: .now() + timeout)
        return snapshot ?? [:]
    }

    /// `base` (default: this process's environment) with the login shell's values
    /// applied. PATH is merged, keeping entries from both.
    func environment(
        base: [String: String] = ProcessInfo.processInfo.environment, wait: Bool = true
    )
        -> [String: String]
    {
        if !wait { prewarm() }
        let shell = wait ? values() : (snapshot ?? [:])
        return Self.merge(base: base, shell: shell)
    }

    /// Environment for an ssh spawn. Never blocks the main thread: there it uses
    /// whatever is resolved already (prewarmed at launch).
    static func sshEnvironment() -> [String: String] {
        shared.environment(wait: !Thread.isMainThread)
    }

    static func merge(base: [String: String], shell: [String: String]) -> [String: String] {
        var env = base
        for key in importedKeys where key != "PATH" {
            if let value = shell[key], !value.isEmpty { env[key] = value }
        }
        if let socket = env["SSH_AUTH_SOCK"], !isSocket(socket), let fallback = base["SSH_AUTH_SOCK"] {
            // A stale export (agent not running) is worse than launchd's agent.
            env["SSH_AUTH_SOCK"] = fallback
        }
        if let shellPath = shell["PATH"], !shellPath.isEmpty {
            env["PATH"] = mergePath(shellPath, env["PATH"] ?? "")
        }
        return env
    }

    static func mergePath(_ first: String, _ second: String) -> String {
        var seen = Set<String>()
        return (first.split(separator: ":") + second.split(separator: ":"))
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// `nil` = the capture failed: stay unresolved so a later `prewarm` retries.
    private func finish(_ values: [String: String]?) {
        lock.lock()
        if let values {
            resolved = values
        } else {
            failures += 1
            lastFailure = booUptime()
            if failures >= Self.maxAttempts { resolved = [:] }
        }
        resolving = false
        let waiting = waiters
        waiters = []
        lock.unlock()
        for sem in waiting { sem.signal() }
    }

    /// Marker printed before `env -0`, so rc-file output (motd, prompts) is skipped.
    private static let marker = "\u{1E}BOO_LOGIN_ENV\u{1E}"

    private static func capture(timeout: TimeInterval) -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        var env = ProcessInfo.processInfo.environment
        // Keep rc files from starting tmux/zellij or a fancy prompt setup on a pipe.
        env["TERM"] = "dumb"
        env["BOO_LOGIN_ENV_PROBE"] = "1"
        process.environment = env
        guard let result = RemoteExplorer.runProcessCapturing(process, timeout: timeout), result.status == 0 else {
            debugLog("[LoginShellEnvironment] \(shell) -ilc failed or timed out")
            return nil
        }
        return parse(result.stdout)
    }

    static func parse(_ output: String) -> [String: String] {
        guard let range = output.range(of: marker) else { return [:] }
        var values: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard importedKeys.contains(key) else { continue }
            values[key] = String(entry[entry.index(after: eq)...])
        }
        return values
    }
}
