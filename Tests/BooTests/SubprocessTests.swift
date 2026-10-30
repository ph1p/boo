import XCTest

@testable import Boo

final class SubprocessTests: XCTestCase {
    func testDrainsOutputLargerThanPipeBuffer() throws {
        let result = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "yes x | head -c 300000"]))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 300_000)
    }

    func testNonZeroExitStillReportsOutput() throws {
        let result = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertNil(Subprocess.output("/bin/sh", ["-c", "exit 1"]))
    }

    func testTimeoutReturnsNil() {
        let start = Date()
        XCTAssertNil(Subprocess.run("/bin/sleep", ["5"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.5)
    }

    func testRunsInDirectoryWithEnvironment() {
        let output = Subprocess.output(
            "/bin/sh", ["-c", "pwd; echo $BOO_TEST"], in: "/tmp", environment: ["BOO_TEST": "yes"])
        XCTAssertEqual(output?.hasSuffix("tmp\nyes\n"), true)
    }
}
