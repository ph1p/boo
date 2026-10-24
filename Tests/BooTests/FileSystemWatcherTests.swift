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
}
