import Darwin
import Foundation

/// Debug logger that writes to /tmp/boo-remote.log for diagnosing file tree issues.
func remoteLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    let path = "/tmp/boo-remote.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// The tool used to connect to a container or VM.
enum ContainerTool: String, Equatable {
    case docker
    case podman
    case nerdctl
    case kubectl
    case oc  // OpenShift CLI
    case lxc
    case limactl
    case colima
    case distrobox
    case toolbox
    case vagrant
    case adb

    /// Subcommands that give an interactive shell where file browsing works.
    /// For tools like docker/podman/nerdctl, both `exec` and `run` can be interactive.
    var interactiveSubcommands: [String] {
        switch self {
        case .docker, .podman, .nerdctl: return ["exec", "run"]
        case .kubectl, .oc: return ["exec"]
        case .lxc: return ["exec"]
        case .limactl: return ["shell"]
        case .colima, .vagrant: return ["ssh"]
        case .distrobox, .toolbox: return ["enter"]
        case .adb: return ["shell"]
        }
    }

    /// The primary subcommand used for remote command execution (file listing).
    var execSubcommand: String {
        switch self {
        case .docker, .podman, .nerdctl, .kubectl, .oc, .lxc: return "exec"
        case .limactl: return "shell"
        case .colima, .vagrant: return "ssh"
        case .distrobox, .toolbox: return "enter"
        case .adb: return "shell"
        }
    }

    /// Whether this tool requires -i or -t flags on `exec`/`run` to be interactive.
    /// Tools like distrobox/toolbox/limactl/vagrant are always interactive.
    var requiresInteractiveFlag: Bool {
        switch self {
        case .docker, .podman, .nerdctl, .kubectl, .oc: return true
        case .lxc, .limactl, .colima, .distrobox, .toolbox, .vagrant, .adb: return false
        }
    }

    /// SF Symbol icon name.
    var icon: String {
        switch self {
        case .docker, .podman, .nerdctl: return "shippingbox"
        case .kubectl, .oc: return "helm"
        case .lxc: return "cube"
        case .limactl, .colima: return "desktopcomputer"
        case .distrobox, .toolbox: return "wrench.and.screwdriver"
        case .vagrant: return "server.rack"
        case .adb: return "iphone"
        }
    }

    /// Display label for the tool.
    var label: String {
        switch self {
        case .oc: return "openshift"
        default: return rawValue
        }
    }

    /// All process names that should be detected for this tool.
    var processNames: [String] {
        switch self {
        case .docker: return ["docker"]
        case .podman: return ["podman"]
        case .nerdctl: return ["nerdctl"]
        case .kubectl: return ["kubectl"]
        case .oc: return ["oc"]
        case .lxc: return ["lxc"]
        case .limactl: return ["limactl", "lima"]
        case .colima: return ["colima"]
        case .distrobox: return ["distrobox"]
        case .toolbox: return ["toolbox"]
        case .vagrant: return ["vagrant"]
        case .adb: return ["adb"]
        }
    }

    /// All container tools, used for process tree scanning.
    static let all: [ContainerTool] = [
        .docker, .podman, .nerdctl, .kubectl, .oc, .lxc,
        .limactl, .colima, .distrobox, .toolbox, .vagrant, .adb
    ]

    /// Map from process name to tool, used for detection.
    static let byProcessName: [String: ContainerTool] = {
        var map: [String: ContainerTool] = [:]
        for tool in ContainerTool.all {
            for name in tool.processNames {
                map[name] = tool
            }
        }
        return map
    }()

    /// Extract the interactive target (container/pod/VM/image) from a shell-split command line.
    /// Returns nil for non-interactive commands such as `docker exec` without `-it`.
    func interactiveTarget(from args: [String]) -> String? {
        let lowerArgs = args.map { $0.lowercased() }
        let interactiveSubs = Set(interactiveSubcommands)
        guard let subIdx = lowerArgs.firstIndex(where: { interactiveSubs.contains($0) }) else {
            return nil
        }

        if requiresInteractiveFlag {
            let hasInteractive = lowerArgs.dropFirst(subIdx + 1).contains { flag in
                flag == "-it" || flag == "-ti" || flag == "-i" || flag == "-t"
                    || flag == "--interactive" || flag == "--tty"
                    || (flag.hasPrefix("-") && !flag.hasPrefix("--")
                        && (flag.contains("i") || flag.contains("t")))
            }
            if !hasInteractive { return nil }
        }

        var skipNext = false
        for index in (subIdx + 1)..<args.count {
            let arg = args[index]
            let lower = lowerArgs[index]

            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                break
            }
            if lower.hasPrefix("--"), let equalsIndex = lower.firstIndex(of: "=") {
                let option = String(lower[..<equalsIndex])
                if optionsWithValues.contains(option) {
                    continue
                }
            }
            if arg.hasPrefix("-") {
                if optionsWithValues.contains(lower) {
                    skipNext = true
                }
                continue
            }
            return Self.stripOuterShellQuotes(arg)
        }

        return nil
    }

    private var optionsWithValues: Set<String> {
        switch self {
        case .docker, .podman, .nerdctl:
            return [
                "-e", "--env",
                "--env-file",
                "-u", "--user",
                "-w", "--workdir",
                "--detach-keys",
                "--name"
            ]
        case .kubectl, .oc:
            return [
                "-n", "--namespace",
                "-c", "--container",
                "--context", "--kubeconfig"
            ]
        case .lxc:
            return ["-u", "--user"]
        case .limactl, .colima, .distrobox, .toolbox, .vagrant, .adb:
            return []
        }
    }

    private static func stripOuterShellQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("\"") && value.hasSuffix("\""))
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// The type of remote session detected.
enum RemoteSessionType {
    case ssh(host: String, alias: String? = nil)
    case mosh(host: String)
    case container(target: String, tool: ContainerTool)

    var displayName: String {
        switch self {
        case .ssh(let host, _): return host
        case .mosh(let host): return host
        case .container(let target, _): return target
        }
    }

    /// The target to use for SSH connections (alias if available, otherwise host).
    /// This matches what the user typed (e.g. "devbox") and what SSHControlManager keys on.
    var sshConnectionTarget: String {
        switch self {
        case .ssh(let host, let alias): return alias ?? host
        case .mosh(let host): return host
        case .container(let target, _): return target
        }
    }

    var icon: String {
        switch self {
        case .ssh: return "globe"
        case .mosh: return "globe.badge.chevron.backward"
        case .container(_, let tool): return tool.icon
        }
    }

    var connectingHint: String {
        switch self {
        case .ssh: return "Establishing SSH connection.\nFile explorer requires key-based auth or SSH agent."
        case .mosh: return "Establishing Mosh connection.\nFile explorer uses SSH for file listing."
        case .container(_, let tool): return "Waiting for \(tool.label) shell to start."
        }
    }

    /// True for session types that use SSH for file listing.
    var isSSHBased: Bool {
        switch self {
        case .ssh, .mosh: return true
        case .container(_, let tool):
            // vagrant ssh and colima ssh connect via SSH
            return tool == .vagrant || tool == .colima
        }
    }

    /// True for container/VM sessions (not SSH-based remote shells).
    var isContainer: Bool {
        if case .container = self { return true }
        return false
    }

    /// The tool label for display and `when` clause matching (e.g. "ssh", "docker", "kubectl").
    var envType: String {
        switch self {
        case .ssh: return "ssh"
        case .mosh: return "mosh"
        case .container(_, let tool): return tool.label
        }
    }
}

extension RemoteSessionType: Equatable {
    /// Alias is ignored for equality — prevents false transitions when alias is discovered.
    static func == (lhs: RemoteSessionType, rhs: RemoteSessionType) -> Bool {
        switch (lhs, rhs) {
        case (.ssh(let lhsHost, _), .ssh(let rhsHost, _)):
            return lhsHost == rhsHost
        case (.mosh(let lhsHost), .mosh(let rhsHost)):
            return lhsHost == rhsHost
        case (.container(let lhsTarget, let lhsTool), .container(let rhsTarget, let rhsTool)):
            return lhsTarget == rhsTarget && lhsTool == rhsTool
        default:
            return false
        }
    }
}
