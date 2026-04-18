import XCTest

@testable import Boo

@MainActor
final class AutoUpdaterTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() async throws {
        await MainActor.run {
            AutoUpdater.resetInstallHooksForTesting()
            for url in tempDirectories {
                try? FileManager.default.removeItem(at: url)
            }
            tempDirectories.removeAll()
        }
        try await super.tearDown()
    }

    func testBuildReplacementScriptStagesReplacementBeforeSwappingCurrentApp() {
        let script = AutoUpdater.buildReplacementScript(
            pid: 4242,
            currentApp: "/Applications/Boo.app",
            newApp: "/tmp/BooUpdate-123/Boo.app"
        )

        XCTAssertTrue(script.contains("trap cleanup EXIT"))
        XCTAssertTrue(script.contains("/usr/bin/ditto \"$new\" \"$replacement\""))
        XCTAssertTrue(script.contains("mv \"$current\" \"$backup\""))
        XCTAssertTrue(script.contains("mv \"$replacement\" \"$current\""))
        XCTAssertTrue(script.contains("if [ -d \"$backup\" ] && [ ! -d \"$current\" ]; then"))
        XCTAssertFalse(script.contains("rm -rf '/Applications/Boo.app'"))
    }

    func testInstallAndRelaunchReportsLauncherFailureWithoutTerminating() {
        let updater = AutoUpdater()
        let launchAttempted = expectation(description: "launch attempted")
        let fakeAppURL = makeFakeAppBundle()
        var didTerminate = false

        AutoUpdater.installHooks = .init(
            extractAppFromDMG: { _ in fakeAppURL },
            verifyCodeSignature: { _ in true },
            launchReplacementScript: { _ in
                launchAttempted.fulfill()
                return false
            },
            terminateApplication: {
                didTerminate = true
            }
        )

        updater.installAndRelaunch(dmgURL: URL(fileURLWithPath: "/tmp/fake.dmg"))

        wait(for: [launchAttempted], timeout: 1.0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(updater.state, .error("Failed to launch installer helper"))
        XCTAssertFalse(didTerminate)
    }

    func testInstallAndRelaunchTerminatesOnlyAfterHelperLaunchSucceeds() {
        let updater = AutoUpdater()
        let terminated = expectation(description: "terminate invoked")
        let fakeAppURL = makeFakeAppBundle()
        var launchCount = 0

        AutoUpdater.installHooks = .init(
            extractAppFromDMG: { _ in fakeAppURL },
            verifyCodeSignature: { _ in true },
            launchReplacementScript: { _ in
                launchCount += 1
                return true
            },
            terminateApplication: {
                terminated.fulfill()
            }
        )

        updater.installAndRelaunch(dmgURL: URL(fileURLWithPath: "/tmp/fake.dmg"))

        wait(for: [terminated], timeout: 1.0)

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(updater.state, .installing)
    }

    private func makeFakeAppBundle() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Boo.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        tempDirectories.append(root)
        return appURL
    }
}
