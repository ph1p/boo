import Combine
import XCTest

@testable import Boo

final class ProjectTasksTests: XCTestCase {
    func testPackageScriptsKeepFileOrderAndUseManager() {
        let json = #"{"name":"x","scripts":{"dev":"vite","build":"vite build","test:unit":"vitest"},"version":"1"}"#
        let tasks = ProjectTaskScanner.packageScripts(json, manager: "pnpm")
        XCTAssertEqual(tasks.map(\.name), ["dev", "build", "test:unit"])
        XCTAssertEqual(tasks.map(\.command), ["pnpm run dev", "pnpm run build", "pnpm run test:unit"])
        XCTAssertEqual(tasks[1].detail, "vite build")
    }

    func testPackageManagerPrefersFieldThenLockfile() {
        XCTAssertEqual(
            ProjectTaskScanner.packageManager(
                packageJSON: #"{"packageManager":"yarn@4.1.0"}"#, lockfiles: ["pnpm-lock.yaml"]), "yarn")
        XCTAssertEqual(ProjectTaskScanner.packageManager(packageJSON: "{}", lockfiles: ["pnpm-lock.yaml"]), "pnpm")
        XCTAssertEqual(ProjectTaskScanner.packageManager(packageJSON: "{}", lockfiles: ["bun.lock"]), "bun")
        XCTAssertEqual(ProjectTaskScanner.packageManager(packageJSON: "{}", lockfiles: []), "npm")
    }

    func testMakeTargets() {
        let text = """
            .PHONY: build test
            VERSION := 1.0
            CC ?= clang
            build: deps ## Build the app
            \tswift build
            test lint:
            \tmake check
            %.o: %.c
            $(OUT): build
            build:
            """
        let tasks = ProjectTaskScanner.makeTargets(text)
        XCTAssertEqual(tasks.map(\.name), ["build", "test", "lint"])
        XCTAssertEqual(tasks.first?.detail, "Build the app")
        XCTAssertEqual(tasks.first?.command, "make build")
    }

    func testJustRecipes() {
        let text = """
            set shell := ["bash", "-c"]
            version := "1.0"
            alias b := build

            # Build everything
            build:
                cargo build

            @deploy env="staging" target:
                echo {{env}}

            _helper:
                true

            [private]
            hidden:
                true
            """
        let tasks = ProjectTaskScanner.justRecipes(text)
        XCTAssertEqual(tasks.map(\.name), ["build", "deploy"])
        XCTAssertEqual(tasks[0].detail, "Build everything")
        XCTAssertEqual(tasks[1].detail, #"args: env="staging" target"#)
        XCTAssertEqual(tasks[1].command, "just deploy")
    }

    func testCargoAndSwiftTasks() {
        XCTAssertEqual(
            ProjectTaskScanner.cargoTasks("[package]\nname = \"x\"").map(\.name),
            ["build", "test", "run", "check", "clippy"])
        XCTAssertFalse(ProjectTaskScanner.cargoTasks("[workspace]\nmembers = []").map(\.name).contains("run"))
        XCTAssertEqual(
            ProjectTaskScanner.swiftTasks(".executableTarget(name: \"x\")").map(\.command),
            ["swift build", "swift test", "swift run"])
    }

    func testGroupsFindNearestFolderAndRepoRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("packages/web")
        let nested = package.appendingPathComponent("src/lib")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "build:\n\ttrue\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try #"{"scripts":{"dev":"vite"}}"#.write(
            to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: package.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)

        let rootPath = ProjectTaskScanner.standardized(root.path)
        let groups = ProjectTaskScanner.groups(cwd: nested.path, repoRoot: root.path)
        XCTAssertEqual(groups.map(\.root), [ProjectTaskScanner.standardized(package.path), rootPath])
        XCTAssertEqual(groups.first?.tasks.map(\.command), ["pnpm run dev"])
        XCTAssertEqual(groups.last?.tasks.map(\.command), ["make build"])

        XCTAssertEqual(ProjectTaskScanner.groups(cwd: root.path, repoRoot: root.path).map(\.root), [rootPath])
    }

    @MainActor
    func testRunStoreRecordsExitAndOrdersRecentFirst() {
        let commands = PassthroughSubject<FinishedCommand, Never>()
        let store = TaskRunStore(file: nil, commands: commands.eraseToAnyPublisher())
        let group = ProjectTaskGroup(
            root: "/p/app",
            tasks: ["build", "test", "lint"].map { ProjectTask(tool: "make", name: $0, command: "make \($0)") })
        let test = group.tasks[1]

        guard case .terminalWithCommand(let dir, let command) = store.start(test, in: "/p/app") else {
            return XCTFail("expected a terminal tab")
        }
        XCTAssertEqual(dir, "/p/app")
        XCTAssertEqual(command, "make test")
        XCTAssertTrue(store.isRunning(test, in: "/p/app"))
        XCTAssertEqual(store.ordered(group).map(\.name), ["test", "build", "lint"])

        func finish(_ command: String, cwd: String, exit: Int32) {
            commands.send(
                FinishedCommand(
                    command: command, exitCode: exit, duration: 3, startedAt: Date(), cwd: cwd, host: nil,
                    workspaceID: UUID(), paneID: UUID(), tabID: UUID()))
        }
        finish("make test", cwd: "/p/other", exit: 1)
        XCTAssertTrue(store.isRunning(test, in: "/p/app"), "another folder's run doesn't count")
        finish("make test", cwd: "/p/app/", exit: 2)
        XCTAssertFalse(store.isRunning(test, in: "/p/app"))
        XCTAssertEqual(store.lastRun(of: test, in: "/p/app")?.exitCode, 2)
        XCTAssertEqual(store.lastRun(of: test, in: "/p/app")?.duration, 3)
        XCTAssertNil(store.lastRun(of: group.tasks[0], in: "/p/app"))
    }
}
