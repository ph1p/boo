import XCTest

@testable import Boo

final class LoginShellEnvironmentTests: XCTestCase {
    func testParseSkipsRcOutputAndKeepsImportedKeys() {
        let output =
            "Welcome to zsh\n\u{1E}BOO_LOGIN_ENV\u{1E}"
            + "HOME=/Users/me\0SSH_AUTH_SOCK=/tmp/agent.sock\0PATH=/opt/homebrew/bin:/usr/bin\0"
            + "KUBECONFIG=/a:/b\0"
        XCTAssertEqual(
            LoginShellEnvironment.parse(output),
            ["SSH_AUTH_SOCK": "/tmp/agent.sock", "PATH": "/opt/homebrew/bin:/usr/bin", "KUBECONFIG": "/a:/b"])
        XCTAssertEqual(LoginShellEnvironment.parse("no marker\0PATH=/x"), [:])
    }

    func testMergePathDedupesAndKeepsShellOrderFirst() {
        XCTAssertEqual(
            LoginShellEnvironment.mergePath("/opt/homebrew/bin:/usr/bin", "/usr/bin:/bin"),
            "/opt/homebrew/bin:/usr/bin:/bin")
    }

    func testMergeFallsBackWhenShellAgentSocketIsMissing() {
        let base = ["SSH_AUTH_SOCK": "/launchd/agent", "PATH": "/usr/bin"]
        let merged = LoginShellEnvironment.merge(
            base: base, shell: ["SSH_AUTH_SOCK": "/nonexistent/agent.sock", "KUBECONFIG": "/k"])
        XCTAssertEqual(merged["SSH_AUTH_SOCK"], "/launchd/agent", "a stale export must not replace launchd's agent")
        XCTAssertEqual(merged["KUBECONFIG"], "/k")
        XCTAssertEqual(merged["PATH"], "/usr/bin")
    }

    func testFailedCaptureIsRetriedInsteadOfCached() {
        let calls = Counter()
        let env = LoginShellEnvironment(disabled: false, retryDelay: 0) { _ in
            calls.increment() == 1 ? nil : ["PATH": "/shell/bin"]
        }
        XCTAssertEqual(env.values(timeout: 2), [:], "first capture fails")
        XCTAssertNil(env.snapshot, "a failure must not be cached as resolved")
        XCTAssertEqual(env.values(timeout: 2), ["PATH": "/shell/bin"], "the next call retries")
        XCTAssertEqual(calls.value, 2)
    }

    func testGivesUpAfterMaxAttempts() {
        let calls = Counter()
        let env = LoginShellEnvironment(disabled: false, retryDelay: 0) { _ in
            _ = calls.increment()
            return nil
        }
        for _ in 0..<5 { _ = env.values(timeout: 2) }
        XCTAssertEqual(calls.value, LoginShellEnvironment.maxAttempts)
        XCTAssertEqual(env.snapshot, [:], "settles on empty once attempts run out")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
