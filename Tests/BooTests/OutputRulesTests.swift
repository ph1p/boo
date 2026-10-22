import XCTest

@testable import Boo

final class OutputLineSplitterTests: XCTestCase {
    private func lines(_ chunks: [String], splitter: inout OutputLineSplitter) -> [String] {
        var events: [OutputLineSplitter.Event] = []
        for c in chunks { splitter.feed(Array(c.utf8), into: &events) }
        return events.map {
            if case .line(let s, _) = $0 { return s }
            return ""
        }
    }

    func testSplitsAcrossChunksAndStripsEscapes() {
        var s = OutputLineSplitter()
        XCTAssertEqual(
            lines(["\u{1B}[31merr", "or\u{1B}[0m: x\r\n", "next\n"], splitter: &s), ["error: x", "next"])
    }

    func testCarriageReturnOverwrites() {
        var s = OutputLineSplitter()
        XCTAssertEqual(lines(["10%\r50%\r100% done\n"], splitter: &s), ["100% done"])
    }

    func testBackspaceAndTab() {
        var s = OutputLineSplitter()
        XCTAssertEqual(lines(["abx\u{08}c\td\n"], splitter: &s), ["abc d"])
    }

    func testOSCIsSkipped() {
        var s = OutputLineSplitter()
        XCTAssertEqual(
            lines(["\u{1B}]0;title\u{07}hi\n", "\u{1B}]7;file://x\u{1B}\\there\n"], splitter: &s), ["hi", "there"])
    }

    func testAltScreenTracked() {
        var s = OutputLineSplitter()
        var events: [OutputLineSplitter.Event] = []
        s.feed(Array("\u{1B}[?1049hfoo\n\u{1B}[?1049lbar\n".utf8), into: &events)
        XCTAssertEqual(events, [.line("foo", altScreen: true), .line("bar", altScreen: false)])
    }

    func testPartialLine() {
        var s = OutputLineSplitter()
        var events: [OutputLineSplitter.Event] = []
        s.feed(Array("Continue? [y/N] ".utf8), into: &events)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(s.partialLine, "Continue? [y/N] ")
    }

    func testLongLinesAreCapped() {
        var s = OutputLineSplitter()
        let out = lines([String(repeating: "a", count: 10_000) + "\n"], splitter: &s)
        XCTAssertEqual(out.first?.count, OutputLineSplitter.maxLineBytes)
    }
}

final class OutputRuleMatcherTests: XCTestCase {
    private func rule(_ id: String, _ regex: String, host: String? = nil, altScreen: Bool = false) -> Rule {
        Rule(
            id: id,
            when: RuleCondition(host: host, cwd: nil, container: nil, kubeContext: nil, process: nil, output: regex),
            then: .actions([.markTab]), cooldown: nil, altScreen: altScreen, enabled: true, fingerprint: id)
    }

    private func feed(_ matcher: OutputRuleMatcher, _ text: String) {
        Array(text.utf8).withUnsafeBufferPointer { matcher.tapOutput($0) }
    }

    @MainActor
    func testMatchesWithCaptures() {
        var got: [OutputMatch] = []
        let done = expectation(description: "match")
        let m = OutputRuleMatcher(rules: [rule("t", #"(\d+) failed"#)], context: .empty) { match in
            got.append(match)
            done.fulfill()
        }
        feed(m, "ok\n3 failed\n")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(got.first?.captures.prefix(2), ["3 failed", "3"])
        XCTAssertEqual(got.first?.line, "3 failed")
    }

    @MainActor
    func testContextConditionGatesOutputRules() {
        let none = expectation(description: "no match")
        none.isInverted = true
        let m = OutputRuleMatcher(rules: [rule("t", "x", host: "prod")], context: .empty) { _ in none.fulfill() }
        feed(m, "x\n")
        m.waitUntilIdle()
        wait(for: [none], timeout: 0.3)
    }

    @MainActor
    func testAltScreenSkippedUnlessAllowed() {
        var ids: [String] = []
        let done = expectation(description: "match")
        let m = OutputRuleMatcher(rules: [rule("a", "x"), rule("b", "x", altScreen: true)], context: .empty) {
            ids.append($0.ruleID)
            done.fulfill()
        }
        feed(m, "\u{1B}[?1049hx\n")
        wait(for: [done], timeout: 2)
        m.waitUntilIdle()
        XCTAssertEqual(ids, ["b"])
    }

    @MainActor
    func testPartialPromptFiresOnceAfterQuiet() {
        var count = 0
        let done = expectation(description: "prompt")
        let m = OutputRuleMatcher(rules: [rule("p", #"\[y/N\]"#)], context: .empty) { _ in
            count += 1
            done.fulfill()
        }
        feed(m, "Proceed? [y/N] ")
        wait(for: [done], timeout: 2)
        // Finishing the same line must not fire again.
        feed(m, "y\n")
        m.waitUntilIdle()
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertEqual(count, 1)
    }

    func testOverflowDropsBytes() {
        let m = OutputRuleMatcher(rules: [rule("t", "never")], context: .empty) { _ in }
        // Hold the queue so nothing drains while we overflow.
        let chunk = [UInt8](repeating: 0x61, count: OutputRuleMatcher.queueLimit)
        chunk.withUnsafeBufferPointer { m.tapOutput($0) }
        chunk.withUnsafeBufferPointer { m.tapOutput($0) }
        m.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(m.droppedBytes, 0)
    }
}
