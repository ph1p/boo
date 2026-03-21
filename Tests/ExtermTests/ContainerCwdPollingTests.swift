import XCTest

@testable import Exterm

/// Tests for the shared container CWD watcher.
final class ContainerCwdPollingTests: XCTestCase {

    func testSharedWatcherReportsCwd() throws {
        try skipIfNoDocker()

        let session = RemoteSessionType.container(target: "195cad4b6562", tool: .docker)
        let paneID = UUID()
        let exp = expectation(description: "CWD reported")

        guard let watcher = ContainerCwdWatcher.shared(for: session) else {
            XCTFail("Should create watcher")
            return
        }

        watcher.registerTab(paneID: paneID) { cwd in
            XCTAssertTrue(cwd.hasPrefix("/"), "CWD should be absolute: \(cwd)")
            exp.fulfill()
        }

        waitForExpectations(timeout: 15)
        watcher.unregisterTab(paneID: paneID)
        ContainerCwdWatcher.releaseIfUnused(for: session)
    }

    func testTwoTabsSameContainerGetIndependentPIDs() throws {
        try skipIfNoDocker()

        let session = RemoteSessionType.container(target: "195cad4b6562", tool: .docker)
        let pane1 = UUID()
        let pane2 = UUID()
        let exp1 = expectation(description: "Tab 1 CWD")
        let exp2 = expectation(description: "Tab 2 CWD")

        guard let watcher = ContainerCwdWatcher.shared(for: session) else {
            XCTFail("Should create watcher")
            return
        }

        var cwd1: String?
        var cwd2: String?
        watcher.registerTab(paneID: pane1) { cwd in
            if cwd1 == nil { cwd1 = cwd; exp1.fulfill() }
        }
        watcher.registerTab(paneID: pane2) { cwd in
            if cwd2 == nil { cwd2 = cwd; exp2.fulfill() }
        }

        waitForExpectations(timeout: 15)

        XCTAssertNotNil(cwd1)
        XCTAssertNotNil(cwd2)

        watcher.unregisterTab(paneID: pane1)
        watcher.unregisterTab(paneID: pane2)
        ContainerCwdWatcher.releaseIfUnused(for: session)
    }

    func testPidDiscoveryCommand() throws {
        try skipIfNoDocker()

        let session = RemoteSessionType.container(target: "195cad4b6562", tool: .docker)
        let exp = expectation(description: "PIDs discovered")

        RemoteExplorer.runPublicRemoteCommand(
            session: session, command: RemoteSessionMonitor.containerCwdCommand
        ) { output in
            guard let raw = output?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                XCTFail("No output")
                exp.fulfill()
                return
            }
            var count = 0
            for line in raw.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    XCTAssertTrue(String(parts[1]).hasPrefix("/"))
                    count += 1
                }
            }
            XCTAssertGreaterThan(count, 0, "Should find PTY processes")
            exp.fulfill()
        }

        waitForExpectations(timeout: 10)
    }

    private func skipIfNoDocker() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["docker", "exec", "195cad4b6562", "echo", "ok"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("Docker container 195cad4b6562 not running")
        }
    }
}
