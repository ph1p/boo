import Foundation

/// tmux sessions Boo can attach to, on the local server and on each ssh
/// host; fetched in the background and cached.
@MainActor
enum TmuxSessions {
    struct Session: Equatable {
        let name: String
        let windows: Int
        let attached: Bool

        var summary: String {
            let count = windows == 1 ? "1 window" : "\(windows) windows"
            return attached ? "\(count), attached elsewhere" : count
        }
    }

    static let listFormat = "#{session_name}\t#{session_windows}\t#{session_attached}"

    /// Parses `tmux ls -F listFormat` output; malformed lines are skipped.
    nonisolated static func parse(_ output: String) -> [Session] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, let windows = Int(fields[1]) else { return nil }
            return Session(name: String(fields[0]), windows: windows, attached: (Int(fields[2]) ?? 0) > 0)
        }
    }

    /// The shell command that opens `attach` (or a new session) in control mode.
    nonisolated static func command(attach name: String?, host: String?) -> String {
        var tmux = "tmux -CC new-session"
        if let name { tmux += " -A -s \(LinkResolver.shellQuote(name))" }
        guard let host else { return "command \(tmux)" }
        return "ssh -t \(LinkResolver.shellQuote(host)) \(LinkResolver.shellQuote(tmux))"
    }

    // MARK: Local

    private static var localSessions: [Session] = []
    private static var fetchingLocal = false

    /// Last known sessions on the local server (empty when tmux is missing or
    /// not running); asks it again in the background, off the main thread.
    static func local() -> [Session] {
        if !fetchingLocal, let tmux = RemoteExplorer.findBinary("tmux") {
            fetchingLocal = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Subprocess.run(tmux, ["list-sessions", "-F", listFormat], timeout: 0.5)
                let sessions = result.map { $0.status == 0 ? parse($0.stdout) : [] } ?? []
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        fetchingLocal = false
                        localSessions = sessions
                    }
                }
            }
        }
        return localSessions
    }

    // MARK: Remote

    private static let hostsKey = "tmuxHosts"

    /// ssh hosts Boo started tmux on, newest first; only these get asked
    /// for sessions, so the palette never probes every known host.
    static var hosts: [String] { UserDefaults.standard.stringArray(forKey: hostsKey) ?? [] }

    static func remember(host: String) {
        let list = [host] + hosts.filter { $0 != host }
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: hostsKey)
    }

    private static var remote: [String: [Session]] = [:]
    private static var fetching: Set<String> = []

    /// Last known sessions on `host`; asks the host again in the background.
    static func remote(on host: String) -> [Session] {
        if !fetching.contains(host) {
            fetching.insert(host)
            let command = "tmux list-sessions -F '\(listFormat)' 2>/dev/null"
            RemoteExplorer.runRemoteCommand(session: .ssh(host: host, alias: host), command: command) { output in
                MainActor.assumeIsolated {
                    fetching.remove(host)
                    remote[host] = output.map(parse) ?? []
                }
            }
        }
        return remote[host] ?? []
    }
}
