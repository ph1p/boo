import XCTest

@testable import Boo

final class QuickSelectTests: XCTestCase {

    private func texts(_ lines: [String]) -> [String] {
        QuickSelect.matches(in: lines).map(\.text)
    }

    func testFindsURLWithoutTrailingPunctuation() {
        XCTAssertEqual(texts(["see https://example.com/a?b=1."]), ["https://example.com/a?b=1"])
    }

    func testURLIsNotAlsoAPath() {
        let matches = QuickSelect.matches(in: ["open https://boo.dev/docs/start now"])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].column, 5)
    }

    func testFindsPathsHashesIPsAndUUIDs() {
        let found = Set(
            texts([
                "M Boo/Ghostty/View.swift ~/dev/boo",
                "commit 279ee82 from 192.168.1.20:8080",
                "id 3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            ]))
        XCTAssertTrue(found.contains("Boo/Ghostty/View.swift"))
        XCTAssertTrue(found.contains("~/dev/boo"))
        XCTAssertTrue(found.contains("279ee82"))
        XCTAssertTrue(found.contains("192.168.1.20:8080"))
        XCTAssertTrue(found.contains("3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
    }

    func testIgnoresPlainNumbersAndBareSlashes() {
        XCTAssertEqual(texts(["total 1234567 / // ..."]), [])
    }

    func testIdenticalTextSharesLabelAndBottomGetsFirst() {
        let matches = QuickSelect.matches(in: ["/tmp/a", "/tmp/b", "/tmp/a"])
        XCTAssertEqual(matches.map(\.label), ["a", "s", "a"])
        XCTAssertEqual(matches.map(\.row), [2, 1, 0])
    }

    func testColumnsCountWideCharacters() {
        let matches = QuickSelect.matches(in: ["日本 /tmp/x"])
        XCTAssertEqual(matches.first?.column, 5)
    }

    func testLabelsArePrefixFree() {
        let labels = QuickSelect.labels(count: 40)
        XCTAssertEqual(Set(labels).count, 40)
        for a in labels {
            for b in labels where a != b { XCTAssertFalse(b.hasPrefix(a)) }
        }
        XCTAssertEqual(QuickSelect.labels(count: 3), ["a", "s", "d"])
    }
}
