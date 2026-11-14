import XCTest

@testable import Boo

final class RuleEngineProfileTests: XCTestCase {
    private let profiles = ["manual", "ruleA", "ruleB", "workspace", "global"].map { Profile(name: $0) }

    // MARK: - basedOn

    func testBasedOnFillsMissingFields() {
        let base = Profile(
            name: "base", theme: "Boo Dark", fontSize: 14, env: ["A": "1", "B": "1"], cursorStyle: "beam",
            tabColor: "#FF0000", badge: "BASE")
        let child = Profile(name: "child", fontSize: 18, env: ["B": "2"], badge: "KID", basedOn: "base")
        let grandchild = Profile(name: "grandchild", theme: "Boo Light", basedOn: "child")
        let (resolved, problems) = ProfileFile.resolve([grandchild, child, base])
        XCTAssertEqual(problems, [])
        XCTAssertEqual(resolved.map(\.name), ["grandchild", "child", "base"])
        let kid = resolved[1]
        XCTAssertEqual(kid.theme, "Boo Dark")
        XCTAssertEqual(kid.fontSize, 18)
        XCTAssertEqual(kid.env, ["A": "1", "B": "2"])
        XCTAssertEqual(kid.cursorStyle, "beam")
        XCTAssertEqual(kid.tabColor, "#FF0000")
        XCTAssertEqual(kid.badge, "KID")
        XCTAssertEqual(kid.basedOn, "base")
        XCTAssertEqual(resolved[0].theme, "Boo Light")
        XCTAssertEqual(resolved[0].fontSize, 18)
        XCTAssertEqual(resolved[2], base)
    }

    func testBasedOnLoopAndMissingParentStayUnmerged() {
        let a = Profile(name: "a", theme: "Boo Dark", basedOn: "b")
        let b = Profile(name: "b", fontSize: 20, basedOn: "a")
        let intoLoop = Profile(name: "c", basedOn: "a")
        let orphan = Profile(name: "d", badge: "X", basedOn: "gone")
        let selfBased = Profile(name: "e", basedOn: "e")
        let all = [a, b, intoLoop, orphan, selfBased]
        let (resolved, problems) = ProfileFile.resolve(all)
        XCTAssertEqual(resolved, all)
        XCTAssertEqual(problems.count, 5)
        XCTAssertEqual(problems.filter { $0.contains("loop") }.count, 4)
        XCTAssertTrue(problems.contains { $0.contains("\"d\"") && $0.contains("\"gone\"") })
    }

    func testParseDropsBadLookFieldsOnly() throws {
        let json = """
            {"profiles": [{"name": "p", "cursorStyle": "wobble", "tabColor": "red", "badge": "  ", "fontSize": 12},
                          {"name": "q", "cursorStyle": "Outline", "tabColor": "#00ff00", "badge": "Q"}]}
            """
        let (profiles, problems) = try ProfileFile.parse(Data(json.utf8))
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(problems.count, 2)
        XCTAssertNil(profiles[0].cursorStyle)
        XCTAssertNil(profiles[0].tabColor)
        XCTAssertNil(profiles[0].badge)
        XCTAssertEqual(profiles[0].fontSize, 12)
        XCTAssertEqual(CursorStyle(profileValue: profiles[1].cursorStyle ?? ""), .blockOutline)
        XCTAssertEqual(profiles[1].badge, "Q")
    }

    func testSurfaceStyleCarriesProfileCursor() {
        let plain = SurfaceStyle(profile: Profile(name: "p"), workspace: nil)
        let beam = SurfaceStyle(profile: Profile(name: "p", cursorStyle: "beam"), workspace: nil)
        XCTAssertTrue(plain.isDefault)
        XCTAssertFalse(beam.isDefault)
        XCTAssertNotEqual(plain.cacheKey, beam.cacheKey)
    }

    private func resolve(
        override: String? = nil, rules: [(String, String)] = [], workspace: String? = nil, global: String? = nil
    ) -> ProfileResolution? {
        ProfileResolver.resolve(
            override: override,
            ruleMatches: rules.map { RuleMatcher.ProfileMatch(name: $0.0, ruleID: $0.1) },
            workspaceDefault: workspace, globalDefault: global, profiles: profiles)
    }

    func testOrder() {
        let all = resolve(
            override: "manual", rules: [("ruleA", "r1"), ("ruleB", "r2")], workspace: "workspace", global: "global")
        XCTAssertEqual(all?.profile.name, "manual")
        XCTAssertEqual(all?.source, .manual)

        let rule = resolve(rules: [("ruleA", "r1"), ("ruleB", "r2")], workspace: "workspace", global: "global")
        XCTAssertEqual(rule?.profile.name, "ruleA")
        XCTAssertEqual(rule?.source, .rule("r1"))

        let workspace = resolve(workspace: "workspace", global: "global")
        XCTAssertEqual(workspace?.profile.name, "workspace")
        XCTAssertEqual(workspace?.source, .workspaceDefault)

        let global = resolve(global: "global")
        XCTAssertEqual(global?.profile.name, "global")
        XCTAssertEqual(global?.source, .globalDefault)

        XCTAssertNil(resolve())
    }

    func testMissingNamesFallThrough() {
        let nextRule = resolve(override: "gone", rules: [("gone", "r1"), ("ruleB", "r2")], global: "global")
        XCTAssertEqual(nextRule?.profile.name, "ruleB")
        XCTAssertEqual(nextRule?.source, .rule("r2"))

        let global = resolve(override: "gone", rules: [("gone", "r1")], workspace: "gone", global: "global")
        XCTAssertEqual(global?.source, .globalDefault)

        XCTAssertNil(resolve(override: "gone", rules: [("gone", "r1")], workspace: "gone", global: "gone"))
    }

    func testProfileMatchesKeepFileOrderAndRuleIDs() throws {
        let json = """
            [{"id": "first", "when": {"process": "vim"}, "then": {"profile": "A"}},
             {"id": "off", "enabled": false, "when": {"process": "vim"}, "then": {"profile": "X"}},
             {"id": "other", "when": {"process": "top"}, "then": {"profile": "Y"}},
             {"id": "second", "when": {"process": "v*"}, "then": {"profile": "B"}}]
            """
        let set = try RuleSet.parse(Data(json.utf8)).set
        let context = RuleContext(host: nil, cwd: "/", container: nil, kubeContext: nil, process: "vim")
        XCTAssertEqual(
            RuleMatcher.profileMatches(for: context, in: set),
            [.init(name: "A", ruleID: "first"), .init(name: "B", ruleID: "second")])
    }

    @MainActor
    func testSourceLabel() {
        XCTAssertEqual(
            RuleEngine.profileSourceLabel(profile: "prod", source: .rule("prod-hosts")), "prod: rule \"prod-hosts\"")
        XCTAssertEqual(RuleEngine.profileSourceLabel(profile: "prod", source: .manual), "prod: picked by hand")
        XCTAssertEqual(RuleEngine.profileSourceLabel(profile: "prod", source: .globalDefault), "prod: default")
        XCTAssertEqual(
            RuleEngine.profileSourceLabel(profile: "prod", source: .workspaceDefault), "prod: workspace default")
        XCTAssertNil(RuleEngine.profileSourceLabel(profile: nil, source: nil))
    }

    func testSessionTabRoundTripsProfileOverride() throws {
        let data = try JSONEncoder().encode(SessionTab(profileOverride: "prod"))
        XCTAssertEqual(try JSONDecoder().decode(SessionTab.self, from: data).profileOverride, "prod")
        XCTAssertNil(try JSONDecoder().decode(SessionTab.self, from: Data("{}".utf8)).profileOverride)
    }

    @MainActor
    func testSnapshotKeepsProfileOverride() throws {
        let state = AppState()
        let workspace = Workspace(folderPath: "/tmp")
        state.addWorkspace(workspace)
        let pane = try XCTUnwrap(workspace.pane(for: workspace.activePaneID))
        pane.setProfile(at: 0, override: "prod", effective: "prod", source: .manual)

        let window = SessionStore.buildWindow(appState: state)
        XCTAssertEqual(window.workspaces.first?.panes.first?.tabs.first?.profileOverride, "prod")

        let restored = SessionStore.workspaces(from: window)
        let tab = try XCTUnwrap(restored.first?.panes.values.first?.tabs.first)
        XCTAssertEqual(tab.state.profileOverride, "prod")
        XCTAssertNil(tab.state.profile)
    }

    func testUnknownProfileProblems() throws {
        let json = """
            [{"id": "ok", "when": {"process": "vim"}, "then": {"profile": "A"}},
             {"id": "bad", "when": {"process": "vim"}, "then": {"profile": "Gone"}},
             {"id": "off", "enabled": false, "when": {"process": "vim"}, "then": {"profile": "Gone"}}]
            """
        let set = try RuleSet.parse(Data(json.utf8)).set
        let problems = set.unknownProfileProblems(known: ["A"])
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("\"bad\""))
    }
}
