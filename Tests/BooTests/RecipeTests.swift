import XCTest

@testable import Boo

@MainActor
final class RecipeTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("boo-recipes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir + "/api", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func decode(_ json: String) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    // MARK: - Format

    func testDecodesNestedLayout() throws {
        let recipe = try decode(
            """
            { "name": "dev", "folder": "~/code",
              "layout": { "split": "right", "ratio": 0.6,
                "a": { "tabs": [{ "command": "pnpm dev" }, {}] },
                "b": { "split": "down", "a": {}, "b": { "tabs": [{ "cwd": "./api", "env": { "PORT": "4000" } }] } } } }
            """)
        XCTAssertEqual(recipe.name, "dev")
        XCTAssertEqual(
            recipe.layout,
            .split(
                .right, ratio: 0.6, a: .tabs([Recipe.Tab(command: "pnpm dev"), Recipe.Tab()]),
                b: .split(
                    .down, ratio: 0.5, a: .tabs([]), b: .tabs([Recipe.Tab(cwd: "./api", env: ["PORT": "4000"])]))))
    }

    func testRatioIsClampedAndRoundTrips() throws {
        let recipe = try decode(#"{"folder":"/tmp","layout":{"split":"down","ratio":2,"a":{},"b":{}}}"#)
        guard case .split(_, let ratio, _, _) = recipe.layout else { return XCTFail("not a split") }
        XCTAssertEqual(ratio, 0.9)

        let saved = Recipe(
            name: nil, folder: "/tmp", layout: .split(.right, ratio: 0.333333, a: .tabs([]), b: .tabs([])))
        let again = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(saved))
        guard case .split(.right, let r, _, _) = again.layout else { return XCTFail("not a split") }
        XCTAssertEqual(r, 0.33)
    }

    func testBadSplitDirectionNamesThePath() throws {
        let path = dir + "/bad.json"
        try Data(#"{"folder":"/tmp","layout":{"split":"right","a":{},"b":{"split":"left","a":{},"b":{}}}}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try RecipeStore.load(path)) { error in
            guard case RecipeError.invalid(_, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, #"layout.b.split: split must be "right" or "down", not "left""#)
        }
    }

    func testMissingFolderAndBrokenJSON() throws {
        let missing = dir + "/missing.json"
        try Data(#"{"layout":{}}"#.utf8).write(to: URL(fileURLWithPath: missing))
        XCTAssertThrowsError(try RecipeStore.load(missing)) { error in
            XCTAssertEqual(error as? RecipeError, .invalid(path: missing, reason: #"missing "folder""#))
        }
        let broken = dir + "/broken.json"
        try Data("{".utf8).write(to: URL(fileURLWithPath: broken))
        XCTAssertThrowsError(try RecipeStore.load(broken)) { error in
            XCTAssertEqual(error as? RecipeError, .invalid(path: broken, reason: "not JSON"))
        }
    }

    // MARK: - Plan

    func testPlanBuildsSplitTreeAndLaunches() throws {
        let recipe = Recipe(
            name: nil, folder: dir,
            layout: .split(
                .right, ratio: 0.7, a: .tabs([Recipe.Tab(command: "make watch")]),
                b: .split(.down, ratio: 0.5, a: .tabs([]), b: .tabs([Recipe.Tab(cwd: "api", env: ["A": "1"])]))))
        let plan = try recipe.plan()
        XCTAssertEqual(plan.folder, dir)
        guard case .split(.horizontal, let first, .split(.vertical, _, let last, _), let ratio) = plan.tree,
            case .leaf(let firstID) = first, case .leaf(let lastID) = last
        else { return XCTFail("unexpected tree \(plan.tree)") }
        XCTAssertEqual(ratio, 0.7, accuracy: 0.001)
        XCTAssertEqual(plan.firstPaneID, firstID)
        XCTAssertEqual(Set(plan.panes.keys), Set(plan.tree.leafIDs))
        XCTAssertEqual(plan.panes[firstID], [RecipePlan.Tab(cwd: dir, launch: LaunchSpec(command: "make watch"))])
        XCTAssertEqual(
            plan.panes[lastID], [RecipePlan.Tab(cwd: dir + "/api", launch: LaunchSpec(command: nil, env: ["A": "1"]))])
        let plain = plan.panes.values.first { $0.count == 1 && $0[0].launch == nil }
        XCTAssertEqual(plain, [RecipePlan.Tab(cwd: dir, launch: nil)], "an empty pane opens one plain tab")
    }

    func testPlanRejectsMissingFolder() {
        let recipe = Recipe(name: nil, folder: dir + "/nope", layout: .tabs([]))
        XCTAssertThrowsError(try recipe.plan()) { error in
            XCTAssertEqual(error as? RecipeError, .missingFolder(dir + "/nope"))
        }
    }

    func testExpandResolvesTildeAndRelativePaths() {
        let home = NSHomeDirectory()
        XCTAssertEqual(Recipe.expand("~/x", relativeTo: "/base"), home + "/x")
        XCTAssertEqual(Recipe.expand("/abs/../y", relativeTo: "/base"), "/y")
        XCTAssertEqual(Recipe.expand("./sub", relativeTo: "/base"), "/base/sub")
        XCTAssertEqual(Recipe.expand("sub", relativeTo: "/base"), "/base/sub")
    }

    // MARK: - Saving

    func testRecipeFromWorkspaceKeepsLayoutAndRelativeCwds() throws {
        let left = UUID()
        let right = UUID()
        let workspace = Workspace(
            folderPath: dir, id: UUID(),
            splitTree: .split(direction: .vertical, first: .leaf(id: left), second: .leaf(id: right), ratio: 0.25),
            activePaneID: left)
        let leftPane = Pane(id: left)
        leftPane.addTab(workingDirectory: dir)
        leftPane.addTab(contentType: .browser, workingDirectory: dir)
        let rightPane = Pane(id: right)
        rightPane.addTab(workingDirectory: dir + "/api")
        rightPane.addTab(workingDirectory: "/usr/bin")
        workspace.restorePane(leftPane)
        workspace.restorePane(rightPane)

        let recipe = Recipe(workspace: workspace, name: "mine", lastCommands: [rightPane.tabs[0].id: "pnpm test"])
        XCTAssertEqual(recipe.name, "mine")
        XCTAssertEqual(
            recipe.layout,
            .split(
                .down, ratio: 0.25, a: .tabs([Recipe.Tab()]),
                b: .tabs([Recipe.Tab(cwd: "./api", lastCommand: "pnpm test"), Recipe.Tab(cwd: "/usr/bin")])),
            "browser tab skipped; lastCommand is noted, never run")
        let plan = try recipe.plan()
        XCTAssertTrue(plan.panes.values.flatMap { $0 }.allSatisfy { $0.launch == nil })
    }

    func testRelative() {
        XCTAssertNil(Recipe.relative("/a/b", to: "/a/b"))
        XCTAssertEqual(Recipe.relative("/a/b/c", to: "/a/b"), "./c")
        XCTAssertEqual(Recipe.relative("/a/bc", to: "/a/b"), "/a/bc")
        XCTAssertEqual(Recipe.relative(NSHomeDirectory() + "/z", to: "/a"), "~/z")
    }

    // MARK: - Store

    func testStoreSavesListsAndFindsByName() throws {
        let recipe = Recipe(name: "Web App", folder: dir, layout: .tabs([Recipe.Tab(command: "ls")]))
        let path = try RecipeStore.save(recipe, as: "Web App", in: dir)
        XCTAssertEqual(path, dir + "/Web App.json")
        try RecipeStore.save(recipe, as: "api", in: dir)
        try Data().write(to: URL(fileURLWithPath: dir + "/.hidden.json"))
        try Data().write(to: URL(fileURLWithPath: dir + "/notes.txt"))

        XCTAssertEqual(RecipeStore.list(in: dir).map(\.name), ["api", "Web App"])
        XCTAssertEqual(try RecipeStore.entry(named: "web app", in: dir).path, path)
        XCTAssertEqual(try RecipeStore.load(path), recipe)
        XCTAssertThrowsError(try RecipeStore.entry(named: "nope", in: dir)) { error in
            XCTAssertEqual(error as? RecipeError, .notFound("nope", available: ["api", "Web App"]))
            XCTAssertEqual(error.localizedDescription, #"No recipe named "nope". Recipes: api, Web App."#)
        }
    }

    func testFileNameIsSanitized() {
        XCTAssertEqual(RecipeStore.fileName(for: "a/b:c"), "a-b-c.json")
        XCTAssertEqual(RecipeStore.fileName(for: "..secret"), "secret.json")
        XCTAssertEqual(RecipeStore.fileName(for: "  "), "recipe.json")
    }

    // MARK: - Palette

    func testPaletteHidesRecipeMenuItems() {
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        let run = NSMenuItem(title: "dev", action: #selector(MainWindowController.runRecipeAction(_:)), keyEquivalent: "")
        file.submenu?.addItem(run)
        file.submenu?.addItem(
            withTitle: "Open Recipes Folder", action: #selector(MainWindowController.openRecipesFolderAction(_:)),
            keyEquivalent: "")
        menu.addItem(file)
        XCTAssertEqual(PaletteSources.actions(menu: menu).map(\.title), ["Open Recipes Folder"])
    }
}
