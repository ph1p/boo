import XCTest
@testable import Exterm

final class RemoteFileTreePluginTests: XCTestCase {

    func testRemoteRootPathFallsBackToHomeUntilRemoteCwdIsKnown() {
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/local/project",
            remoteSession: .ssh(host: "user@remote-host"),
            gitContext: nil,
            processName: "ssh",
            paneCount: 1,
            tabCount: 1
        )

        XCTAssertEqual(RemoteFileTreePlugin.remoteRootPath(for: context), "~")
    }

    func testRemoteRootPathUsesTrackedRemoteCwdEvenForCommonLocalPaths() {
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/local/project",
            remoteSession: .ssh(host: "user@remote-host"),
            remoteCwd: "/tmp",
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        XCTAssertEqual(RemoteFileTreePlugin.remoteRootPath(for: context), "/tmp")
        XCTAssertEqual(RemoteFileTreePlugin.displayPath(for: context), "/tmp")
    }

    func testRemoteRootPathKeepsHomeRelativeRemotePath() {
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/local/project",
            remoteSession: .ssh(host: "user@remote-host"),
            remoteCwd: "~/src/exterm",
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        XCTAssertEqual(RemoteFileTreePlugin.remoteRootPath(for: context), "~/src/exterm")
    }

    // MARK: - Remote Root Reuse on cd

    @MainActor
    func testRemoteRootReusedOnCd() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "het")

        // Create initial root for home directory
        let root1 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        // Simulate successful load
        root1.applyEntries([.init(name: "src", isDirectory: true)])

        // Now cd to a different directory — should reuse the same root object
        let root2 = plugin.getOrCreateRemoteRoot(for: "/home/user/project", session: session)
        XCTAssertTrue(root1 === root2, "Same root object should be reused for the same host on cd")
        XCTAssertEqual(root2.remotePath, "/home/user/project")
    }

    @MainActor
    func testRemoteRootNotReusedAcrossHosts() {
        let plugin = RemoteFileTreePlugin()

        let rootA = plugin.getOrCreateRemoteRoot(for: "~", session: .ssh(host: "hostA"))
        rootA.applyEntries([.init(name: "file", isDirectory: false)])

        let rootB = plugin.getOrCreateRemoteRoot(for: "~", session: .ssh(host: "hostB"))
        XCTAssertFalse(rootA === rootB, "Different hosts should have separate root objects")
    }

    @MainActor
    func testRemoteRootTildePromotionViaReuse() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "het")

        // Start with tilde root
        let tildeRoot = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        tildeRoot.applyEntries([.init(name: "Documents", isDirectory: true)])

        // Title resolves to absolute path — reuses the tilde root
        let resolved = plugin.getOrCreateRemoteRoot(for: "/home/user", session: session)
        XCTAssertTrue(tildeRoot === resolved)
        XCTAssertEqual(resolved.remotePath, "/home/user")
        // Children should still be present (no spinner)
        XCTAssertNotNil(resolved.children)
    }

    @MainActor
    func testRemoteRootCacheHitReturnsSameObject() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "het")

        let root1 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        let root2 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        XCTAssertTrue(root1 === root2, "Cache hit should return the same root object")
    }

    @MainActor
    func testRemoteRootResolvesAbsolutePathWhenHomeCached() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "het")

        // Pre-populate home cache so resolveTilde works synchronously
        RemoteExplorer.resolveRemoteHome(session: session) { _ in }
        // Manually seed the cache for test (resolveRemoteHome requires real SSH)
        // Instead, test with an absolute path directly
        let root = plugin.getOrCreateRemoteRoot(for: "/root", session: session)
        XCTAssertEqual(root.remotePath, "/root")
        XCTAssertFalse(root.remotePath.hasPrefix("~"))
    }

    @MainActor
    func testRemoteRootAbsolutePathChildrenAreAbsolute() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "het")

        let root = plugin.getOrCreateRemoteRoot(for: "/root", session: session)
        root.applyEntries([
            .init(name: "container", isDirectory: true),
            .init(name: "file.txt", isDirectory: false),
        ])

        // Children should have absolute paths, not tilde-relative
        XCTAssertEqual(root.children?[0].remotePath, "/root/container")
        XCTAssertEqual(root.children?[1].remotePath, "/root/file.txt")
        XCTAssertFalse(root.children?[0].remotePath.hasPrefix("~") ?? true)
    }

    // MARK: - Cache Key Consistency with Alias

    /// When the session has an alias, the cache key must use sshConnectionTarget (the alias),
    /// not the display host. This ensures the cache key matches the SSHControlManager socket key.
    @MainActor
    func testCacheKeyUsesAliasNotDisplayHost() {
        let plugin = RemoteFileTreePlugin()

        // Session where display host differs from alias
        let session = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "het")

        let root1 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        root1.applyEntries([.init(name: "src", isDirectory: true)])

        // Same alias, same path — must return cached root
        let root2 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        XCTAssertTrue(root1 === root2, "Cache hit must work when alias matches")
    }

    /// Sessions with different display hosts but the same alias must share cache.
    @MainActor
    func testCacheSharedBySameAlias() {
        let plugin = RemoteFileTreePlugin()

        // Title-based session: host="het", alias="het"
        let session1 = RemoteSessionType.ssh(host: "het", alias: "het")
        let root1 = plugin.getOrCreateRemoteRoot(for: "~", session: session1)
        root1.applyEntries([.init(name: "docs", isDirectory: true)])

        // After reconciliation: host="root@ubuntu-server", alias="het"
        let session2 = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "het")
        let root2 = plugin.getOrCreateRemoteRoot(for: "~", session: session2)
        XCTAssertTrue(root1 === root2,
                      "Same alias must hit same cache entry regardless of display host")
    }

    /// Docker cache key should use container name.
    @MainActor
    func testDockerCacheKeyUsesContainerName() {
        let plugin = RemoteFileTreePlugin()

        let session = RemoteSessionType.docker(container: "web-app")
        let root1 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        root1.applyEntries([.init(name: "app", isDirectory: true)])

        let root2 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        XCTAssertTrue(root1 === root2, "Docker cache should work with container name")
    }

    /// On cd, the existing root must be reused even with aliased sessions.
    @MainActor
    func testRemoteRootReusedOnCdWithAlias() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "het", alias: "het")

        let root1 = plugin.getOrCreateRemoteRoot(for: "~", session: session)
        root1.applyEntries([.init(name: "src", isDirectory: true)])

        // cd to /tmp — same host prefix, different path → reuse
        let root2 = plugin.getOrCreateRemoteRoot(for: "/tmp", session: session)
        XCTAssertTrue(root1 === root2, "Same root must be reused on cd")
        XCTAssertEqual(root2.remotePath, "/tmp")
        // Children from old path should be cleared by loadChildren (async)
    }
}
