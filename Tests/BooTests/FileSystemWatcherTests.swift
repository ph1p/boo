import XCTest

@testable import Boo

final class FileSystemWatcherTests: XCTestCase {
    func testRootChangedFiresWhenWatchedFolderIsDeleted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rootChanged = expectation(description: "root changed")
        rootChanged.assertForOverFulfill = false
        let watcher = FileSystemWatcher(path: dir.path, onRootChanged: { rootChanged.fulfill() }, onChange: { _ in })
        watcher.start()
        defer { watcher.stop() }
        // FSEvents only reports changes after the stream is live.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        try FileManager.default.removeItem(at: dir)
        wait(for: [rootChanged], timeout: 5)
    }

    func testRootChangedQuietWhileFolderStays() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rootChanged = expectation(description: "root changed")
        rootChanged.isInverted = true
        let changed = expectation(description: "content changed")
        changed.assertForOverFulfill = false
        let watcher = FileSystemWatcher(
            path: dir.path, onRootChanged: { rootChanged.fulfill() }, onChange: { _ in changed.fulfill() })
        watcher.start()
        defer { watcher.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        try Data().write(to: dir.appendingPathComponent("file"))
        wait(for: [changed, rootChanged], timeout: 1)
    }

    func testChangesArriveOnMainAndStopAfterStop() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let changed = expectation(description: "content changed")
        changed.assertForOverFulfill = false
        var filteredOnMain = true
        var calls = 0
        let watcher = FileSystemWatcher(
            path: dir.path,
            filter: { path in
                if Thread.isMainThread { filteredOnMain = true }
                return !path.hasSuffix("skip")
            },
            onChange: { paths in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertFalse(paths.contains { $0.hasSuffix("skip") })
                calls += 1
                changed.fulfill()
            })
        filteredOnMain = false
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        try Data().write(to: dir.appendingPathComponent("file"))
        wait(for: [changed], timeout: 5)
        XCTAssertFalse(filteredOnMain)

        watcher.stop()
        let before = calls
        try Data().write(to: dir.appendingPathComponent("after"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(calls, before)
    }

    func testGitWatcherSkipsBuildOutputInsideTheRepo() {
        let root = "/Users/me/target/app"
        XCTAssertTrue(GitPlugin.isBuildOutput("\(root)/node_modules/x/index.js", repoRoot: root))
        XCTAssertTrue(GitPlugin.isBuildOutput("\(root)/pkg/.build/debug/a.o", repoRoot: root))
        XCTAssertFalse(GitPlugin.isBuildOutput("\(root)/src/main.swift", repoRoot: root))
        XCTAssertFalse(GitPlugin.isBuildOutput("\(root)/src/targets.swift", repoRoot: root))
        // The repo's own parent folder named `target` does not count.
        XCTAssertFalse(GitPlugin.isBuildOutput("/private\(root)/README.md", repoRoot: root))
    }
}
