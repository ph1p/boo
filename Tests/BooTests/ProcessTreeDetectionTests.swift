import Darwin
import XCTest

@testable import Boo

/// Tests for process-tree detection and process name resolution.
///
/// NOTE: `proc_name()` requires `com.apple.security.get-task-allow` (present in the Boo
/// app bundle) but NOT in the test runner. Tests that would call proc_name on a child
/// process therefore skip or test the fallback path instead.
final class ProcessTreeDetectionTests: XCTestCase {

    // MARK: - childPIDs

    func testChildPIDsEmptyForNonexistentPID() {
        XCTAssertEqual(ProcessTree.childPIDs(of: 999_999_999), [])
    }

    func testChildPIDsReturnsAllDirectChildren() {
        // Spawn two children and verify both appear.
        let p1 = makeProcess("/bin/sleep", args: ["60"])
        let p2 = makeProcess("/bin/sleep", args: ["60"])
        defer {
            p1.terminate()
            p1.waitUntilExit()
            p2.terminate()
            p2.waitUntilExit()
        }

        var children: [pid_t] = []
        for _ in 0..<20 {
            children = ProcessTree.childPIDs(of: getpid())
            if children.contains(p1.processIdentifier) && children.contains(p2.processIdentifier) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(children.contains(p1.processIdentifier), "childPIDs must contain first child")
        XCTAssertTrue(children.contains(p2.processIdentifier), "childPIDs must contain second child")
    }

    // MARK: - processName (proc_name wrapper)
    //
    // proc_name requires get-task-allow entitlement (present in the Boo app bundle but
    // NOT in the Swift test runner). We can only test the strip-dash logic indirectly.

    // MARK: - argv0 extraction via KERN_PROCARGS2
    //
    // KERN_PROCARGS2 works for processes we own regardless of get-task-allow.

    // MARK: - Agent descendant walk

    /// The bug this whole path exists for: agents fork helper shells, so a depth-1 scan of the
    /// shell's children sees only a shell and reports "no foreground process". The walk must
    /// find the agent *through* that intermediate shell.
    ///
    /// The fake agent is a real `python3` with "codex" in its argv — the one way to manufacture an
    /// "ai"-category name here. Renaming a binary doesn't work: name resolution reads `proc_name`
    /// (needs get-task-allow, absent in the runner) or the KERN_PROCARGS2 *exec path*, so `exec -a`
    /// is invisible and a copied binary loses its signature and is SIGKILLed. A script-runtime
    /// process resolves through `agentFromArgs` instead, which is exactly the shim path real
    /// agents take (`npx codex`, `uv run aider`).
    func testAgentIsFoundBeneathAnIntermediateShell() throws {
        // bash (the tracked shell) -> sh (the intermediate helper shell) -> python3 (the agent).
        // The trailing `:` matters: with a single simple command `sh -c` execs into it and
        // collapses the middle level, which would let the single-child fast path answer and
        // exercise no walk at all.
        let script = """
            #!/bin/bash
            /bin/sh -c '/usr/bin/python3 -c "import time; time.sleep(60)  # codex"; :'
            """
        let scriptPath = NSTemporaryDirectory() + "boo_agent_walk_\(UUID().uuidString).sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("no /usr/bin/python3 to stand in for a script-shim agent")
        }

        let shell = makeProcess(scriptPath, args: [])
        defer {
            // terminate() only signals the outer bash; kill the descendants too or the
            // 60s python3 outlives the test run.
            killTree(shell.processIdentifier)
            shell.terminate()
            shell.waitUntilExit()
        }

        var resolved: String?
        for _ in 0..<60 {
            // maxAge: 0 defeats the cache — otherwise the first (pre-spawn) nil would be
            // served back for the rest of the poll.
            resolved = ProcessTree.foregroundProcess(shellPID: shell.processIdentifier, maxAge: 0)
            if resolved == "codex" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertEqual(
            resolved, "codex",
            "the agent must be found through the intermediate shell, not reported as idle")
    }

    // MARK: - suppressAIAgents

    func testSuppressAIAgentsBlocksAIKeywordsFromTitle() {
        let aiTitles = [
            "claude", "✳ Claude Code", "⠂ Thinking deeply",
            "opencode", "⠂ opencode task", "codex", "codex: doing something"
        ]
        for title in aiTitles {
            XCTAssertEqual(
                TerminalBridge.extractProcessName(from: title, suppressAIAgents: true), "",
                "AI title '\(title)' must be suppressed"
            )
        }
    }

    func testSuppressAIAgentsAllowsNonAIProcesses() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "vim file.txt", suppressAIAgents: true), "vim")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "git status", suppressAIAgents: true), "git")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "cargo build", suppressAIAgents: true), "cargo")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "node server.js", suppressAIAgents: true), "node")
    }

    func testNoSuppressDetectsAIFromTitle() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "✳ Claude Code"), "claude")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "opencode"), "opencode")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "codex"), "codex")
    }

    // MARK: - resolveProcess integration (via TerminalBridge)

    func testResolveProcessFallsBackToTitleWhenShellPIDUnknown() {
        let bridge = TerminalBridge(paneID: UUID(), workspaceID: UUID(), workingDirectory: "/tmp")
        let pane = bridge.state.paneID

        bridge.handleTitleChange(title: "✳ Claude Code", paneID: pane)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "vim file.txt", paneID: pane)
        XCTAssertEqual(bridge.state.foregroundProcess, "vim")

        bridge.handleTitleChange(title: "~/dev/opencode-stuff", paneID: pane)
        XCTAssertEqual(bridge.state.foregroundProcess, "")
    }

    @MainActor
    func testResolveProcessSuppressesAITitleWhenShellKnownAndIdle() {
        // When we know the shell PID and it has no AI child, title-based AI matching is suppressed.
        let paneID = UUID()
        let bridge = TerminalBridge(paneID: paneID, workspaceID: UUID(), workingDirectory: "/tmp")
        bridge.monitor.track(paneID: paneID, shellPID: getpid())
        Thread.sleep(forTimeInterval: 0.05)

        bridge.handleTitleChange(title: "✳ Claude Code", paneID: paneID)
        // Shell is idle (no claude child) — AI title must be suppressed.
        XCTAssertEqual(
            bridge.state.foregroundProcess, "",
            "AI title must be suppressed when shell PID is known and shell has no AI child"
        )
        bridge.monitor.untrack(paneID: paneID)
    }

    // MARK: - Helpers

    /// SIGKILL a pid and everything beneath it, deepest first.
    private func killTree(_ pid: pid_t) {
        for child in ProcessTree.childPIDs(of: pid) { killTree(child) }
        kill(pid, SIGKILL)
    }

    private func makeProcess(_ path: String, args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return process
    }

    // MARK: - stdinIsTerminal

    private func sleeper(stdin: Any) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        p.standardInput = stdin
        try p.run()
        return p
    }

    func testStdinIsTerminalFalseForNullAndPipe() throws {
        for stdin: Any in [FileHandle.nullDevice, Pipe()] {
            let p = try sleeper(stdin: stdin)
            defer { p.terminate() }
            XCTAssertFalse(ProcessTree.stdinIsTerminal(pid: p.processIdentifier))
        }
    }

    func testStdinIsTerminalTrueForPty() throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { close(master) }
        let p = try sleeper(stdin: FileHandle(fileDescriptor: slave, closeOnDealloc: true))
        defer { p.terminate() }
        XCTAssertTrue(ProcessTree.stdinIsTerminal(pid: p.processIdentifier))
    }
}
