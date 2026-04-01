import XCTest

@testable import Boo

final class RemoteFileTreeNodeTests: XCTestCase {

    override func tearDown() {
        SSHControlManager.shared.clearTestState()
        super.tearDown()
    }

    // MARK: - Basic Properties

    func testInitialState() {
        let node = RemoteFileTreeNode(
            name: "project", remotePath: "~/project", isDirectory: true, session: .ssh(host: "devbox"))
        XCTAssertNil(node.children)
        XCTAssertFalse(node.isLoading)
        XCTAssertFalse(node.loadFailed)
        XCTAssertTrue(node.isDirectory)
        XCTAssertEqual(node.remotePath, "~/project")
    }

    func testUpdatePathChangesNameAndPath() {
        let node = RemoteFileTreeNode(name: "~", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))
        node.updatePath("/home/user/project")
        XCTAssertEqual(node.remotePath, "/home/user/project")
        XCTAssertEqual(node.name, "project")
    }

    func testUpdatePathRootDirectory() {
        let node = RemoteFileTreeNode(name: "~", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))
        node.updatePath("/")
        XCTAssertEqual(node.remotePath, "/")
        XCTAssertEqual(node.name, "/")
    }

    // MARK: - applyEntries

    func testApplyEntriesSetsChildren() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))
        node.isLoading = true

        let entries: [RemoteExplorer.RemoteEntry] = [
            .init(name: "Documents", isDirectory: true),
            .init(name: "README.md", isDirectory: false)
        ]
        node.applyEntries(entries)

        XCTAssertFalse(node.isLoading)
        XCTAssertFalse(node.loadFailed)
        XCTAssertEqual(node.children?.count, 2)
        XCTAssertEqual(node.children?[0].name, "Documents")
        XCTAssertTrue(node.children?[0].isDirectory ?? false)
        XCTAssertEqual(node.children?[1].name, "README.md")
        XCTAssertFalse(node.children?[1].isDirectory ?? true)
    }

    func testApplyEntriesPreservesExistingMatchingNodes() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))

        let entries1: [RemoteExplorer.RemoteEntry] = [
            .init(name: "src", isDirectory: true),
            .init(name: "file.txt", isDirectory: false)
        ]
        node.applyEntries(entries1)

        let srcChild = node.children?[0]
        XCTAssertEqual(srcChild?.name, "src")

        // Expand src so we can verify it's preserved
        srcChild?.isExpanded = true

        // Apply updated entries with same src directory
        let entries2: [RemoteExplorer.RemoteEntry] = [
            .init(name: "src", isDirectory: true),
            .init(name: "README.md", isDirectory: false)
        ]
        node.applyEntries(entries2)

        // Same src node object should be reused (preserving expanded state)
        XCTAssertTrue(node.children?[0] === srcChild)
        XCTAssertTrue(node.children?[0].isExpanded ?? false)
    }

    func testApplyEntriesResetsLoadFailed() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))
        node.loadFailed = true
        node.applyEntries([])
        XCTAssertFalse(node.loadFailed)
    }

    // MARK: - resetForRetry

    func testResetForRetry() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))
        node.loadFailed = true
        node.resetForRetry()
        XCTAssertFalse(node.loadFailed)
    }

    // MARK: - Session Properties

    func testSSHSessionProperties() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))
        XCTAssertEqual(node.session, .ssh(host: "devbox"))
    }

    // MARK: - Child Path Construction

    func testApplyEntriesChildPathsCorrect() {
        let node = RemoteFileTreeNode(
            name: "project", remotePath: "/home/user/project", isDirectory: true, session: .ssh(host: "devbox"))
        let entries: [RemoteExplorer.RemoteEntry] = [
            .init(name: "src", isDirectory: true),
            .init(name: "Makefile", isDirectory: false)
        ]
        node.applyEntries(entries)
        XCTAssertEqual(node.children?[0].remotePath, "/home/user/project/src")
        XCTAssertEqual(node.children?[1].remotePath, "/home/user/project/Makefile")
    }

    // MARK: - updatePath Retry Reset

    /// updatePath must reset retry state so navigation (cd) gets a fresh retry budget.
    /// Without this, a node that exhausted retries on the initial load would never
    /// retry when the user navigates to a new directory.
    func testUpdatePathResetsRetryState() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))

        // Simulate exhausted retries from a failed initial load
        node.loadFailed = true
        node.isLoading = false

        // Navigate to a new directory
        node.updatePath("/home/user/project")

        XCTAssertFalse(node.loadFailed, "updatePath must clear loadFailed")
        XCTAssertFalse(node.isLoading, "updatePath must clear isLoading")
        XCTAssertEqual(node.remotePath, "/home/user/project")
        XCTAssertEqual(node.name, "project")
    }

    /// updatePath must cancel any in-flight retry timer to prevent stale retries
    /// from interfering with the new path's load.
    func testUpdatePathCancelsIsLoading() {
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: .ssh(host: "devbox"))

        // Simulate a load in progress
        node.isLoading = true

        // Navigate to a new directory
        node.updatePath("/tmp")

        XCTAssertFalse(
            node.isLoading,
            "updatePath must clear isLoading so the next loadChildren isn't blocked")
    }

    // MARK: - Session with Alias

    func testNodeUsesConnectionTargetForSSH() {
        let session = RemoteSessionType.ssh(host: "devbox", alias: "devbox")
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: session)
        XCTAssertEqual(
            node.session.sshConnectionTarget, "devbox",
            "Node should use alias for SSH connection")
    }

    func testNodeWithDifferentHostAndAlias() {
        let session = RemoteSessionType.ssh(host: "root@ubuntu-server", alias: "devbox")
        let node = RemoteFileTreeNode(name: "root", remotePath: "~", isDirectory: true, session: session)
        XCTAssertEqual(
            node.session.sshConnectionTarget, "devbox",
            "Connection target must be the alias, not the display host")
        XCTAssertEqual(
            node.session.displayName, "root@ubuntu-server",
            "Display name should show the full host")
    }
}
