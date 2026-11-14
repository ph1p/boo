import XCTest

@testable import Boo

final class RulesTests: XCTestCase {
    private func parse(_ json: String) throws -> (set: RuleSet, problems: [String]) {
        try RuleSet.parse(Data(json.utf8))
    }

    func testParsesProfileAndActionRules() throws {
        let (set, problems) = try parse(
            """
            {"rules": [
              {"id": "prod", "when": {"host": "*.prod"}, "then": {"profile": "Production"}},
              {"id": "fail", "when": {"output": "FAIL (\\\\w+)"}, "then": [{"notify": "x"}, {"markTab": {}}],
               "cooldown": 2, "altScreen": true}
            ]}
            """)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(set.rules.count, 2)
        XCTAssertEqual(set.rules[0].then, .profile("Production"))
        XCTAssertEqual(set.rules[1].then, .actions([.notify(title: nil, body: "x"), .markTab]))
        XCTAssertEqual(set.rules[1].cooldown, 2)
        XCTAssertTrue(set.rules[1].altScreen)
        XCTAssertEqual(set.contextRules.map(\.id), ["prod"])
        XCTAssertEqual(set.outputRules.map(\.id), ["fail"])
    }

    func testAcceptsBareArray() throws {
        let (set, _) = try parse(#"[{"when": {"cwd": "~/x"}, "then": {"profile": "P"}}]"#)
        XCTAssertEqual(set.rules.first?.id, "rule-1")
    }

    func testBadRulesAreSkippedAndReported() throws {
        let (set, problems) = try parse(
            """
            {"rules": [
              {"id": "a", "when": {}, "then": {"profile": "P"}},
              {"id": "b", "when": {"output": "("}, "then": [{"markTab": {}}]},
              {"id": "c", "when": {"output": "x"}, "then": {"profile": "P"}},
              {"id": "d", "when": {"host": "h"}, "then": [{"explode": 1}]},
              {"id": "e", "when": {"host": "h"}, "then": [], "cooldown": 1},
              {"id": "ok", "when": {"host": "h"}, "then": [{"run": "true"}]},
              {"id": "ok", "when": {"host": "h"}, "then": [{"run": "true"}]}
            ]}
            """)
        XCTAssertEqual(set.rules.map(\.id), ["ok", "ok#6"])
        XCTAssertEqual(problems.count, 6)
        XCTAssertTrue(problems[0].contains("no conditions"))
        XCTAssertTrue(problems[1].contains("regular expression"))
        XCTAssertTrue(problems[2].contains("can't switch profiles"))
        XCTAssertTrue(problems[3].contains("unknown action"))
    }

    func testNotJSONThrows() {
        XCTAssertThrowsError(try parse("nope"))
        XCTAssertThrowsError(try parse(#"{"x": 1}"#))
    }

    func testFingerprintIsStableAndTextSensitive() throws {
        let a = try parse(#"[{"id": "r", "when": {"host": "h"}, "then": [{"sendText": "y"}]}]"#).set.rules[0]
        let b = try parse(#"[{"then": [{"sendText": "y"}], "id": "r", "when": {"host": "h"}}]"#).set.rules[0]
        let c = try parse(#"[{"id": "r", "when": {"host": "h"}, "then": [{"sendText": "n"}]}]"#).set.rules[0]
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }

    func testDisabledRulesAreInactive() throws {
        let (set, _) = try parse(#"[{"when": {"host": "h"}, "then": {"profile": "P"}, "enabled": false}]"#)
        XCTAssertTrue(set.contextRules.isEmpty)
    }

    // MARK: Matching

    func testContextMatchingIsAND() {
        let cond = RuleCondition(host: "*.prod", cwd: "~/work/**", container: nil, kubeContext: nil, process: nil)
        let home = NSHomeDirectory()
        XCTAssertTrue(
            RuleMatcher.contextMatches(
                cond,
                RuleContext(host: "db.prod", cwd: home + "/work/a/b", container: nil, kubeContext: nil, process: "")))
        XCTAssertFalse(
            RuleMatcher.contextMatches(
                cond, RuleContext(host: "db.dev", cwd: home + "/work/a", container: nil, kubeContext: nil, process: ""))
        )
        XCTAssertFalse(
            RuleMatcher.contextMatches(
                cond, RuleContext(host: "db.prod", cwd: "/tmp", container: nil, kubeContext: nil, process: "")))
    }

    func testHostMatchesAlias() {
        let cond = RuleCondition(host: "devbox", cwd: nil, container: nil, kubeContext: nil, process: nil)
        let ctx = RuleContext(
            host: "10.0.0.5", hostAlias: "devbox", cwd: "", container: nil, kubeContext: nil, process: "")
        XCTAssertTrue(RuleMatcher.contextMatches(cond, ctx))
    }

    func testFirstMatchingProfileWins() throws {
        let (set, _) = try parse(
            """
            [{"when": {"process": "vim"}, "then": {"profile": "A"}},
             {"when": {"process": "v*"}, "then": {"profile": "B"}}]
            """)
        let ctx = RuleContext(host: nil, cwd: "/", container: nil, kubeContext: nil, process: "vim")
        XCTAssertEqual(RuleMatcher.profile(for: ctx, in: set), "A")
    }

    func testWorkspaceBranchUserAndTimeConditions() throws {
        let (set, problems) = try parse(
            """
            [{"id": "r", "when": {"workspace": "api*", "workspaceFolder": "~/work", "gitBranch": "release/*",
              "user": "root", "time": "22:00-06:00"}, "then": {"profile": "P"}}]
            """)
        XCTAssertEqual(problems, [])
        XCTAssertTrue(set.usesGitBranch)
        XCTAssertTrue(set.usesTime)
        var ctx = RuleContext(
            host: nil, cwd: "/", container: nil, kubeContext: nil, process: "", workspace: "API server",
            workspaceFolder: NSHomeDirectory() + "/work/api", gitBranch: "release/1.2", user: "root",
            minuteOfDay: 23 * 60)
        XCTAssertEqual(RuleMatcher.profile(for: ctx, in: set), "P")
        ctx.minuteOfDay = 5 * 60 + 59
        XCTAssertEqual(RuleMatcher.profile(for: ctx, in: set), "P", "the window crosses midnight")
        ctx.minuteOfDay = 6 * 60
        XCTAssertNil(RuleMatcher.profile(for: ctx, in: set), "the end is exclusive")
        ctx.minuteOfDay = nil
        XCTAssertNil(RuleMatcher.profile(for: ctx, in: set))
        ctx.minuteOfDay = 0
        for change: (inout RuleContext) -> Void in [
            { $0.workspace = "web" }, { $0.workspaceFolder = "/tmp" }, { $0.gitBranch = nil },
            { $0.gitBranch = "main" }, { $0.user = "me" }
        ] {
            var other = ctx
            change(&other)
            XCTAssertNil(RuleMatcher.profile(for: other, in: set))
        }
    }

    func testTimeRange() {
        XCTAssertEqual(TimeRange("09:00-18:30")?.start, 540)
        XCTAssertEqual(TimeRange("09:00-18:30")?.end, 1110)
        XCTAssertEqual(TimeRange("9:00 - 18:30")?.start, 540)
        XCTAssertTrue(TimeRange("09:00-18:00")?.contains(540) == true)
        XCTAssertTrue(TimeRange("09:00-18:00")?.contains(1080) == false)
        for bad in ["", "09:00", "09:00-09:00", "24:00-01:00", "09:60-10:00", "9-18", "09:0-18:00", "a:b-c:d"] {
            XCTAssertNil(TimeRange(bad), bad)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600) ?? .current
        XCTAssertEqual(TimeRange.minuteOfDay(Date(timeIntervalSince1970: 0), calendar: calendar), 60)
    }

    func testUnknownConditionWarnsAndBadTimeSkips() throws {
        let (set, problems) = try parse(
            """
            [{"id": "a", "when": {"host": "h", "hots": "x"}, "then": {"profile": "P"}},
             {"id": "b", "when": {"time": "soon"}, "then": {"profile": "P"}},
             {"id": "c", "when": {"hots": "x"}, "then": {"profile": "P"}}]
            """)
        XCTAssertEqual(set.rules.map(\.id), ["a"], "an unknown key alone leaves no condition")
        XCTAssertEqual(problems.count, 3)
        XCTAssertTrue(problems[0].contains("unknown condition \"when.hots\""))
        XCTAssertTrue(problems[1].contains("09:00-18:00"))
        XCTAssertTrue(problems[2].contains("no conditions"))
    }

    func testRuleUserComesFromTheSession() {
        XCTAssertEqual(RuleEngine.user(of: nil), NSUserName())
        XCTAssertEqual(RuleEngine.user(of: .ssh(host: "deploy@db.prod")), "deploy")
        XCTAssertNil(RuleEngine.user(of: .ssh(host: "db.prod")))
        XCTAssertNil(RuleEngine.user(of: .ssh(host: "@db.prod")))
    }

    // MARK: Glob

    func testGlobPlain() {
        XCTAssertTrue(Glob.matches("*.prod.example.com", "db.prod.example.com"))
        XCTAssertTrue(Glob.matches("web-?", "WEB-1"))
        XCTAssertFalse(Glob.matches("web-?", "web-10"))
        XCTAssertTrue(Glob.matches("a.b", "a.b"))
        XCTAssertFalse(Glob.matches("a.b", "axb"))
    }

    func testGlobPaths() {
        XCTAssertTrue(Glob.matches("/src/*", "/src/app", path: true))
        XCTAssertTrue(Glob.matches("/src/*", "/src/app/deep", path: true), "a directory pattern covers its subtree")
        XCTAssertFalse(Glob.matches("/src/*/x", "/src/a/b/x", path: true))
        XCTAssertTrue(Glob.matches("/src/**/x", "/src/a/b/x", path: true))
        XCTAssertTrue(Glob.matches("~/code", NSHomeDirectory() + "/code/boo", path: true))
        XCTAssertFalse(Glob.matches("/src", "/srcfoo", path: true))
        XCTAssertFalse(Glob.matches("/Src", "/src", path: true), "paths are case-sensitive")
    }

    // MARK: Templates

    func testCaptureTemplate() {
        let caps = ["all", "one", "two"]
        XCTAssertEqual(CaptureTemplate.expand("$1-$2-$9", captures: caps), "one-two-")
        XCTAssertEqual(CaptureTemplate.expand("$$1 $x $", captures: caps), "$1 $x $")
        XCTAssertEqual(CaptureTemplate.expand("$0!", captures: caps), "all!")
    }

    func testKubeContextParse() {
        let text = """
            apiVersion: v1
            contexts:
            - context:
                cluster: a
              name: staging
            current-context: "prod-eu"
            """
        XCTAssertEqual(KubeContextReader.parse(text), "prod-eu")
        XCTAssertNil(KubeContextReader.parse("current-context:\n"))
    }
}
