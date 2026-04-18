import Darwin
import XCTest

@testable import Boo

final class BooSocketWriteTests: XCTestCase {
    func testSendJSONReturnsFalseWhenPeerClosed() {
        let (writer, reader) = makeSocketPair()
        defer { close(writer) }
        close(reader)

        configureWriterSocket(writer)

        XCTAssertFalse(BooSocketServer.shared.sendJSON(fd: writer, dict: ["ok": true]))
    }

    func testSendJSONWritesEntirePayloadToNonBlockingSocket() throws {
        let (writer, reader) = makeSocketPair()
        defer {
            close(writer)
            close(reader)
        }

        configureWriterSocket(writer, sendBufferSize: 1024)

        let payload = String(repeating: "x", count: 200_000)
        let receivedLine = expectation(description: "received full JSON line")
        nonisolated(unsafe) var received = Data()

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 {
                    received.append(contentsOf: buffer[0..<count])
                    if received.last == UInt8(ascii: "\n") {
                        receivedLine.fulfill()
                        return
                    }
                    continue
                }
                if count == 0 {
                    return
                }
                if errno == EINTR {
                    continue
                }
                return
            }
        }

        XCTAssertTrue(BooSocketServer.shared.sendJSON(fd: writer, dict: ["ok": true, "text": payload]))

        wait(for: [receivedLine], timeout: 2.0)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(received.dropLast())) as? [String: Any]
        )
        XCTAssertEqual(json["text"] as? String, payload)
    }

    func testBroadcastEventRemovesDisconnectedSubscriber() {
        let (writer, reader) = makeSocketPair()
        defer { close(writer) }
        close(reader)

        configureWriterSocket(writer)

        let server = BooSocketServer.shared
        server.queue.sync {
            server.subscriptions[writer] = Set(["cwd_changed"])
            server.broadcastEvent(name: "cwd_changed", data: ["path": "/tmp"])
        }

        let remaining = server.queue.sync { server.subscriptions[writer] }
        XCTAssertNil(remaining)
    }

    private func makeSocketPair() -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    private func configureWriterSocket(_ fd: Int32, sendBufferSize: Int32 = 4096) {
        var flags = fcntl(fd, F_GETFL)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var bufferSize = sendBufferSize
        _ = withUnsafePointer(to: &bufferSize) {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }
}
