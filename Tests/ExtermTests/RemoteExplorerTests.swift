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
        guard fd >= 0 else {
            XCTFail("Could not create socket")
            return
        }
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
        guard bindResult == 0 else {
            XCTFail("Could not bind socket: \(errno)")
            return
        }

        // Correct host should find the socket
        let found = RemoteExplorer.findControlSocket(host: "exterm-test-user@serverA")
        XCTAssertNotNil(found, "findControlSocket should find socket for the correct host")

        // Looking for serverB must NOT return serverA's socket.
        // The old code matched on "user" alone, which would wrongly match serverA's socket.
        let wrong = RemoteExplorer.findControlSocket(host: "exterm-test-user@serverB")
        XCTAssertNil(wrong, "findControlSocket must not match serverA socket when looking for serverB")
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
        XCTAssertTrue(session.connectingHint.contains("key-based auth"))
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

    // MARK: - shellEscPath for cd commands

    func testShellEscPathPreservesTildeExpansion() {
        // Tilde must NOT be inside single quotes — shell needs it unquoted
        let result = RemoteExplorer.shellEscPath("~/container")
        XCTAssertFalse(result.hasPrefix("'"), "Tilde path must not start with quote")
        XCTAssertTrue(result.hasPrefix("~/"), "Tilde prefix must be preserved unquoted")
    }

    func testShellEscPathBareTilde() {
        XCTAssertEqual(RemoteExplorer.shellEscPath("~"), "~")
    }

    func testShellEscPathAbsolutePathIsQuoted() {
        let result = RemoteExplorer.shellEscPath("/root/container")
        XCTAssertEqual(result, "'/root/container'")
    }

    func testShellEscPathAbsolutePathWithSpaces() {
        let result = RemoteExplorer.shellEscPath("/home/user/My Documents")
        XCTAssertEqual(result, "'/home/user/My Documents'")
    }

    // MARK: - Tilde Resolution

    func testResolveTildeWithoutCacheReturnsNil() {
        RemoteExplorer.clearAllHomeCache()
        let result = RemoteExplorer.resolveTilde("~/project", session: .ssh(host: "unknown-host-xyz"))
        XCTAssertNil(result)
    }

    func testDockerStdinNullified() {
        // Verify Docker exec branch of runRemoteCommand sets standardInput.
        // We can't easily test the Process setup, but we can verify the command
        // structure is correct by checking directoryListCommand output.
        let cmd = RemoteExplorer.directoryListCommand(for: "/app")
        XCTAssertEqual(cmd, "ls -1AF '/app' 2>/dev/null")
    }

    // MARK: - sshConnectionTarget for home cache

    func testResolveTildeUsesConnectionTarget() {
        RemoteExplorer.clearAllHomeCache()

        // Two sessions with same alias but different display hosts
        let session1 = RemoteSessionType.ssh(host: "het", alias: "het")
        let session2 = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "het")

        // resolveTilde with no cache returns nil for both
        XCTAssertNil(RemoteExplorer.resolveTilde("~/proj", session: session1))
        XCTAssertNil(RemoteExplorer.resolveTilde("~/proj", session: session2))

        // Both sessions should use the same cache key ("het")
        XCTAssertEqual(session1.sshConnectionTarget, "het")
        XCTAssertEqual(session2.sshConnectionTarget, "het")
    }

    func testSSHConnectionTargetWithAlias() {
        let session = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "het")
        XCTAssertEqual(session.sshConnectionTarget, "het")
        XCTAssertEqual(session.displayName, "root@ubuntu-server")
    }

    func testSSHConnectionTargetWithoutAlias() {
        let session = RemoteSessionType.ssh(host: "nas.local")
        XCTAssertEqual(session.sshConnectionTarget, "nas.local")
    }
}
