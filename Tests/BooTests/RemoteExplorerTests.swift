import XCTest

@testable import Boo

final class RemoteExplorerTests: XCTestCase {

    // MARK: - findControlSocket

    func testFindControlSocketDoesNotMatchWrongHost() {
        // Create a Unix domain socket in ~/.ssh named for serverA
        let sshDir = NSHomeDirectory() + "/.ssh"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true)

        let socketName = "cm-boo-test-user@serverA:22"
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
        let found = RemoteExplorer.findControlSocket(host: "boo-test-user@serverA")
        XCTAssertNotNil(found, "findControlSocket should find socket for the correct host")

        // Looking for serverB must NOT return serverA's socket.
        // The old code matched on "user" alone, which would wrongly match serverA's socket.
        let wrong = RemoteExplorer.findControlSocket(host: "boo-test-user@serverB")
        XCTAssertNil(wrong, "findControlSocket must not match serverA socket when looking for serverB")
    }

    // MARK: - ControlMaster Config

    // MARK: - Session Type Properties

    func testSSHSessionConnectingHint() {
        let session = RemoteSessionType.ssh(host: "test-host")
        XCTAssertTrue(session.connectingHint.contains("SSH"))
        XCTAssertTrue(session.connectingHint.contains("key-based auth"))
    }

    func testDockerSessionConnectingHint() {
        let session = RemoteSessionType.container(target: "my-container", tool: .docker)
        XCTAssertTrue(session.connectingHint.contains("docker"))
    }

    func testMoshSessionConnectingHint() {
        let session = RemoteSessionType.mosh(host: "test-host")
        XCTAssertTrue(session.connectingHint.contains("Mosh"))
    }

    // MARK: - Remote Session Display

    func testSSHHostWithUser() {
        let session = RemoteSessionType.ssh(host: "user@fileserv.local")
        XCTAssertEqual(session.displayName, "user@fileserv.local")
    }

    func testSSHHostWithoutUser() {
        let session = RemoteSessionType.ssh(host: "fileserv.local")
        XCTAssertEqual(session.displayName, "fileserv.local")
    }

    func testDockerContainerDisplay() {
        let session = RemoteSessionType.container(target: "web-app", tool: .docker)
        XCTAssertEqual(session.displayName, "web-app")
        XCTAssertEqual(session.icon, "shippingbox")
    }

    func testMoshDisplay() {
        let session = RemoteSessionType.mosh(host: "server.example.com")
        XCTAssertEqual(session.displayName, "server.example.com")
        XCTAssertEqual(session.icon, "globe.badge.chevron.backward")
        XCTAssertEqual(session.envType, "mosh")
    }

    func testSSHIcon() {
        let session = RemoteSessionType.ssh(host: "host")
        XCTAssertEqual(session.icon, "globe")
    }

    // MARK: - Container Tool Properties

    func testContainerToolIcons() {
        XCTAssertEqual(RemoteSessionType.container(target: "pod", tool: .kubectl).icon, "helm")
        XCTAssertEqual(RemoteSessionType.container(target: "vm", tool: .limactl).icon, "desktopcomputer")
        XCTAssertEqual(RemoteSessionType.container(target: "box", tool: .distrobox).icon, "wrench.and.screwdriver")
        XCTAssertEqual(RemoteSessionType.container(target: "dev", tool: .adb).icon, "iphone")
    }

    func testContainerToolEnvTypes() {
        XCTAssertEqual(RemoteSessionType.container(target: "c", tool: .docker).envType, "docker")
        XCTAssertEqual(RemoteSessionType.container(target: "p", tool: .podman).envType, "podman")
        XCTAssertEqual(RemoteSessionType.container(target: "k", tool: .kubectl).envType, "kubectl")
        XCTAssertEqual(RemoteSessionType.container(target: "o", tool: .oc).envType, "openshift")
    }

    func testIsSSHBased() {
        XCTAssertTrue(RemoteSessionType.ssh(host: "h").isSSHBased)
        XCTAssertTrue(RemoteSessionType.mosh(host: "h").isSSHBased)
        XCTAssertTrue(RemoteSessionType.container(target: "vm", tool: .vagrant).isSSHBased)
        XCTAssertTrue(RemoteSessionType.container(target: "vm", tool: .colima).isSSHBased)
        XCTAssertFalse(RemoteSessionType.container(target: "c", tool: .docker).isSSHBased)
        XCTAssertFalse(RemoteSessionType.container(target: "p", tool: .kubectl).isSSHBased)
    }

    func testContainerEquality() {
        let a = RemoteSessionType.container(target: "web", tool: .docker)
        let b = RemoteSessionType.container(target: "web", tool: .docker)
        let c = RemoteSessionType.container(target: "web", tool: .podman)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMoshEquality() {
        XCTAssertEqual(RemoteSessionType.mosh(host: "h"), RemoteSessionType.mosh(host: "h"))
        XCTAssertNotEqual(RemoteSessionType.mosh(host: "h"), RemoteSessionType.ssh(host: "h"))
    }

    func testContainerToolByProcessName() {
        XCTAssertEqual(ContainerTool.byProcessName["docker"], .docker)
        XCTAssertEqual(ContainerTool.byProcessName["podman"], .podman)
        XCTAssertEqual(ContainerTool.byProcessName["kubectl"], .kubectl)
        XCTAssertEqual(ContainerTool.byProcessName["oc"], .oc)
        XCTAssertEqual(ContainerTool.byProcessName["lima"], .limactl)
        XCTAssertEqual(ContainerTool.byProcessName["adb"], .adb)
    }

    func testDockerInteractiveTargetSkipsOptionValuePairs() {
        let target = ContainerTool.docker.interactiveTarget(
            from: ["docker", "exec", "--user", "root", "--workdir", "/app", "-it", "web", "bash"])
        XCTAssertEqual(target, "web")
    }

    func testDockerInteractiveTargetSkipsInlineLongOptionValues() {
        let target = ContainerTool.docker.interactiveTarget(
            from: ["docker", "exec", "--user=root", "--workdir=/app", "-it", "web", "bash"])
        XCTAssertEqual(target, "web")
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
            "ls -1AF ~/Projects/'My App' 2>/dev/null"
        )
    }

    func testDirectoryListCommandQuotesAbsolutePaths() {
        XCTAssertEqual(
            RemoteExplorer.directoryListCommand(for: "/var/log"),
            "ls -1AF /var/log 2>/dev/null"
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

    func testShellEscPathAbsolutePathIsUnquotedWhenNoSpecialChars() {
        let result = RemoteExplorer.shellEscPath("/root/container")
        XCTAssertEqual(result, "/root/container")
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

    // MARK: - sshConnectionTarget for home cache

    func testResolveTildeUsesConnectionTarget() {
        RemoteExplorer.clearAllHomeCache()

        // Two sessions with same alias but different display hosts
        let session1 = RemoteSessionType.ssh(host: "devbox", alias: "devbox")
        let session2 = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "devbox")

        // resolveTilde with no cache returns nil for both
        XCTAssertNil(RemoteExplorer.resolveTilde("~/proj", session: session1))
        XCTAssertNil(RemoteExplorer.resolveTilde("~/proj", session: session2))

        // Both sessions should use the same cache key ("devbox")
        XCTAssertEqual(session1.sshConnectionTarget, "devbox")
        XCTAssertEqual(session2.sshConnectionTarget, "devbox")
    }

    func testSSHConnectionTargetWithAlias() {
        let session = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "devbox")
        XCTAssertEqual(session.sshConnectionTarget, "devbox")
        XCTAssertEqual(session.displayName, "root@ubuntu-server")
    }

    func testSSHConnectionTargetWithoutAlias() {
        let session = RemoteSessionType.ssh(host: "fileserv.local")
        XCTAssertEqual(session.sshConnectionTarget, "fileserv.local")
    }
}
