import XCTest

@testable import Boo

final class BooMCPDispatcherTests: XCTestCase {
    /// Collects written lines as parsed JSON, thread-safe.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        func append(_ data: Data) {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            lock.withLock { lines.append(object) }
        }
        var ids: [String] { lock.withLock { lines.map { "\($0["id"] ?? "nil")" } } }
        var all: [[String: Any]] { lock.withLock { lines } }
    }

    private func call(_ id: Int, _ name: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)"}}"#
    }

    func testSlowCallDoesNotBlockLaterMessages() {
        let output = Output()
        let release = DispatchSemaphore(value: 0)
        let dispatcher = BooMCPDispatcher(
            handle: { message, _ in
                let name = (message["params"] as? [String: Any])?["name"] as? String
                if name == "slow" { release.wait() }
                return ["jsonrpc": "2.0", "id": message["id"] ?? NSNull(), "result": [:]]
            },
            write: output.append)
        dispatcher.receive(call(1, "slow"))
        dispatcher.receive(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        dispatcher.receive(call(3, "fast"))
        let deadline = Date().addingTimeInterval(5)
        while output.ids.count < 2, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(Set(output.ids), ["2", "3"])
        release.signal()
        dispatcher.waitForCalls()
        XCTAssertEqual(output.ids.last, "1")
    }

    func testCancelledCallAbortsAndSendsNoReply() {
        let output = Output()
        let started = DispatchSemaphore(value: 0)
        let dispatcher = BooMCPDispatcher(
            handle: { message, cancel in
                started.signal()
                while !cancel.isCancelled { usleep(5_000) }
                return ["jsonrpc": "2.0", "id": message["id"] ?? NSNull(), "result": [:]]
            },
            write: output.append)
        dispatcher.receive(call(7, "wait_for_events"))
        started.wait()
        dispatcher.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#)
        dispatcher.waitForCalls()
        XCTAssertTrue(output.all.isEmpty)
    }

    func testCancelShutsDownTheSocketRead() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let cancel = BooMCPCancel()
        XCTAssertTrue(cancel.attach(fds[0]))
        let done = expectation(description: "read returns")
        let fd = fds[0]
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            _ = read(fd, &byte, 1)
            done.fulfill()
        }
        usleep(50_000)
        cancel.cancel()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(cancel.attach(fds[0]), "a cancelled request must not start a new read")
    }

    func testParseErrorAndBlankLines() {
        let output = Output()
        let dispatcher = BooMCPDispatcher(handle: { _, _ in nil }, write: output.append)
        dispatcher.receive("   ")
        dispatcher.receive("{not json")
        let error = output.all.first?["error"] as? [String: Any]
        XCTAssertEqual(output.all.count, 1)
        XCTAssertEqual(error?["code"] as? Int, -32700)
    }
}
