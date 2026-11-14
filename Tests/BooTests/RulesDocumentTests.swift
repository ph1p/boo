import XCTest

@testable import Boo

final class RulesDocumentTests: XCTestCase {
    private let source = """
        {
          "version": 2,
          "rules": [
            {"id": "typer", "when": {"output": "ready", "future": "x"}, "then": [{"sendText": "go\\n"}], "note": "keep"},
            {"id": "prod", "when": {"host": "*.prod"}, "then": {"profile": "Production", "extra": 1}},
            "stray"
          ]
        }
        """

    private func rules(_ text: String) throws -> [Rule] {
        try RuleSet.parse(Data(text.utf8)).set.rules
    }

    func testRoundTripKeepsUnknownKeysAndRootShape() throws {
        let doc = try XCTUnwrap(RulesDocument(text: source))
        let out = try XCTUnwrap(RulesDocument(text: doc.text()))
        XCTAssertEqual(out.items.count, 3)
        XCTAssertEqual(out.items[2] as? String, "stray")
        XCTAssertEqual(out.rule(at: 0)?["note"] as? String, "keep")
        XCTAssertEqual((out.rule(at: 0)?["when"] as? [String: Any])?["future"] as? String, "x")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(doc.text().utf8)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 2)

        let bare = try XCTUnwrap(
            RulesDocument(text: #"[{"id": "a", "when": {"cwd": "~/x"}, "then": {"profile": "P"}}]"#))
        XCTAssertTrue(bare.text().hasPrefix("["))
        XCTAssertNil(RulesDocument(text: "{ nope"))
        XCTAssertNil(RulesDocument(text: #"{"rules": 3}"#))
        XCTAssertEqual(RulesDocument(text: "")?.text(), "{\n  \"rules\": []\n}\n")
    }

    func testWriterPutsKnownKeysFirst() throws {
        let doc = try XCTUnwrap(
            RulesDocument(
                text:
                    #"[{"then": {"profile": "P"}, "altScreen": false, "zeta": 1, "when": {"cwd": "~/a/b"}, "id": "a"}]"#
            ))
        let text = doc.text()
        let order = ["\"id\"", "\"when\"", "\"then\"", "\"altScreen\"", "\"zeta\""].map {
            text.range(of: $0)?.lowerBound
        }
        XCTAssertEqual(order.compactMap { $0 }.count, 5)
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
        XCTAssertTrue(text.contains("\"~/a/b\""), "slashes are not escaped")
    }

    func testEditingOneRuleKeepsTheOthersFingerprint() throws {
        var doc = try XCTUnwrap(RulesDocument(text: source))
        let before = try rules(source)
        var draft = RuleDraft(try XCTUnwrap(doc.rule(at: 1)))
        draft.conditions["host"] = "*.staging"
        draft.conditions["gitBranch"] = "main"
        doc.replace(at: 1, with: draft.applied(to: try XCTUnwrap(doc.rule(at: 1))))
        doc.move(at: 1, by: -1)

        let after = try rules(doc.text())
        XCTAssertEqual(after.map(\.id), ["prod", "typer"])
        XCTAssertEqual(after[1].fingerprint, before[0].fingerprint)
        XCTAssertNotEqual(after[0].fingerprint, before[1].fingerprint)
        XCTAssertEqual(after[0].when.host, "*.staging")
        XCTAssertEqual(after[0].when.gitBranch, "main")
        XCTAssertEqual((doc.rule(at: 0)?["then"] as? [String: Any])?["extra"] as? Int, 1)
    }

    func testDraftRoundTripLeavesARuleAsWritten() throws {
        let doc = try XCTUnwrap(
            RulesDocument(
                text: """
                    [{"id": "a", "when": {"output": "x"}, "then": {"notify": {"body": "b"}}, "cooldown": 2.5},
                     {"id": "b", "when": {"output": "x"}, "then": [{"notify": "n"}, {"markTab": {}}, {"beep": 1}]},
                     {"when": {"cwd": "~/x"}, "then": {"profile": "P"}, "enabled": true}]
                    """))
        for index in 0..<3 {
            let rule = try XCTUnwrap(doc.rule(at: index))
            let draft = RuleDraft(rule)
            XCTAssertEqual(draft, RuleDraft(rule))
            if index != 0 {
                XCTAssertTrue((draft.applied(to: rule) as NSDictionary).isEqual(to: rule), "rule \(index)")
            }
        }
        // A single action object stays one, and the unknown action is carried.
        let single = RuleDraft(try XCTUnwrap(doc.rule(at: 0)))
        XCTAssertEqual(single.cooldown, "2.5")
        XCTAssertNotNil(single.applied(to: try XCTUnwrap(doc.rule(at: 0)))["then"] as? [String: Any])
        let mixed = RuleDraft(try XCTUnwrap(doc.rule(at: 1)))
        XCTAssertEqual(mixed.actions.map(\.kind), [.notify, .markTab, nil])
    }

    func testDraftBuildsANewRule() throws {
        var draft = RuleDraft()
        draft.id = " tests "
        draft.conditions["output"] = "(\\d+) failed"
        draft.kind = .actions
        var notify = RuleDraft.Action(kind: .notify)
        notify.title = "Tests"
        notify.text = "$1 failing"
        draft.actions = [notify, RuleDraft.Action(kind: .markTab)]
        draft.cooldown = "10"
        draft.altScreen = true
        XCTAssertNil(draft.problem)

        let rule = draft.applied(to: [:])
        XCTAssertNil(rule["enabled"], "defaults are not written into a new rule")
        XCTAssertNil(RuleDraft.parseProblem(in: rule))
        let parsed = try XCTUnwrap(try RuleSet.parse(JSONSerialization.data(withJSONObject: [rule])).set.rules.first)
        XCTAssertEqual(parsed.id, "tests")
        XCTAssertEqual(parsed.cooldown, 10)
        XCTAssertTrue(parsed.altScreen)
        XCTAssertEqual(parsed.then, .actions([.notify(title: "Tests", body: "$1 failing"), .markTab]))

        draft.cooldown = "soon"
        XCTAssertNotNil(draft.problem)
        var empty = RuleDraft()
        empty.profile = "P"
        XCTAssertNotNil(RuleDraft.parseProblem(in: empty.applied(to: [:])), "a rule needs a condition")
        XCTAssertEqual(RuleDraft.summary(of: rule), "output (\\d+) failed → notify, markTab")
    }

    func testSetEnabledAndRemove() throws {
        var doc = try XCTUnwrap(RulesDocument(text: source))
        doc.setEnabled(false, at: 1)
        doc.remove(at: 2)
        let after = try rules(doc.text())
        XCTAssertEqual(after.map(\.enabled), [true, false])
        XCTAssertEqual(doc.ids(except: 0), ["prod"])
    }
}
