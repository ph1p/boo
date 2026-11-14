import XCTest

@testable import Boo

final class RuleEngineProfileTests: XCTestCase {
    private let profiles = ["manual", "ruleA", "ruleB", "workspace", "global"].map { Profile(name: $0) }

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
