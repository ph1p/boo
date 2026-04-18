import Combine
import XCTest

@testable import Boo

@MainActor final class TerminalBridgeTests: XCTestCase {
    nonisolated(unsafe) private var bridge: TerminalBridge!
    nonisolated(unsafe) private var cancellables: Set<AnyCancellable>!
    private let paneID = UUID()
    private let workspaceID = UUID()
    private let localHome = NSHomeDirectory()

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            cancellables = []
            bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            cancellables = nil
            bridge = nil
        }
        try await super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(bridge.state.paneID, paneID)
        XCTAssertEqual(bridge.state.workspaceID, workspaceID)
        XCTAssertEqual(bridge.state.workingDirectory, "/tmp")
        XCTAssertEqual(bridge.state.terminalTitle, "")
        XCTAssertEqual(bridge.state.foregroundProcess, "")
        XCTAssertNil(bridge.state.remoteSession)
        XCTAssertNil(bridge.state.remoteCwd)
        XCTAssertFalse(bridge.state.isDockerAvailable)
    }

    func testDirectoryChangeEmitsEvent() {
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleDirectoryChange(path: "/Users/test", paneID: paneID)

        XCTAssertEqual(bridge.state.workingDirectory, "/Users/test")
        XCTAssertTrue(events.contains(.directoryChanged(path: "/Users/test")))
    }

    func testDuplicateDirectoryIgnored() {
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleDirectoryChange(path: "/tmp", paneID: paneID)  // same as initial
        XCTAssertTrue(events.isEmpty)
    }

    func testDirectoryChangeFromWrongPaneIgnored() {
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        let otherPane = UUID()
        bridge.handleDirectoryChange(path: "/Users/other", paneID: otherPane)

        XCTAssertEqual(bridge.state.workingDirectory, "/tmp")
        XCTAssertTrue(events.isEmpty)
    }

    func testTitleChangeExtractsProcess() {
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleTitleChange(title: "vim file.txt", paneID: paneID)

        XCTAssertEqual(bridge.state.foregroundProcess, "vim")
        XCTAssertEqual(bridge.state.terminalTitle, "vim file.txt")
        XCTAssertTrue(events.contains(.titleChanged(title: "vim file.txt")))
        XCTAssertTrue(events.contains(.processChanged(name: "vim")))
    }

    func testTitleUpdatesProcess() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "vim")

        bridge.handleTitleChange(title: "nvim", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "nvim")
    }

    func testTitleWithSpinnerMatchesClaude() {
        // Spinner-prefixed titles match "claude" via matchTitle
        bridge.handleTitleChange(title: "⠂ General coding assistance", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "✳ Claude Code", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")
    }

    func testSwitchContextResetsState() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        bridge.handleDirectoryChange(path: "/Users/test", paneID: paneID)

        let newPaneID = UUID()
        let newWorkspaceID = UUID()
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.switchContext(paneID: newPaneID, workspaceID: newWorkspaceID, workingDirectory: "/home")

        XCTAssertEqual(bridge.state.paneID, newPaneID)
        XCTAssertEqual(bridge.state.workspaceID, newWorkspaceID)
        XCTAssertEqual(bridge.state.workingDirectory, "/home")
        XCTAssertEqual(bridge.state.terminalTitle, "")
        XCTAssertEqual(bridge.state.foregroundProcess, "")
        XCTAssertNil(bridge.state.remoteSession)
        XCTAssertTrue(events.contains(.workspaceSwitched(workspaceID: newWorkspaceID)))
    }

    func testFocusChangeEmitsEvent() {
        let newPane = UUID()
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleFocus(paneID: newPane, workingDirectory: "/home/user")

        XCTAssertEqual(bridge.state.paneID, newPane)
        XCTAssertEqual(bridge.state.workingDirectory, "/home/user")
        XCTAssertTrue(events.contains(.focusChanged(paneID: newPane)))
    }

    func testProcessExitClearsRemote() {
        // Set up a remote session via title heuristic
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        bridge.handleTitleChange(title: "user@remote-host: ~", paneID: paneID)

        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleProcessExit(paneID: paneID)

        XCTAssertNil(bridge.state.remoteSession)
        XCTAssertEqual(bridge.state.foregroundProcess, "")
        XCTAssertEqual(bridge.state.terminalTitle, "")
    }

    func testMultipleEventsSequence() {
        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        bridge.handleDirectoryChange(path: "/Users/test/project", paneID: paneID)
        bridge.handleTitleChange(title: "make build", paneID: paneID)

        XCTAssertEqual(bridge.state.foregroundProcess, "make")
        XCTAssertEqual(bridge.state.workingDirectory, "/Users/test/project")
        XCTAssertTrue(events.count >= 3)
    }

    // MARK: - extractProcessName

    func testExtractProcessName() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: ""), "")
        // Shell names are filtered out
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "zsh"), "")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "bash"), "")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "fish"), "")
        // Real processes are kept
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "vim file.txt"), "vim")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "python3 script.py"), "python3")
        // Remote user@host is kept
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "user@remote-server: ~/dir"), "user@remote-server")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "  "), "")
    }

    // MARK: - Remote Detection Heuristics

    func testSSHDetectionHeuristic() {
        // user@host in title → SSH (no filesystem check needed)
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "user@remote-server: /home/user",
            cwd: "/tmp"
        )
        if case .ssh(let host, _) = result {
            XCTAssertTrue(host.contains("@"))
            XCTAssertTrue(host.contains("remote-server"))
        } else {
            XCTFail("Expected SSH detection, got \(String(describing: result))")
        }
    }

    func testDockerDetectionHeuristic() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "docker exec -it mycontainer bash",
            cwd: "/tmp"
        )
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "mycontainer")
            XCTAssertEqual(tool, .docker)
        } else {
            XCTFail("Expected Docker detection, got \(String(describing: result))")
        }
    }

    func testDockerDetectionHeuristicWithAbsoluteBinaryPath() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "/usr/local/bin/docker exec -it mycontainer bash",
            cwd: "/tmp"
        )
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "mycontainer")
            XCTAssertEqual(tool, .docker)
        } else {
            XCTFail("Expected Docker detection for absolute binary path, got \(String(describing: result))")
        }
    }

    func testDockerDetectionHeuristicSkipsOptionValuePairs() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "docker exec --user root --workdir /app -it mycontainer bash",
            cwd: "/tmp"
        )
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "mycontainer")
            XCTAssertEqual(tool, .docker)
        } else {
            XCTFail("Expected Docker detection, got \(String(describing: result))")
        }
    }

    func testDockerHexPromptDetectionHeuristic() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "root@195cad4b6562:/app",
            cwd: "/tmp"
        )
        XCTAssertEqual(result, .container(target: "195cad4b6562", tool: .docker))
    }

    func testPodmanDetectionHeuristic() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "podman exec -it mycontainer bash",
            cwd: "/tmp"
        )
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "mycontainer")
            XCTAssertEqual(tool, .podman)
        } else {
            XCTFail("Expected Podman detection, got \(String(describing: result))")
        }
    }

    func testKubectlDetectionHeuristic() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "kubectl exec -it my-pod -- bash",
            cwd: "/tmp"
        )
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "my-pod")
            XCTAssertEqual(tool, .kubectl)
        } else {
            XCTFail("Expected kubectl detection, got \(String(describing: result))")
        }
    }

    func testLocalSessionNotDetectedAsRemote() {
        // user@localhost is not remote even with existing CWD
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "user@localhost: /tmp",
            cwd: "/tmp"
        )
        XCTAssertNil(result)
    }

    func testRemoteSessionDetectedEvenWhenCwdExistsLocally() {
        // user@remote-host:/tmp should be detected as remote even though /tmp exists locally
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "user@remote-host: /tmp",
            cwd: "/tmp"
        )
        if case .ssh(let host, _) = result {
            XCTAssertTrue(host.contains("remote-host"))
        } else {
            XCTFail("Expected SSH detection, got \(String(describing: result))")
        }
    }

    func testEmptyTitleNotDetectedAsRemote() {
        let result = TerminalBridge.detectRemoteFromHeuristics(title: "", cwd: "/tmp")
        XCTAssertNil(result)
    }

    func testLocalhostNotDetectedAsSSH() {
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "user@localhost: /home",
            cwd: "/tmp"
        )
        XCTAssertNil(result)
    }

    func testNpmScopedPackageNotDetectedAsSSH() {
        // "bunx @scope/package" — scoped package, empty user before "@"
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "bunx @scope/package", cwd: "/tmp"))
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "npx @scope/package", cwd: "/tmp"))
        // "@scope/package" as first word — empty user part, still not SSH
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "@scope/package", cwd: "/tmp"))
    }

    func testNpmVersionTagNotDetectedAsSSH() {
        // "npx any-buddy@latest" — package@version as an argument to npx/bunx.
        // "any-buddy" is the user and "latest" the host only by accident; this is npm syntax.
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "npx any-buddy@latest", cwd: "/tmp"))
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "bunx any-buddy@latest", cwd: "/tmp"))
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "npx pkg@2.0.0", cwd: "/tmp"))
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "bunx @scope/tool --flag value", cwd: "/tmp"))
    }

    func testGitForgeSSHUrlNotDetectedAsInteractiveRemote() {
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "git@github.com:org/repo.git", cwd: "/tmp")
        )
    }

    func testCustomGitHostNotDetectedAsInteractiveRemote() {
        // "git clone git@git.gwvs.de:org/repo" — user is "git", non-interactive transport
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "git@git.gwvs.de:org/repo.git", cwd: "/tmp")
        )
    }

    func testGitUserSSHCommandNotDetectedAsInteractiveRemote() {
        // Terminal title shows "ssh git@git.gwvs.de" during a git clone — not a shell session
        XCTAssertNil(
            TerminalBridge.detectRemoteFromProcessName(title: "ssh git@git.gwvs.de")
        )
    }

    func testRealSSHStillDetectedAfterScopedPackageFix() {
        // Genuine SSH sessions must continue to be detected.
        // The prompt "user@remote-server:~" is the first (and only) word — still SSH.
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "user@remote-server:~", cwd: "/tmp")
        if case .ssh(let host, _) = result {
            XCTAssertTrue(host.contains("remote-server"))
        } else {
            XCTFail("Expected SSH session to be detected")
        }
    }

    func testResolveRemoteSessionRetainsPreviousRemoteForBlankTitle() {
        let previous = RemoteSessionType.ssh(host: "user@remote-host")
        let result = TerminalBridge.resolveRemoteSession(
            title: "",
            cwd: "/tmp",
            previous: previous
        )

        XCTAssertEqual(result, previous)
    }

    func testResolveRemoteSessionRetainsPreviousRemoteForRemotePromptOnCommonPath() {
        let previous = RemoteSessionType.ssh(host: "user@remote-host")
        let result = TerminalBridge.resolveRemoteSession(
            title: "user@remote-host:/tmp",
            cwd: "/tmp",
            previous: previous
        )

        XCTAssertEqual(result, previous)
    }

    func testResolveRemoteSessionClearsPreviousRemoteForExplicitLocalTitle() {
        let previous = RemoteSessionType.ssh(host: "user@remote-host")
        let result = TerminalBridge.resolveRemoteSession(
            title: "zsh",
            cwd: "/tmp",
            previous: previous
        )

        XCTAssertNil(result)
    }

    func testResolveRemoteSessionKeepsPreviousRemoteDuringCwdEventWithLocalLookingTitle() {
        let previous = RemoteSessionType.ssh(host: "user@remote-host")
        let result = TerminalBridge.resolveRemoteSession(
            title: "user@localhost:/Users/testuser/project",
            cwd: "/tmp",
            previous: previous,
            preferPreviousForCwdEvent: true
        )

        XCTAssertEqual(result, previous)
    }

    func testDirectoryChangeKeepsExistingRemoteSessionWhenTitleIsStaleLocalPrompt() {
        bridge = TerminalBridge(
            paneID: paneID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/testuser/project"
        )

        bridge.handleTitleChange(title: "ssh user@remote-host", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "user@remote-host"))

        bridge.handleTitleChange(title: "user@localhost:/Users/testuser/project", paneID: paneID)
        XCTAssertNil(bridge.state.remoteSession)

        // Simulate MainWindowController keeping the remote session on the pane while the
        // bridge still has a stale local-looking title during a remote OSC 7 CWD update.
        bridge.handleTitleChange(title: "ssh user@remote-host", paneID: paneID)
        bridge.handleDirectoryChange(path: "/tmp", paneID: paneID)

        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "user@remote-host"))
    }

    // MARK: - detectRemoteFromProcessName

    func testSSHProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "ssh user@prod-server")
        if case .ssh(let host, _) = result {
            XCTAssertEqual(host, "user@prod-server")
        } else {
            XCTFail("Expected SSH detection, got \(String(describing: result))")
        }
    }

    func testSSHProcessWithFlagsDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "ssh -p 2222 -i ~/.ssh/key user@staging")
        if case .ssh(let host, _) = result {
            XCTAssertEqual(host, "user@staging")
        } else {
            XCTFail("Expected SSH detection, got \(String(describing: result))")
        }
    }

    func testDockerProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "docker exec -it postgres bash")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "postgres")
            XCTAssertEqual(tool, .docker)
        } else {
            XCTFail("Expected Docker detection, got \(String(describing: result))")
        }
    }

    func testDockerProcessDetectionSkipsOptionValuePairs() {
        let result = TerminalBridge.detectRemoteFromProcessName(
            title: "docker exec --user root --workdir /app -it postgres bash")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "postgres")
            XCTAssertEqual(tool, .docker)
        } else {
            XCTFail("Expected Docker detection, got \(String(describing: result))")
        }
    }

    func testMoshProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "mosh user@server")
        if case .mosh(let host) = result {
            XCTAssertEqual(host, "user@server")
        } else {
            XCTFail("Expected Mosh detection, got \(String(describing: result))")
        }
    }

    func testKubectlProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "kubectl exec -it my-pod -- bash")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "my-pod")
            XCTAssertEqual(tool, .kubectl)
        } else {
            XCTFail("Expected kubectl detection, got \(String(describing: result))")
        }
    }

    func testVagrantProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "vagrant ssh default")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "default")
            XCTAssertEqual(tool, .vagrant)
        } else {
            XCTFail("Expected Vagrant detection, got \(String(describing: result))")
        }
    }

    func testDistroboxProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "distrobox enter ubuntu")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "ubuntu")
            XCTAssertEqual(tool, .distrobox)
        } else {
            XCTFail("Expected Distrobox detection, got \(String(describing: result))")
        }
    }

    func testAdbProcessDetection() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "adb shell ls")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "ls")
            XCTAssertEqual(tool, .adb)
        } else {
            XCTFail("Expected ADB detection, got \(String(describing: result))")
        }
    }

    func testNonRemoteProcessDetection() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "vim file.txt"))
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: ""))
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "make build"))
    }

    // MARK: - Non-interactive commands must NOT be detected

    func testDockerLogsNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "docker logs -f mycontainer"))
        XCTAssertNil(TerminalBridge.detectRemoteFromHeuristics(title: "docker logs -f mycontainer", cwd: "/tmp"))
    }

    func testDockerBuildNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "docker build -t myimage ."))
        XCTAssertNil(TerminalBridge.detectRemoteFromHeuristics(title: "docker build -t myimage .", cwd: "/tmp"))
    }

    func testDockerRunWithoutInteractiveFlagsNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "docker run --rm myimage echo hello"))
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "docker run --rm myimage echo hello", cwd: "/tmp"))
    }

    func testDockerExecWithoutInteractiveFlagsNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "docker exec mycontainer cat /etc/hostname"))
        XCTAssertNil(
            TerminalBridge.detectRemoteFromHeuristics(title: "docker exec mycontainer cat /etc/hostname", cwd: "/tmp"))
    }

    func testDockerRunInteractiveDetected() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "docker run -it ubuntu bash")
        if case .container(let target, let tool) = result {
            XCTAssertEqual(target, "ubuntu")
            XCTAssertEqual(tool, .docker)
        } else {
            XCTFail("Expected Docker run detection, got \(String(describing: result))")
        }
    }

    func testDockerPsNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "docker ps"))
        XCTAssertNil(TerminalBridge.detectRemoteFromHeuristics(title: "docker ps", cwd: "/tmp"))
    }

    func testKubectlExecWithoutInteractiveFlagsNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "kubectl exec my-pod -- cat /etc/hostname"))
    }

    func testKubectlLogsNotDetected() {
        XCTAssertNil(TerminalBridge.detectRemoteFromProcessName(title: "kubectl logs my-pod"))
        XCTAssertNil(TerminalBridge.detectRemoteFromHeuristics(title: "kubectl logs my-pod", cwd: "/tmp"))
    }

    func testSSHLocalhostNotRemote() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "ssh localhost")
        XCTAssertNil(result)
    }

    // MARK: - isLocalHost / Local Identity

    func testIsLocalHostKnownAliases() {
        // These must always be local
        XCTAssertTrue(TerminalBridge.isLocalHost("localhost"))
        XCTAssertTrue(TerminalBridge.isLocalHost("127.0.0.1"))
        XCTAssertTrue(TerminalBridge.isLocalHost("Localhost"))  // case-insensitive
    }

    func testIsLocalHostMatchesAllHostnameVariants() {
        // localHostnames should contain at least gethostname, ProcessInfo, SCDynamicStore names
        let names = TerminalBridge.localHostnames
        XCTAssertTrue(
            names.count >= 3, "Should have at least localhost, 127.0.0.1, and one real hostname, got: \(names)")

        // gethostname(2) result
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0, let hn = String(validating: buf, as: UTF8.self), !hn.isEmpty {
            XCTAssertTrue(TerminalBridge.isLocalHost(hn), "gethostname '\(hn)' should be local")
        }
    }

    func testIsLocalHostRejectsRemote() {
        XCTAssertFalse(TerminalBridge.isLocalHost("remote-server"))
        XCTAssertFalse(TerminalBridge.isLocalHost("prod-db-01"))
        XCTAssertFalse(TerminalBridge.isLocalHost("fileserv"))
        XCTAssertFalse(TerminalBridge.isLocalHost("devbox"))
    }

    func testLocalUserAtHostNotDetectedAsRemote() {
        // The real local hostname from gethostname — simulates "user@hostname" style prompt
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0,
            let hn = String(validating: buf, as: UTF8.self), !hn.isEmpty
        else {
            return  // Can't test without a hostname
        }
        let localUser = NSUserName()

        // "user@localhostname: ~/dir" must NOT be detected as remote
        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "\(localUser)@\(hn): ~/dir",
            cwd: "/tmp"
        )
        XCTAssertNil(result, "\(localUser)@\(hn) should be local, not remote")

        // titleLooksRemote should also return false
        XCTAssertFalse(TerminalBridge.titleLooksRemote("\(localUser)@\(hn): ~/dir"))

        // extractProcessName should return empty (local prompt, not a process)
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "\(localUser)@\(hn): ~/dir"), "")
    }

    func testProcessInfoHostnameNotDetectedAsRemote() {
        // ProcessInfo.hostName short form
        let piHost =
            ProcessInfo.processInfo.hostName
            .split(separator: ".").first.map(String.init) ?? ""
        guard !piHost.isEmpty else { return }

        let result = TerminalBridge.detectRemoteFromHeuristics(
            title: "user@\(piHost): ~/work",
            cwd: "/tmp"
        )
        XCTAssertNil(result, "user@\(piHost) should be local")
    }

    func testTitleLooksRemoteWithActualLocalHostname() {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0,
            let hn = String(validating: buf, as: UTF8.self), !hn.isEmpty
        else { return }
        XCTAssertFalse(TerminalBridge.titleLooksRemote("user@\(hn): ~/dir"))
        XCTAssertTrue(TerminalBridge.titleLooksRemote("user@definitely-remote-box: ~/dir"))
    }

    func testLocalHostnamesContainsExpectedEntries() {
        let names = TerminalBridge.localHostnames
        // Must always have these
        XCTAssertTrue(names.contains("localhost"))
        XCTAssertTrue(names.contains("127.0.0.1"))
        // Must have at least one real hostname beyond aliases
        let realNames = names.subtracting(["localhost", "127.0.0.1"])
        XCTAssertFalse(realNames.isEmpty, "Should have at least one real hostname, got only aliases")
    }

    // MARK: - remoteCwd in BridgeState

    func testRemoteCwdExtractedFromTitleChange() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        bridge.handleTitleChange(title: "user@remote-host:~/projects", paneID: paneID)

        XCTAssertNotNil(bridge.state.remoteSession)
        XCTAssertEqual(bridge.state.remoteCwd, "/home/user/projects")
    }

    func testSessionSwitchResetsRemoteCwd() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        bridge.handleTitleChange(title: "user@host1:~/dir", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteCwd, "/home/user/dir")

        // Switch to a different host
        bridge.handleTitleChange(title: "user@host2:~/other", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteCwd, "/home/user/other")
        if case .ssh(let host, _) = bridge.state.remoteSession {
            XCTAssertTrue(host.contains("host2"))
        } else {
            XCTFail("Expected SSH session for host2")
        }
    }

    func testProcessExitClearsRemoteCwd() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        bridge.handleTitleChange(title: "user@remote-host:~/dir", paneID: paneID)
        XCTAssertNotNil(bridge.state.remoteCwd)

        bridge.handleProcessExit(paneID: paneID)
        XCTAssertNil(bridge.state.remoteCwd)
    }

    func testSwitchContextClearsRemoteCwd() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        bridge.handleTitleChange(title: "user@remote-host:~/dir", paneID: paneID)
        XCTAssertNotNil(bridge.state.remoteCwd)

        bridge.switchContext(paneID: UUID(), workspaceID: UUID(), workingDirectory: "/home")
        XCTAssertNil(bridge.state.remoteCwd)
    }

    func testSSHHostSwitchDetectsNewSession() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")

        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.handleTitleChange(title: "ssh user@host1", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "user@host1"))

        bridge.handleTitleChange(title: "ssh user@host2", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "user@host2"))

        let sessionEvents = events.filter {
            if case .remoteSessionChanged = $0 { return true }
            return false
        }
        XCTAssertEqual(sessionEvents.count, 2, "Should emit two session change events for host switch")
    }

    // MARK: - SSH exit → new SSH regression

    /// Simulates: ssh devbox → connected → exit → ssh fileserv.
    /// The session must switch from devbox to fileserv; it must NOT stick on devbox.
    func testSSHExitThenNewSSHClearsOldSession() {
        // Use the real local hostname so the detection recognizes it as local
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0,
            let localHost = String(validating: buf, as: UTF8.self), !localHost.isEmpty
        else {
            return  // Can't test without a hostname
        }
        let localUser = NSUserName()

        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/Users/\(localUser)")

        // 1. User types "ssh devbox"
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))

        // 2. SSH connects, remote shell sets title to "user@devbox:~"
        //    Session preserves the config alias "devbox" instead of switching to "user@devbox"
        bridge.handleTitleChange(title: "\(localUser)@devbox:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))

        // 3. User types "exit" — local shell resumes
        //    OSC 7 fires with local CWD BEFORE title updates
        bridge.handleDirectoryChange(path: "/Users/\(localUser)", paneID: paneID)

        // 4. Title changes to local prompt (using real hostname)
        bridge.handleTitleChange(title: "\(localUser)@\(localHost):~/", paneID: paneID)

        // At this point the remote session MUST be cleared
        XCTAssertNil(
            bridge.state.remoteSession,
            "Session must be nil after exiting SSH (local prompt title with \(localHost))")

        // 5. User types "ssh fileserv"
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "fileserv"),
            "Session must be fileserv, not devbox")
    }

    /// Same scenario but the CWD change arrives while the remote title is still showing.
    /// This is the critical race: OSC 7 arrives before the title updates to local.
    func testSSHExitWithStaleTitleThenNewSSH() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // 1. SSH to devbox, connected — alias preserved
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "user@devbox:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))

        // 2. User exits SSH. OSC 7 CWD arrives while title still shows remote prompt.
        bridge.handleDirectoryChange(path: localHome, paneID: paneID)

        // The session may still be retained here due to preferPreviousForCwdEvent — that's OK
        // as long as it clears on the next title change.

        // 3. Title updates to local prompt (the exit command or shell name)
        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertNil(
            bridge.state.remoteSession,
            "Session must be nil after title shows local shell")

        // 4. User types "ssh fileserv"
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "fileserv"),
            "Session must be fileserv after new SSH command")
    }

    /// The critical race: exit SSH, and the user types "ssh fileserv" so fast that the
    /// title goes from "user@devbox:~" directly to "ssh fileserv" without an intermediate
    /// local title. The CWD change (OSC 7) arrives between these.
    func testSSHExitFastRetypeWithCwdRace() {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0,
            let localHost = String(validating: buf, as: UTF8.self), !localHost.isEmpty
        else { return }
        let localUser = NSUserName()

        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/Users/\(localUser)")

        // 1. SSH to devbox, connected — alias preserved
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "\(localUser)@devbox:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))

        // 2. User types exit. CWD change arrives (local path).
        //    Title still shows remote prompt due to timing.
        bridge.handleDirectoryChange(path: "/Users/\(localUser)", paneID: paneID)

        // CWD changed to a LOCAL path while supposedly remote — session should be cleared.
        // This is the key fix: a local CWD proves we're back on the local shell.
        XCTAssertNil(
            bridge.state.remoteSession,
            "CWD change to local path must clear remote session even with stale title")

        // 3. User immediately types "ssh fileserv" — title changes directly
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)

        // The session MUST be fileserv, not devbox
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "fileserv"),
            "Fast retype: session must be fileserv, not stuck on devbox")
    }

    /// Verify that when SSH config aliases are used (short hostnames like "devbox", "fileserv"),
    /// switching between them produces distinct sessions with correct host values.
    func testSSHConfigAliasSessionSwitch() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        // SSH to first host
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))

        // Exit: title goes to local shell
        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertNil(bridge.state.remoteSession)

        // SSH to second host
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "fileserv"))

        // Verify all three session change events fired
        let sessionEvents = events.compactMap { event -> TerminalEvent? in
            if case .remoteSessionChanged = event { return event }
            return nil
        }
        // Expected: .ssh("devbox"), nil, .ssh("fileserv")
        XCTAssertEqual(sessionEvents.count, 3, "Should have 3 session changes: devbox → nil → fileserv")
        XCTAssertEqual(sessionEvents[0], .remoteSessionChanged(session: .ssh(host: "devbox")))
        XCTAssertEqual(sessionEvents[1], .remoteSessionChanged(session: nil))
        XCTAssertEqual(sessionEvents[2], .remoteSessionChanged(session: .ssh(host: "fileserv")))
    }

    // MARK: - Directory Listing (OSC 2 EXTERM_LS protocol)

    func testParseLsOutputBasic() {
        let output = "dir1/\nfile.txt\nlink@\nexec*\n"
        let entries = TerminalBridge.parseLsOutput(output)
        XCTAssertEqual(entries.count, 4)
        // Directories sort first
        XCTAssertEqual(entries[0].name, "dir1")
        XCTAssertTrue(entries[0].isDirectory)
        // Then files sorted alphabetically
        XCTAssertEqual(entries[1].name, "exec")
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[2].name, "file.txt")
        XCTAssertFalse(entries[2].isDirectory)
        XCTAssertEqual(entries[3].name, "link")
        XCTAssertFalse(entries[3].isDirectory)
    }

    func testParseLsOutputEmpty() {
        XCTAssertEqual(TerminalBridge.parseLsOutput("").count, 0)
    }

    func testHandleDirectoryListingCachesAndEmitsEvent() {
        var events: [TerminalEvent] = []
        bridge.events
            .sink { events.append($0) }
            .store(in: &cancellables)

        bridge.handleDirectoryListing(path: "/home/user", output: "docs/\nreadme.md\n", paneID: paneID)

        XCTAssertNotNil(bridge.cachedRemoteListing)
        XCTAssertEqual(bridge.cachedRemoteListing?.path, "/home/user")
        XCTAssertEqual(bridge.cachedRemoteListing?.entries.count, 2)

        let listingEvents = events.filter {
            if case .remoteDirectoryListed = $0 { return true }
            return false
        }
        XCTAssertEqual(listingEvents.count, 1)
    }

    func testHandleDirectoryListingIgnoresWrongPane() {
        bridge.handleDirectoryListing(path: "/home/user", output: "file\n", paneID: UUID())
        XCTAssertNil(bridge.cachedRemoteListing)
    }

    // MARK: - SSH Alias Stability (no false session transitions on cd)

    /// Core bug: "ssh devbox" connects, initial tree loads, then on cd the title changes
    /// from "root@devbox:~" to "root@devbox:/tmp". Each title change must NOT cause a session
    /// change event — the session host must stay stable as "devbox".
    func testSSHAliasStableAcrossMultipleCdChanges() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        var sessionEvents: [TerminalEvent] = []
        bridge.events
            .sink { if case .remoteSessionChanged = $0 { sessionEvents.append($0) } }
            .store(in: &cancellables)

        // 1. User types "ssh devbox"
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))
        XCTAssertEqual(sessionEvents.count, 1, "Initial SSH detection should fire one event")

        // 2. Remote shell prompt appears
        bridge.handleTitleChange(title: "root@devbox:~", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "devbox"),
            "Session host must stay 'devbox' — not flip to 'root@devbox'")
        XCTAssertEqual(sessionEvents.count, 1, "No new session event — host unchanged")

        // 3. User does cd /tmp
        bridge.handleTitleChange(title: "root@devbox:/tmp", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "devbox"),
            "cd must not cause session change")
        XCTAssertEqual(sessionEvents.count, 1, "Still only 1 session event total")

        // 4. User does cd /var/log
        bridge.handleTitleChange(title: "root@devbox:/var/log", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))
        XCTAssertEqual(sessionEvents.count, 1, "Multiple cd's must not cause session churn")
    }

    /// When the SSH config alias resolves to a different hostname (e.g., "devbox" → "ubuntu-server"),
    /// the title shows "root@ubuntu-server:~" but the session must stay stable with the alias.
    func testSSHAliasStableWhenHostnameDiffersFromAlias() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        var sessionEvents: [TerminalEvent] = []
        bridge.events
            .sink { if case .remoteSessionChanged = $0 { sessionEvents.append($0) } }
            .store(in: &cancellables)

        // 1. User types "ssh devbox"
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))

        // 2. Title shows different hostname — alias must survive
        bridge.handleTitleChange(title: "root@ubuntu-server:~", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "devbox"),
            "Session must stay 'devbox' even when remote hostname differs")
        XCTAssertEqual(sessionEvents.count, 1, "No false session transition")

        // 3. cd on the remote — still stable
        bridge.handleTitleChange(title: "root@ubuntu-server:/opt", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))
        XCTAssertEqual(sessionEvents.count, 1)
    }

    /// Verify sshConnectionTarget returns the alias for command execution.
    func testSSHConnectionTargetReturnsAlias() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // Establish session with alias via process tree reconciliation
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        // Simulate process tree detecting the same alias
        bridge.handleProcessTreeDetection(session: .ssh(host: "devbox"), paneID: paneID)

        guard let session = bridge.state.remoteSession else {
            XCTFail("Expected remote session")
            return
        }
        XCTAssertEqual(
            session.sshConnectionTarget, "devbox",
            "sshConnectionTarget must return alias for SSH command execution")
    }

    /// After alias is set via process tree, subsequent title changes must preserve it.
    func testProcessTreeAliasPreservedAcrossTitleChanges() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // 1. ssh devbox detected by title
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)

        // 2. Process tree confirms with alias
        bridge.handleProcessTreeDetection(session: .ssh(host: "devbox"), paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "devbox")

        // 3. Title changes to remote prompt
        bridge.handleTitleChange(title: "root@ubuntu-server:~", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession?.sshConnectionTarget, "devbox",
            "Alias must survive title changes")

        // 4. Multiple cd's
        bridge.handleTitleChange(title: "root@ubuntu-server:/tmp", paneID: paneID)
        bridge.handleTitleChange(title: "root@ubuntu-server:/var", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "devbox")
    }

    // MARK: - Docker Session Stability

    /// Docker container prompts show "root@abc123def456:~" which looks like SSH to the
    /// title heuristic. The Docker session must not flip to SSH.
    func testDockerSessionNotFlippedToSSHByContainerPrompt() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        var sessionEvents: [TerminalEvent] = []
        bridge.events
            .sink { if case .remoteSessionChanged = $0 { sessionEvents.append($0) } }
            .store(in: &cancellables)

        // 1. Docker exec detected
        bridge.handleTitleChange(title: "docker exec -it mycontainer bash", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .container(target: "mycontainer", tool: .docker))
        XCTAssertEqual(sessionEvents.count, 1)

        // 2. Container shell prompt looks like SSH (user@containerID:path)
        bridge.handleTitleChange(title: "root@abc123def456:/app", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .container(target: "mycontainer", tool: .docker),
            "Docker session must not flip to SSH from container prompt")
        XCTAssertEqual(sessionEvents.count, 1, "No false session transition")

        // 3. cd inside container
        bridge.handleTitleChange(title: "root@abc123def456:/tmp", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .container(target: "mycontainer", tool: .docker))
        XCTAssertEqual(sessionEvents.count, 1, "Docker session stays stable across cd")
    }

    /// Docker session ends when process tree says no remote child.
    func testDockerSessionClearedByProcessTree() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // Start Docker session
        bridge.handleTitleChange(title: "docker exec -it web bash", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .container(target: "web", tool: .docker))

        // Container prompt
        bridge.handleTitleChange(title: "root@abc123:/app", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .container(target: "web", tool: .docker))

        // Process tree says no remote child (user exited container)
        bridge.handleProcessTreeDetection(session: nil, paneID: paneID)
        XCTAssertNil(
            bridge.state.remoteSession,
            "Docker session must be cleared when process tree says no remote child")
    }

    // MARK: - RemoteSessionType Equatable and sshConnectionTarget

    func testSSHEqualityIgnoresAlias() {
        let a = RemoteSessionType.ssh(host: "devbox", alias: "devbox")
        let b = RemoteSessionType.ssh(host: "devbox", alias: nil)
        let c = RemoteSessionType.ssh(host: "devbox", alias: "other")
        XCTAssertEqual(a, b, "Alias should be ignored for equality")
        XCTAssertEqual(a, c, "Different aliases with same host should be equal")
    }

    func testSSHConnectionTargetPrefersAlias() {
        let withAlias = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "devbox")
        XCTAssertEqual(withAlias.sshConnectionTarget, "devbox")

        let noAlias = RemoteSessionType.ssh(host: "root@ubuntu-server")
        XCTAssertEqual(noAlias.sshConnectionTarget, "root@ubuntu-server")

        let shortHost = RemoteSessionType.ssh(host: "devbox")
        XCTAssertEqual(shortHost.sshConnectionTarget, "devbox")
    }

    func testDockerConnectionTarget() {
        let docker = RemoteSessionType.container(target: "web-app", tool: .docker)
        XCTAssertEqual(docker.sshConnectionTarget, "web-app")
    }

    // MARK: - Transient command titles must not clear session

    /// When the user types "cd /tmp" in a remote SSH session, the terminal title
    /// briefly shows "cd /tmp" before updating to the new prompt. This transient
    /// title must NOT clear the remote session.
    func testTransientCommandTitleDoesNotClearSSHSession() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        var sessionEvents: [TerminalEvent] = []
        bridge.events
            .sink { if case .remoteSessionChanged = $0 { sessionEvents.append($0) } }
            .store(in: &cancellables)

        // 1. SSH connected
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "root@ubuntu-server:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))
        let eventsAfterConnect = sessionEvents.count

        // 2. User types "cd /tmp" — title briefly shows the command
        bridge.handleTitleChange(title: "cd /tmp", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "devbox"),
            "Transient 'cd /tmp' title must not clear SSH session")
        XCTAssertEqual(
            sessionEvents.count, eventsAfterConnect,
            "No session change event for transient command title")

        // 3. Title updates to new prompt
        bridge.handleTitleChange(title: "root@ubuntu-server:/tmp", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "devbox"))
        XCTAssertEqual(bridge.state.remoteCwd, "/tmp")
    }

    /// Various command titles that should not clear a remote session.
    func testVariousTransientTitlesPreserveSession() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "root@server:~", paneID: paneID)
        XCTAssertNotNil(bridge.state.remoteSession)

        // All of these are commands typed during the SSH session
        for cmd in [
            "cd /tmp", "vim file.txt", "ls -la", "cat /etc/hosts",
            "make build", "git status", "top", "htop"
        ] {
            bridge.handleTitleChange(title: cmd, paneID: paneID)
            XCTAssertNotNil(
                bridge.state.remoteSession,
                "Title '\(cmd)' must not clear remote session")
        }
    }

    /// A local shell prompt ("zsh", "bash") SHOULD clear the session — it means
    /// the user has exited the remote shell.
    func testLocalShellTitleClearsSession() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        XCTAssertNotNil(bridge.state.remoteSession)

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertNil(
            bridge.state.remoteSession,
            "Local shell name 'zsh' must clear remote session")
    }

    // MARK: - SSH session switch (connect to server B while on server A)

    /// User is connected to server A, exits, and connects to server B.
    /// The session must switch to B, not stay on A.
    func testSSHSwitchServersViaExit() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // Connect to server A
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "root@ubuntu-server:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "devbox")

        // Exit server A — title shows "exit" command, then OSC 7 with local CWD
        bridge.handleTitleChange(title: "exit", paneID: paneID)
        bridge.handleDirectoryChange(path: localHome, paneID: paneID)
        XCTAssertNil(bridge.state.remoteSession, "Session A must be cleared after exit + local CWD")

        // Connect to server B
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "fileserv"),
            "Session must be fileserv, not devbox")
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "fileserv")
    }

    /// Realistic sequence: user types "exit", title shows "exit", then "logout",
    /// then local prompt, then "ssh newserver". Session must not stick on old server.
    func testSSHExitSequenceFullRealistic() {
        let localUser = NSUserName()
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0,
            let localHost = String(validating: buf, as: UTF8.self), !localHost.isEmpty
        else { return }

        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/Users/\(localUser)")

        // Connect to server A
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "root@ubuntu-server:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "devbox")

        // User types "exit" — this is the title the terminal shows
        bridge.handleTitleChange(title: "exit", paneID: paneID)
        // Session may or may not be cleared here — "exit" is ambiguous

        // But then the local prompt MUST clear it
        bridge.handleDirectoryChange(path: "/Users/\(localUser)", paneID: paneID)
        XCTAssertNil(
            bridge.state.remoteSession,
            "Session must be cleared when local CWD is reported after exit")

        // Connect to server B
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .ssh(host: "fileserv"))

        // Server B prompt
        bridge.handleTitleChange(title: "user@fileserv-host:~", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession?.sshConnectionTarget, "fileserv",
            "Connection target must be fileserv, not devbox")
    }

    /// User connects to server A, then directly types "ssh serverB" (nested or quick switch).
    /// The title goes: "ssh serverA" → "root@serverA:~" → "ssh serverB".
    func testSSHSwitchServersDirectly() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // Connect to server A
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        bridge.handleTitleChange(title: "root@ubuntu-server:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "devbox")

        // User types "ssh fileserv" (either nested SSH or after quick exit)
        bridge.handleTitleChange(title: "ssh fileserv", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "fileserv"),
            "Session must switch to fileserv when user types ssh fileserv")
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "fileserv")
    }

    /// User connects to "ssh -i key root@1.2.3.4", prompt shows "root@hostname:~",
    /// then exits and connects to "ssh devbox". Must switch to devbox.
    func testSSHSwitchFromIPToAlias() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        // Connect via IP
        bridge.handleTitleChange(title: "ssh -i ~/.ssh/key root@1.2.3.4", paneID: paneID)
        bridge.handleTitleChange(title: "root@hostname:~", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "root@1.2.3.4")

        // Exit
        bridge.handleDirectoryChange(path: localHome, paneID: paneID)
        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertNil(bridge.state.remoteSession)

        // Connect to different server
        bridge.handleTitleChange(title: "ssh devbox", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .ssh(host: "devbox"),
            "Session must be devbox after switching from IP-based session")
        XCTAssertEqual(bridge.state.remoteSession?.sshConnectionTarget, "devbox")
    }

    // MARK: - Docker shell-quoted container names

    /// Docker commands in the terminal title may have shell-quoted container names
    /// (e.g., docker exec -it 'my-container' sh). The quotes must be stripped.
    func testDockerQuotedContainerNameStripped() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "docker exec -it 'fancy-calendar-db' sh")
        XCTAssertEqual(
            result, .container(target: "fancy-calendar-db", tool: .docker),
            "Single quotes must be stripped from container name")
    }

    func testDockerDoubleQuotedContainerNameStripped() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "docker exec -it \"web-app\" bash")
        XCTAssertEqual(
            result, .container(target: "web-app", tool: .docker),
            "Double quotes must be stripped from container name")
    }

    func testDockerUnquotedContainerNameUnchanged() {
        let result = TerminalBridge.detectRemoteFromProcessName(title: "docker exec -it web-app bash")
        XCTAssertEqual(result, .container(target: "web-app", tool: .docker))
    }

    func testDockerHeuristicQuotedContainerName() {
        let result = TerminalBridge.detectRemoteFromHeuristics(title: "docker exec -it 'my-db' sh", cwd: "/tmp")
        XCTAssertEqual(
            result, .container(target: "my-db", tool: .docker),
            "Heuristic detection must strip quotes from container name")
    }

    // MARK: - Docker CWD Extraction

    func testExtractRemoteCwdFromDockerContainerPrompt() {
        // Docker container prompt: "abc123def456:/path#"
        let result = TerminalBridge.extractRemoteCwd(from: "abc123def456:/tmp")
        XCTAssertEqual(
            result, "/tmp",
            "Docker container prompt should extract /tmp as CWD")
    }

    func testExtractRemoteCwdFromDockerContainerPromptWithHash() {
        let result = TerminalBridge.extractRemoteCwd(from: "abc123def456:/app#")
        XCTAssertEqual(
            result, "/app",
            "Docker container prompt with trailing # should extract /app")
    }

    func testExtractRemoteCwdFromDockerContainerPromptWithDollar() {
        let result = TerminalBridge.extractRemoteCwd(from: "abc123def456:/home/user$ ")
        XCTAssertEqual(
            result, "/home/user",
            "Docker container prompt with trailing $ should extract /home/user")
    }

    func testExtractRemoteCwdDoesNotMatchShortNonHexStrings() {
        // "foo:/bar" should not match — "foo" is not a hex container ID
        let result = TerminalBridge.extractRemoteCwd(from: "foo:/bar")
        XCTAssertNil(result, "Non-hex, short prefix should not match Docker pattern")
    }

    func testExtractRemoteCwdStillMatchesUserAtHost() {
        // Traditional user@host:path should still work
        let result = TerminalBridge.extractRemoteCwd(from: "root@server:~/projects")
        XCTAssertEqual(result, "/root/projects")
    }

    // MARK: - Container prompt CWD extraction

    func testExtractRemoteCwdHexContainerWithAbsolutePath() {
        let result = TerminalBridge.extractRemoteCwd(from: "195cad4b6562:/app#")
        XCTAssertEqual(result, "/app")
    }

    func testExtractRemoteCwdHexContainerWithTilde() {
        let result = TerminalBridge.extractRemoteCwd(from: "195cad4b6562:~#")
        XCTAssertEqual(result, "/root")
    }

    func testExtractRemoteCwdHexContainerWithTildeSubdir() {
        let result = TerminalBridge.extractRemoteCwd(from: "195cad4b6562:~/projects$")
        XCTAssertEqual(result, "/root/projects")
    }

    func testExtractRemoteCwdNamedContainerWithPath() {
        let result = TerminalBridge.extractRemoteCwd(from: "my-service-1:/var/log#")
        XCTAssertEqual(result, "/var/log")
    }

    func testExtractRemoteCwdNamedContainerWithTilde() {
        let result = TerminalBridge.extractRemoteCwd(from: "web-app_2:~#")
        XCTAssertEqual(result, "/root")
    }

    func testExtractRemoteCwdUserAtContainerPrompt() {
        // root@195cad4b6562:/app# — matched by the user@host:path branch
        let result = TerminalBridge.extractRemoteCwd(from: "root@195cad4b6562:/app#")
        XCTAssertEqual(result, "/app")
    }

    func testExtractRemoteCwdUserAtContainerTilde() {
        let result = TerminalBridge.extractRemoteCwd(from: "root@195cad4b6562:~#")
        XCTAssertEqual(result, "/root")
    }

    func testExtractRemoteCwdPlainWordDoesNotMatch() {
        // Short names without hyphens/digits should not match
        XCTAssertNil(TerminalBridge.extractRemoteCwd(from: "vim:/tmp"))
        XCTAssertNil(TerminalBridge.extractRemoteCwd(from: "bash:/home"))
    }

    /// Docker session stays stable when title changes to container prompt.
    func testDockerSessionStableWithQuotedName() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        bridge.handleTitleChange(title: "docker exec -it 'fancy-calendar-db' sh", paneID: paneID)
        XCTAssertEqual(bridge.state.remoteSession, .container(target: "fancy-calendar-db", tool: .docker))

        // Container prompt
        bridge.handleTitleChange(title: "root@abc123def456:/app", paneID: paneID)
        XCTAssertEqual(
            bridge.state.remoteSession, .container(target: "fancy-calendar-db", tool: .docker),
            "Docker session must not flip to SSH from container prompt")
    }

    func testDockerHexPromptCreatesContainerSessionWithoutCommandTitle() {
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: localHome)

        bridge.handleTitleChange(title: "root@195cad4b6562:/app", paneID: paneID)

        XCTAssertEqual(bridge.state.remoteSession, .container(target: "195cad4b6562", tool: .docker))
        XCTAssertEqual(bridge.state.remoteCwd, "/app")
    }
}
