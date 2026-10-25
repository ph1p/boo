import XCTest

@testable import Boo

/// The remote source's scripts are plain POSIX `sh`, so they run against a temp folder on
/// this Mac exactly as they would on the remote host; parsing is checked on that output.
final class RemoteFileTreeSourceTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("RemoteSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Resolve /var → /private/var so git's paths and ours agree.
        dir = (dir as NSString).resolvingSymlinksInPath
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func sh(_ script: String, in cwd: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd ?? dir)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Remote scripts must always exit 0")
        return String(decoding: data, as: UTF8.self)
    }

    private func touch(_ relative: String) {
        let path = (dir as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    private func mkdir(_ relative: String) {
        try? FileManager.default.createDirectory(
            atPath: (dir as NSString).appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(relative))
    }

    // MARK: - Listing

    func testListingBatchesDirectoriesAndSortsFoldersFirst() throws {
        touch("b.txt")
        touch("A.md")
        touch(".hidden")
        mkdir("src")
        touch("src/main.swift")
        let src = (dir as NSString).appendingPathComponent("src")

        let output = try sh(RemoteFileTreeSource.listScript([dir, src]))
        let listings = RemoteFileTreeSource.parseListing(output, paths: [dir, src])

        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings[0]?.map(\.name), ["src", ".hidden", "A.md", "b.txt"])
        XCTAssertEqual(listings[0]?.first?.isDir, true)
        XCTAssertEqual(listings[0]?.first?.path, src)
        XCTAssertEqual(listings[1]?.map(\.path), [(src as NSString).appendingPathComponent("main.swift")])
    }

    func testListingMarksMissingDirectoryUnreadable() throws {
        mkdir("empty")
        let empty = (dir as NSString).appendingPathComponent("empty")
        let missing = (dir as NSString).appendingPathComponent("gone")

        let output = try sh(RemoteFileTreeSource.listScript([missing, empty]))
        let listings = RemoteFileTreeSource.parseListing(output, paths: [missing, empty])

        XCTAssertNil(listings[0], "A folder that can't be read must report a failure, not an empty listing")
        XCTAssertEqual(listings[1]?.count, 0)
    }

    func testListingIgnoresShellNoiseBeforeFirstSection() {
        let output = "Welcome to Ubuntu\nLast login: today\n\u{1E}\nsrc/\nREADME\n"
        let listings = RemoteFileTreeSource.parseListing(output, paths: ["/home/u"])
        XCTAssertEqual(listings[0]?.map(\.name), ["src", "README"])
        XCTAssertEqual(listings[0]?.map(\.path), ["/home/u/src", "/home/u/README"])
    }

    func testListingWithMissingSectionsFails() {
        let listings = RemoteFileTreeSource.parseListing("", paths: ["/a", "/b"])
        XCTAssertEqual(listings.count, 2)
        XCTAssertNil(listings[0])
        XCTAssertNil(listings[1])
    }

    func testListingHandlesNamesNeedingQuotes() throws {
        let odd = "it's a \"dir\" $HOME"
        mkdir(odd)
        touch("\(odd)/file")
        let path = (dir as NSString).appendingPathComponent(odd)

        let output = try sh(RemoteFileTreeSource.listScript([path]))
        XCTAssertEqual(RemoteFileTreeSource.parseListing(output, paths: [path])[0]?.map(\.name), ["file"])
    }

    func testChildPathAtFilesystemRoot() {
        XCTAssertEqual(RemoteFileTreeSource.childPath("/", "etc"), "/etc")
        XCTAssertEqual(RemoteFileTreeSource.childPath("/srv", "app"), "/srv/app")
    }

    // MARK: - Index

    func testIndexWithoutGitUsesFindAndSkipsHeavyFolders() throws {
        touch("src/a.swift")
        touch("node_modules/pkg/index.js")
        let output = try sh(RemoteFileTreeSource.indexScript(dir))
        XCTAssertTrue(output.hasPrefix("F\n"))
        let paths = Set(RemoteFileTreeSource.parseIndex(output, showHidden: false).map(\.relativePath))
        XCTAssertTrue(paths.contains("src/a.swift"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("node_modules") })
    }

    func testIndexInGitRepoUsesLsFiles() throws {
        _ = try sh("git init -q .")
        touch("tracked.txt")
        touch("ignored.log")
        try "*.log\n".write(
            toFile: (dir as NSString).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let output = try sh(RemoteFileTreeSource.indexScript(dir))
        XCTAssertTrue(output.hasPrefix("G\n"))
        let paths = Set(RemoteFileTreeSource.parseIndex(output, showHidden: false).map(\.relativePath))
        XCTAssertTrue(paths.contains("tracked.txt"))
        XCTAssertFalse(paths.contains("ignored.log"))
    }

    func testIndexOfUnknownOutputIsEmpty() {
        XCTAssertTrue(RemoteFileTreeSource.parseIndex("", showHidden: true).isEmpty)
    }

    // MARK: - Git status

    func testGitStatusFromSubfolderResolvesRepoRoot() throws {
        _ = try sh("git init -q .")
        touch("sub/new.txt")
        let sub = (dir as NSString).appendingPathComponent("sub")

        let output = try sh(RemoteFileTreeSource.gitStatusScript(sub))
        let status = try XCTUnwrap(RemoteFileTreeSource.parseGitStatus(output, rootPath: sub))
        XCTAssertEqual(status.repoRoot, dir)
        XCTAssertNotNil(
            status.entries[(sub as NSString).appendingPathComponent("new.txt")]
                ?? status.entries[sub],
            "The untracked file (or its folder) must be decorated")
    }

    func testGitStatusOutsideRepoIsNil() throws {
        let output = try sh(RemoteFileTreeSource.gitStatusScript(dir))
        XCTAssertNil(RemoteFileTreeSource.parseGitStatus(output, rootPath: dir))
    }

    // MARK: - Info

    func testInfoReportsSizeForFiles() throws {
        try Data(count: 2048).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("blob")))
        let output = try sh(RemoteFileTreeSource.infoScript((dir as NSString).appendingPathComponent("blob")))
        let summary = try XCTUnwrap(RemoteFileTreeSource.parseInfo(output))
        XCTAssertTrue(summary.contains("KB"), summary)
        XCTAssertTrue(summary.contains("Modified"), summary)
    }

    func testInfoParsesGNUStatForDirectories() {
        let summary = RemoteFileTreeSource.parseInfo("4096 1700000000 directory\n")
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.contains("KB") ?? true, "Folder sizes are meaningless and must be omitted")
    }

    func testInfoRejectsGarbage() {
        XCTAssertNil(RemoteFileTreeSource.parseInfo(""))
        XCTAssertNil(RemoteFileTreeSource.parseInfo("stat: cannot stat"))
    }

    // MARK: - Operations

    func testOperationScriptReportsFailureInBand() throws {
        let ok = try sh(RemoteFileTreeSource.operationScript("true"))
        XCTAssertNil(RemoteFileTreeSource.failureMessage(in: ok))

        let failed = try sh(RemoteFileTreeSource.operationScript("echo boom >&2; false"))
        XCTAssertEqual(RemoteFileTreeSource.failureMessage(in: failed), "boom")

        let silent = try sh(RemoteFileTreeSource.operationScript("false"))
        XCTAssertEqual(RemoteFileTreeSource.failureMessage(in: silent), "Remote command failed")
    }

    func testMoveRefusesToOverwrite() throws {
        touch("a.txt")
        touch("b.txt")
        let a = (dir as NSString).appendingPathComponent("a.txt")
        let b = (dir as NSString).appendingPathComponent("b.txt")
        let c = (dir as NSString).appendingPathComponent("c.txt")

        let blocked = try sh(RemoteFileTreePlugin.moveScript(from: a, to: b))
        XCTAssertNotNil(RemoteFileTreeSource.failureMessage(in: blocked))
        XCTAssertTrue(exists("a.txt"))

        let moved = try sh(RemoteFileTreePlugin.moveScript(from: a, to: c))
        XCTAssertNil(RemoteFileTreeSource.failureMessage(in: moved))
        XCTAssertFalse(exists("a.txt"))
        XCTAssertTrue(exists("c.txt"))
    }

    func testCreatePicksFreeName() throws {
        for _ in 0..<3 {
            let output = try sh(
                RemoteFileTreePlugin.createScript(in: dir, baseName: "New Folder", command: "mkdir -- \"$n\""))
            XCTAssertNil(RemoteFileTreeSource.failureMessage(in: output))
        }
        XCTAssertTrue(exists("New Folder"))
        XCTAssertTrue(exists("New Folder 2"))
        XCTAssertTrue(exists("New Folder 3"))

        _ = try sh(RemoteFileTreePlugin.createScript(in: dir, baseName: "New File", command: ": > \"$n\""))
        XCTAssertTrue(exists("New File"))
    }

    func testDuplicateUsesCopyNaming() throws {
        try "x".write(toFile: (dir as NSString).appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let path = (dir as NSString).appendingPathComponent("notes.md")
        _ = try sh(RemoteFileTreePlugin.duplicateScript(path))
        _ = try sh(RemoteFileTreePlugin.duplicateScript(path))
        XCTAssertTrue(exists("notes copy.md"))
        XCTAssertTrue(exists("notes copy 2.md"))

        mkdir("pkg")
        touch("pkg/inner")
        _ = try sh(RemoteFileTreePlugin.duplicateScript((dir as NSString).appendingPathComponent("pkg")))
        XCTAssertTrue(exists("pkg copy/inner"), "Folders duplicate recursively")
    }

    // MARK: - Transfer scripts

    func testTransferRoundTripThroughTar() throws {
        touch("src/a.txt")
        touch("-dash")
        mkdir("dest")
        let script = RemoteFileTransfer.downloadScript(parent: dir, names: ["src", "-dash"])
        let dest = (dir as NSString).appendingPathComponent("dest")
        _ = try sh("{ \(script); } | { \(RemoteFileTransfer.uploadScript(destination: dest)); }")
        XCTAssertTrue(exists("dest/src/a.txt"))
        XCTAssertTrue(exists("dest/-dash"), "A leading dash must not be read as a tar option")
    }

    func testGroupedByParentKeepsOrder() {
        let groups = RemoteFileTransfer.groupedByParent(["/a/x", "/b/y", "/a/z", "/top"])
        XCTAssertEqual(groups.map(\.parent), ["/a", "/b", "/"])
        XCTAssertEqual(groups.map(\.names), [["x", "z"], ["y"], ["top"]])
    }

    func testTransferUnsupportedForTTYContainers() {
        XCTAssertFalse(RemoteFileTransfer.isSupported(.container(target: "phone", tool: .adb)))
        XCTAssertTrue(RemoteFileTransfer.isSupported(.container(target: "web", tool: .docker)))
        XCTAssertTrue(RemoteFileTransfer.isSupported(.ssh(host: "devbox")))
    }

    // MARK: - Retry policy

    func testRetryPolicyGivesUpOnFailedConnection() {
        var policy = RemoteListingRetryPolicy()
        XCTAssertNil(policy.next(isSSHBased: true, state: .failed))
    }

    func testRetryPolicyReconnectsReadyMasterOnce() {
        var policy = RemoteListingRetryPolicy()
        let first = policy.next(isSSHBased: true, state: .ready)
        XCTAssertEqual(first?.reconnect, true)
        var steps = 1
        while let step = policy.next(isSSHBased: true, state: .ready) {
            XCTAssertFalse(step.reconnect, "The rebuild is requested only once")
            steps += 1
        }
        XCTAssertEqual(steps, RemoteListingRetryPolicy.initialBudget - 10)
    }

    func testRetryPolicyPollsWhileConnecting() {
        var policy = RemoteListingRetryPolicy()
        var steps = 0
        while let step = policy.next(isSSHBased: true, state: .connecting) {
            XCTAssertEqual(step.delay, 1)
            steps += 1
        }
        XCTAssertEqual(steps, RemoteListingRetryPolicy.initialBudget)
    }

    func testRetryPolicyContainerBudget() {
        var policy = RemoteListingRetryPolicy()
        var steps = 0
        while policy.next(isSSHBased: false, state: nil) != nil { steps += 1 }
        XCTAssertEqual(steps, RemoteListingRetryPolicy.initialBudget - 10)
    }
}
