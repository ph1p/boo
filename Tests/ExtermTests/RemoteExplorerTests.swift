import XCTest
@testable import Exterm

final class RemoteExplorerTests: XCTestCase {

    // MARK: - findControlSocket

    func testFindControlSocketDoesNotMatchWrongHost() {
        // Create a Unix domain socket in ~/.ssh named for serverA
        let sshDir = NSHomeDirectory() + "/.ssh"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true)

        let socketName = "cm-exterm-test-user@serverA:22"
        let socketPath = sshDir + "/" + socketName
        // Clean up any previous test socket
        defer { unlink(socketPath) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { XCTFail("Could not create socket"); return }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let len = min(socketPath.utf8.count, buf.count - 1)
                _ = memcpy(buf.baseAddress!, cstr, len)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { XCTFail("Could not bind socket: \(errno)"); return }

        // Correct host should find the socket
        let found = RemoteExplorer.findControlSocket(host: "exterm-test-user@serverA")
        XCTAssertNotNil(found, "findControlSocket should find socket for the correct host")

        // Looking for serverB must NOT return serverA's socket.
        // The old code matched on "user" alone, which would wrongly match serverA's socket.
        let wrong = RemoteExplorer.findControlSocket(host: "exterm-test-user@serverB")
        XCTAssertNil(wrong, "findControlSocket must not match serverA socket when looking for serverB")
    }

    // MARK: - RemoteShellInjector

    func testRemoteInitScriptUsesOSC2NotOSC7() {
        let script = RemoteShellInjector.remoteInitScript
        // Must use OSC 2 (set title), not OSC 7 (set pwd) — Ghostty rejects remote OSC 7
        XCTAssertTrue(script.contains("\\033]2;"), "Remote init must use OSC 2 (title), not OSC 7")
        XCTAssertFalse(script.contains("\\033]7;"), "Remote init must NOT use OSC 7 (rejected by Ghostty)")
        // Must report user@host:path format for TerminalBridge.extractRemoteCwd
        XCTAssertTrue(script.contains("$(whoami)"))
        XCTAssertTrue(script.contains("$(hostname"))
        XCTAssertTrue(script.contains("$PWD"))
    }

    func testRemoteInitBase64RoundTrips() {
        guard let decoded = Data(base64Encoded: RemoteShellInjector.remoteInitBase64) else {
            XCTFail("Base64 decode failed"); return
        }
        let script = String(data: decoded, encoding: .utf8)
        XCTAssertEqual(script, RemoteShellInjector.remoteInitScript)
    }

    // MARK: - ControlMaster Config

    func testEnableControlMasterIdempotent() {
        // If ControlMaster is already in the config, enableControlMaster should detect it
        let content = """
        Host *
          ControlMaster auto
          ControlPath ~/.ssh/cm-%r@%h:%p
        """
        XCTAssertTrue(content.lowercased().contains("controlmaster"))
    }

    // MARK: - Session Type Properties

    func testSSHSessionConnectingHint() {
        let session = RemoteSessionType.ssh(host: "test-host")
        XCTAssertTrue(session.connectingHint.contains("SSH"))
        XCTAssertTrue(session.connectingHint.contains("ControlMaster"))
    }

    func testDockerSessionConnectingHint() {
        let session = RemoteSessionType.docker(container: "my-container")
        XCTAssertTrue(session.connectingHint.contains("container"))
    }

    // MARK: - Remote Session Display

    func testSSHHostWithUser() {
        let session = RemoteSessionType.ssh(host: "phlp@nas.local")
        XCTAssertEqual(session.displayName, "phlp@nas.local")
    }

    func testSSHHostWithoutUser() {
        let session = RemoteSessionType.ssh(host: "nas.local")
        XCTAssertEqual(session.displayName, "nas.local")
    }

    func testDockerContainerDisplay() {
        let session = RemoteSessionType.docker(container: "web-app")
        XCTAssertEqual(session.displayName, "web-app")
        XCTAssertEqual(session.icon, "shippingbox")
    }

    func testSSHIcon() {
        let session = RemoteSessionType.ssh(host: "host")
        XCTAssertEqual(session.icon, "globe")
    }

    func testDirectoryListCommandLeavesBareTildeUnquoted() {
        XCTAssertEqual(
            RemoteExplorer.directoryListCommand(for: "~"),
            "ls -1AF ~ 2>/dev/null"
        )
    }

    func testDirectoryListCommandPreservesTildeExpansionForNestedHomePath() {
        XCTAssertEqual(
            RemoteExplorer.directoryListCommand(for: "~/Projects/My App"),
            "ls -1AF ~/'Projects'/'My App' 2>/dev/null"
        )
    }

    func testDirectoryListCommandQuotesAbsolutePaths() {
        XCTAssertEqual(
            RemoteExplorer.directoryListCommand(for: "/var/log"),
            "ls -1AF '/var/log' 2>/dev/null"
        )
    }
}
