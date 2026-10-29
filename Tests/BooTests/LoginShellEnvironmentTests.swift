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
}
