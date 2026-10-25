import XCTest

@testable import Boo

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
            remoteCwd: "~/src/boo",
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        XCTAssertEqual(RemoteFileTreePlugin.remoteRootPath(for: context), "~/src/boo")
    }

    // MARK: - Root cache

    private func entry(_ dir: String, _ name: String, isDir: Bool = true) -> FileTreeNode.Entry {
        FileTreeNode.Entry(name: name, path: RemoteFileTreeSource.childPath(dir, name), isDir: isDir)
    }

    /// Each folder is its own root, like the local tree — a cd keeps the previous root
    /// (and its open folders) cached for the way back.
    @MainActor
    func testEachPathGetsItsOwnRoot() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "devbox")

        let (root1, created1) = plugin.getOrCreateRoot(for: "/srv/app", session: session)
        let (root2, created2) = plugin.getOrCreateRoot(for: "/srv/other", session: session)
        XCTAssertTrue(created1)
        XCTAssertTrue(created2)
        XCTAssertFalse(root1 === root2)
        XCTAssertEqual(root2.path, "/srv/other")
        XCTAssertEqual(root2.name, "other")
        XCTAssertFalse(root2.source.isLocal, "Remote roots must list through the remote source")
    }

    @MainActor
    func testRemoteRootCacheHitReturnsSameObject() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "devbox")

        let (root1, _) = plugin.getOrCreateRoot(for: "/srv", session: session)
        let (root2, created) = plugin.getOrCreateRoot(for: "/srv", session: session)
        XCTAssertTrue(root1 === root2, "Cache hit should return the same root object")
        XCTAssertFalse(created)
    }

    @MainActor
    func testRemoteRootNotSharedAcrossHosts() {
        let plugin = RemoteFileTreePlugin()
        let (rootA, _) = plugin.getOrCreateRoot(for: "/srv", session: .ssh(host: "hostA"))
        let (rootB, _) = plugin.getOrCreateRoot(for: "/srv", session: .ssh(host: "hostB"))
        XCTAssertFalse(rootA === rootB, "Different hosts should have separate root objects")
    }

    @MainActor
    func testRootAtFilesystemRootIsNamedSlash() {
        let plugin = RemoteFileTreePlugin()
        let (root, _) = plugin.getOrCreateRoot(for: "/", session: .ssh(host: "devbox"))
        XCTAssertEqual(root.name, "/")
    }

    @MainActor
    func testRemoteChildrenGetAbsolutePathsAndShareSource() {
        let plugin = RemoteFileTreePlugin()
        let (root, _) = plugin.getOrCreateRoot(for: "/root", session: .ssh(host: "devbox"))
        root.applyListing([entry("/root", "container"), entry("/root", "file.txt", isDir: false)])

        XCTAssertEqual(root.children?.map(\.path), ["/root/container", "/root/file.txt"])
        XCTAssertTrue(root.children?[0].source === root.source)
    }

    @MainActor
    func testOldestRootEvictedPastLimit() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "devbox")
        let (first, _) = plugin.getOrCreateRoot(for: "/p0", session: session)
        for i in 1...RemoteFileTreePlugin.maxCachedRoots {
            plugin.getOrCreateRoot(for: "/p\(i)", session: session)
        }
        let key0 = RemoteFileTreePlugin.cacheKey(for: "/p0", session: session)
        XCTAssertNil(plugin.cachedRoot(forKey: key0), "The least recently used root must be evicted")
        let (again, created) = plugin.getOrCreateRoot(for: "/p0", session: session)
        XCTAssertTrue(created)
        XCTAssertFalse(again === first)
    }

    // MARK: - Cache Key Consistency with Alias

    /// When the session has an alias, the cache key must use sshConnectionTarget (the alias),
    /// not the display host. This ensures the cache key matches the SSHControlManager socket key.
    @MainActor
    func testCacheSharedBySameAlias() {
        let plugin = RemoteFileTreePlugin()

        let session1 = RemoteSessionType.ssh(host: "devbox", alias: "devbox")
        let (root1, _) = plugin.getOrCreateRoot(for: "/srv", session: session1)

        let session2 = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "devbox")
        let (root2, _) = plugin.getOrCreateRoot(for: "/srv", session: session2)
        XCTAssertTrue(root1 === root2, "Same alias must hit same cache entry regardless of display host")
        XCTAssertEqual(RemoteFileTreePlugin.cacheKey(for: "/srv", session: session2), "devbox:/srv")
    }

    // MARK: - Display path

    func testDisplayPathRelativeToTerminalFolder() {
        XCTAssertEqual(RemoteFileTreePlugin.displayPath(root: "/srv/app", terminalCwd: "/srv/app", home: nil), "app")
        XCTAssertEqual(
            RemoteFileTreePlugin.displayPath(root: "/srv/app/src/lib", terminalCwd: "/srv/app", home: nil),
            "./src/lib")
    }

    func testDisplayPathAbbreviatesRemoteHome() {
        let home = "/home/u"
        XCTAssertEqual(RemoteFileTreePlugin.displayPath(root: "/home/u", terminalCwd: "/srv", home: home), "~")
        XCTAssertEqual(
            RemoteFileTreePlugin.displayPath(root: "/home/u/code", terminalCwd: "/srv", home: home), "~/code")
        XCTAssertEqual(
            RemoteFileTreePlugin.displayPath(root: "/home/user2", terminalCwd: "/srv", home: home), "/home/user2",
            "A sibling sharing the home prefix must not be abbreviated")
        XCTAssertEqual(RemoteFileTreePlugin.displayPath(root: "/etc", terminalCwd: "/srv", home: nil), "/etc")
    }

    // MARK: - Downloads

    func testUniquePathAddsCounterBeforeExtension() {
        let taken: Set<String> = ["/d/report.pdf", "/d/report 2.pdf", "/d/folder"]
        XCTAssertEqual(
            RemoteFileTreePlugin.uniquePath(in: "/d", name: "report.pdf") { taken.contains($0) }, "/d/report 3.pdf")
        XCTAssertEqual(RemoteFileTreePlugin.uniquePath(in: "/d", name: "folder") { taken.contains($0) }, "/d/folder 2")
        XCTAssertEqual(RemoteFileTreePlugin.uniquePath(in: "/d", name: "new.txt") { taken.contains($0) }, "/d/new.txt")
    }

    func testCachePathMirrorsRemotePathPerHost() {
        let path = RemoteFileTreePlugin.cachePath(for: "/etc/nginx/nginx.conf", session: .ssh(host: "user@web-1"))
        XCTAssertTrue(path.hasSuffix("Boo-remote/user_web-1/etc/nginx/nginx.conf"), path)
    }
}
