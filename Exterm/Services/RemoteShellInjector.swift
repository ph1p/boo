import Foundation

/// Injects a CWD reporter into remote shells detected by TerminalBridge.
///
/// When an SSH session is detected (via title heuristics), the injector:
/// 1. Waits for a ControlMaster socket to appear (the user's SSH authenticates)
/// 2. Sends a POSIX init script over the socket that reports CWD via OSC 2 (set title)
/// 3. TerminalBridge.extractRemoteCwd parses the resulting "user@host:path" title
///
/// Falls back gracefully — if no socket is found (password auth, no ControlMaster),
/// the existing title heuristics continue to work.
final class RemoteShellInjector {
    /// Hosts that have already been injected (avoid double-injection).
    private var injectedHosts: Set<String> = []
    /// ControlMaster sockets we created (host → socket path).
    private var ownedSockets: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.exterm.remote-injector", qos: .userInitiated)

    /// POSIX-compatible script that reports CWD via OSC 2 (terminal title).
    /// Format: "user@host:path" — parsed by TerminalBridge.extractRemoteCwd.
    /// Uses OSC 2 instead of OSC 7 because Ghostty rejects OSC 7 from non-local hosts.
    static let remoteInitScript: String = [
        #"__exterm_report() {"#,
        #"  printf '\033]2;%s@%s:%s\a' "$(whoami)" "$(hostname -s 2>/dev/null || hostname)" "$PWD""#,
        #"  printf '\033]2;EXTERM_LS:%s:%s\a' "$PWD" "$(ls -1AF 2>/dev/null | head -500)""#,
        #"}"#,
        #"if [ -n "$ZSH_VERSION" ]; then"#,
        #"  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook chpwd __exterm_report"#,
        #"  precmd_functions+=(__exterm_report)"#,
        #"elif [ -n "$BASH_VERSION" ]; then"#,
        #"  PROMPT_COMMAND="__exterm_report${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#,
        #"fi"#,
        #"__exterm_report"#,
    ].joined(separator: "\n")

    static let remoteInitBase64: String = {
        Data(remoteInitScript.utf8).base64EncodedString()
    }()

    /// Attempt to inject CWD reporter into a remote SSH session.
    /// Called on a background queue. Safe to call multiple times for the same host.
    func injectIfNeeded(host: String) {
        queue.async { [weak self] in
            self?.doInject(host: host)
        }
    }

    /// Clean up when an SSH session to this host ends.
    func sessionEnded(host: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.injectedHosts.remove(host)
            if let socket = self.ownedSockets.removeValue(forKey: host) {
                // Tell SSH to close the ControlMaster socket
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-o", "ControlPath=\(socket)", "-O", "exit", host]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                try? process.run()
                // Fire and forget — don't block on socket cleanup
            }
        }
    }

    /// Clean up all owned sockets (call on app termination).
    func cleanupAll() {
        for host in ownedSockets.keys {
            sessionEnded(host: host)
        }
    }

    // MARK: - Private

    private func doInject(host: String) {
        guard !injectedHosts.contains(host) else { return }

        // Poll for a ControlMaster socket (the user's SSH may still be authenticating)
        for _ in 0..<8 {
            if let socket = RemoteExplorer.findControlSocket(host: host) {
                if injectViaSocket(host: host, socketPath: socket) {
                    injectedHosts.insert(host)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // No socket found — injection not possible (password auth / no ControlMaster).
        // The existing title heuristics still provide basic remote detection.
    }

    private func injectViaSocket(host: String, socketPath: String) -> Bool {
        let cmd = "eval \"$(echo \(Self.remoteInitBase64) | base64 -d)\" 2>/dev/null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-n",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=2",
            "-o", "ControlPath=\(socketPath)",
            host, cmd,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
