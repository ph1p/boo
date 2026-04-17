import Darwin
import Foundation

/// Debug logger for diagnosing remote file-tree issues. No-op in release builds.
func remoteLog(_ message: String) {
    #if DEBUG
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(message)\n"
        // Use the app's private temp directory so the log is not world-readable.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boo", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700
            ])
        let logURL = dir.appendingPathComponent("remote.log")
        let path = logURL.path
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) { handle.write(data) }
            handle.closeFile()
        } else {
            FileManager.default.createFile(
                atPath: path, contents: line.data(using: .utf8),
                attributes: [
                    .posixPermissions: 0o600
                ])
        }
    #endif
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

    // MARK: - Spec

    private struct Spec {
        let interactiveSubcommands: [String]
        let execSubcommand: String
        /// Whether -i or -t flags are required for interactive exec/run.
        let requiresInteractiveFlag: Bool
        let icon: String
        let label: String
        let processNames: [String]
    }

    // Factories for groups sharing the same fixed properties.
    private static func dockerCompatSpec(label: String) -> Spec {
        Spec(
            interactiveSubcommands: ["exec", "run"], execSubcommand: "exec",
            requiresInteractiveFlag: true, icon: "shippingbox",
            label: label, processNames: [label])
    }

    private static func k8sSpec(label: String, processName: String) -> Spec {
        Spec(
            interactiveSubcommands: ["exec"], execSubcommand: "exec",
            requiresInteractiveFlag: true, icon: "helm",
            label: label, processNames: [processName])
    }

    private static func enterSpec(label: String) -> Spec {
        Spec(
            interactiveSubcommands: ["enter"], execSubcommand: "enter",
            requiresInteractiveFlag: false, icon: "wrench.and.screwdriver",
            label: label, processNames: [label])
    }

    private var spec: Spec {
        switch self {
        case .docker: return Self.dockerCompatSpec(label: "docker")
        case .podman: return Self.dockerCompatSpec(label: "podman")
        case .nerdctl: return Self.dockerCompatSpec(label: "nerdctl")
        case .kubectl: return Self.k8sSpec(label: "kubectl", processName: "kubectl")
        case .oc: return Self.k8sSpec(label: "openshift", processName: "oc")
        case .lxc:
            return Spec(
                interactiveSubcommands: ["exec"], execSubcommand: "exec",
                requiresInteractiveFlag: false, icon: "cube",
                label: "lxc", processNames: ["lxc"])
        case .limactl:
            return Spec(
                interactiveSubcommands: ["shell"], execSubcommand: "shell",
                requiresInteractiveFlag: false, icon: "desktopcomputer",
                label: "limactl", processNames: ["limactl", "lima"])
        case .colima:
            return Spec(
                interactiveSubcommands: ["ssh"], execSubcommand: "ssh",
                requiresInteractiveFlag: false, icon: "desktopcomputer",
                label: "colima", processNames: ["colima"])
        case .distrobox: return Self.enterSpec(label: "distrobox")
        case .toolbox: return Self.enterSpec(label: "toolbox")
        case .vagrant:
            return Spec(
                interactiveSubcommands: ["ssh"], execSubcommand: "ssh",
                requiresInteractiveFlag: false, icon: "server.rack",
                label: "vagrant", processNames: ["vagrant"])
        case .adb:
            return Spec(
                interactiveSubcommands: ["shell"], execSubcommand: "shell",
                requiresInteractiveFlag: false, icon: "iphone",
                label: "adb", processNames: ["adb"])
        }
    }

    // MARK: - Public API

    var interactiveSubcommands: [String] { spec.interactiveSubcommands }
    var execSubcommand: String { spec.execSubcommand }
    var requiresInteractiveFlag: Bool { spec.requiresInteractiveFlag }
    var icon: String { spec.icon }
    var label: String { spec.label }
    var processNames: [String] { spec.processNames }

    // MARK: - Static helpers

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

    // MARK: - Interactive target detection

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
