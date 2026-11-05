import XCTest

@testable import Boo

final class TestFailureParserTests: XCTestCase {
    func testXCTestAndSwiftTesting() throws {
        let output = """
            Test Case '-[BooTests.ParserTests testA]' started.
            /Users/me/boo/Tests/BooTests/ParserTests.swift:12: error: -[BooTests.ParserTests testA] : XCTAssertEqual failed: ("1") is not equal to ("2")
            /Users/me/boo/Tests/BooTests/ParserTests.swift:14: error: -[BooTests.ParserTests testA] : XCTAssertTrue failed
            Test Case '-[BooTests.ParserTests testA]' failed (0.002 seconds).
            ✘ Test "Adds numbers" recorded an issue at MathTests.swift:8:5: Expectation failed: 1 == 2
            Executed 3 tests, with 2 failures (0 unexpected) in 0.010 seconds
            """
        let report = try XCTUnwrap(TestFailureParser.parse(output))
        XCTAssertEqual(report.framework, "XCTest")
        XCTAssertEqual(report.failures.count, 3)
        XCTAssertEqual(report.testCount, 2)
        XCTAssertEqual(report.summary, "2 tests failed")
        XCTAssertEqual(report.failures[0].name, "ParserTests.testA")
        XCTAssertEqual(report.failures[0].location, "/Users/me/boo/Tests/BooTests/ParserTests.swift:12")
        XCTAssertEqual(report.failures[0].message, #"XCTAssertEqual failed: ("1") is not equal to ("2")"#)
        XCTAssertEqual(report.failures[2].name, "Adds numbers")
        XCTAssertEqual(report.failures[2].location, "MathTests.swift:8")
    }

    func testJest() throws {
        let output = """
             FAIL  src/sum.test.ts
              ● math › adds numbers

                expect(received).toBe(expected) // Object.is equality

                Expected: 3
                Received: 4

                  3 | test('adds numbers', () => {
                > 4 |   expect(sum(2, 2)).toBe(3);
                    |                     ^

                  at Object.<anonymous> (src/sum.test.ts:4:21)

            Test Suites: 1 failed, 1 total
            Tests:       1 failed, 1 total
            """
        let report = try XCTUnwrap(TestFailureParser.parse(output))
        XCTAssertEqual(report.framework, "Jest")
        XCTAssertEqual(report.failures.count, 1)
        let failure = report.failures[0]
        XCTAssertEqual(failure.name, "math › adds numbers")
        XCTAssertEqual(failure.location, "src/sum.test.ts:4")
        XCTAssertTrue(failure.message.hasPrefix("expect(received).toBe(expected)"))
        XCTAssertTrue(failure.message.contains("Received: 4"))
    }

    func testVitestWithANSI() throws {
        let output = """
            \u{1B}[31m FAIL \u{1B}[39m src/sum.test.ts > math > adds numbers
            AssertionError: expected 4 to be 3 // Object.is equality

            - Expected
            + Received

            ❯ src/sum.test.ts:4:21
                  2| test('adds numbers', () => {
            ⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[1/2]⎯
             FAIL  src/other.test.ts > other
            Error: boom
            """
        let report = try XCTUnwrap(TestFailureParser.parse(output))
        XCTAssertEqual(report.framework, "Vitest")
        XCTAssertEqual(report.failures.map(\.name), ["math › adds numbers", "other"])
        XCTAssertEqual(report.failures[0].location, "src/sum.test.ts:4")
        XCTAssertEqual(
            report.failures[0].message,
            "AssertionError: expected 4 to be 3 // Object.is equality\n- Expected\n+ Received")
        XCTAssertEqual(report.failures[1].location, "src/other.test.ts")
    }

    func testPytest() throws {
        let output = """
            =================================== FAILURES ===================================
            ___________________________ TestMath.test_add ___________________________

                def test_add(self):
            >       assert add(2, 2) == 3
            E       assert 4 == 3

            tests/test_math.py:7: AssertionError
            _________________________________ test_div _________________________________
            tests/test_math.py:12: ZeroDivisionError
            =========================== short test summary info ============================
            FAILED tests/test_math.py::TestMath::test_add - assert 4 == 3
            FAILED tests/test_math.py::test_div - ZeroDivisionError: division by zero
            ========================= 2 failed, 3 passed in 0.12s ==========================
            """
        let report = try XCTUnwrap(TestFailureParser.parse(output))
        XCTAssertEqual(report.framework, "pytest")
        XCTAssertEqual(
            report.failures.map(\.name), ["tests/test_math.py::TestMath::test_add", "tests/test_math.py::test_div"])
        XCTAssertEqual(report.failures.map(\.location), ["tests/test_math.py:7", "tests/test_math.py:12"])
        XCTAssertEqual(report.failures[0].message, "assert 4 == 3")
    }

    func testCargo() throws {
        let output = """
            running 2 tests
            test tests::adds ... FAILED
            test tests::old ... FAILED

            failures:

            ---- tests::adds stdout ----
            thread 'tests::adds' panicked at src/lib.rs:10:9:
            assertion `left == right` failed
              left: 4
             right: 3
            note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace

            ---- tests::old stdout ----
            thread 'tests::old' panicked at 'boom', src/lib.rs:20:5

            failures:
                tests::adds
                tests::old

            test result: FAILED. 0 passed; 2 failed
            """
        let report = try XCTUnwrap(TestFailureParser.parse(output))
        XCTAssertEqual(report.framework, "cargo test")
        XCTAssertEqual(report.failures.map(\.name), ["tests::adds", "tests::old"])
        XCTAssertEqual(report.failures.map(\.location), ["src/lib.rs:10", "src/lib.rs:20"])
        XCTAssertEqual(report.failures[0].message, "assertion `left == right` failed\nleft: 4\nright: 3")
        XCTAssertEqual(report.failures[1].message, "boom")
    }

    func testGoTest() throws {
        let output = """
            --- FAIL: TestAdd (0.00s)
                math_test.go:9: got 4, want 3
            FAIL
            FAIL	example.com/math	0.002s
            """
        let report = try XCTUnwrap(TestFailureParser.parse(output))
        XCTAssertEqual(
            report.failures, [TestFailure(name: "TestAdd", file: "math_test.go", line: 9, message: "got 4, want 3")])
        XCTAssertEqual(report.summary, "1 test failed")
    }

    func testNoFailuresInOrdinaryErrors() {
        XCTAssertNil(TestFailureParser.parse("zsh: command not found: foo"))
        XCTAssertNil(TestFailureParser.parse("make: *** [build] Error 1\nerror: linker command failed"))
        XCTAssertNil(TestFailureParser.parse(""))
    }

    func testComposeSendsOnlyFailures() {
        let report = TestFailureReport(
            framework: "Jest",
            failures: [
                TestFailure(name: "adds", file: "src/a.test.ts", line: 4, message: "Expected: 3\nReceived: 4"),
                TestFailure(name: "subs", file: nil, line: nil, message: "")
            ])
        let text = AgentHandoff.compose(failures: report, command: "pnpm test", exitCode: 1, cwd: nil)
        XCTAssertEqual(
            text,
            """
            2 tests failed (Jest) in `pnpm test` (exit code 1):
            ```
            - adds at src/a.test.ts:4
              Expected: 3
              Received: 4
            - subs
            ```

            """)
    }
}
