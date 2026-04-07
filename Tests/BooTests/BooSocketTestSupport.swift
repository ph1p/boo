import Darwin
import Foundation
import XCTest

@testable import Boo

@MainActor
class BooSocketIntegrationTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        BooSocketTestSupport.startSharedServer()
    }

    override func tearDown() {
        BooSocketTestSupport.stopSharedServer()
        super.tearDown()
    }
}

enum BooSocketTestSupport {
    @MainActor
    static func startSharedServer(
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        BooSocketServer.shared.start()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let client = try? BooSocketTestClient() {
                client.close()
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTFail("Timed out waiting for BooSocketServer to accept connections", file: file, line: line)
    }

    @MainActor
    static func stopSharedServer() {
        BooSocketServer.shared.stop()
    }

    @MainActor
    static func waitUntil(
        timeout: TimeInterval = 1.0,
        pollInterval: TimeInterval = 0.01,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition", file: file, line: line)
    }
}

func withBooSocketClient<T>(_ body: (BooSocketTestClient) throws -> T) throws -> T {
    let client = try BooSocketTestClient()
    defer { client.close() }
    return try body(client)
}

func socketStringSet(_ value: Any?) -> Set<String> {
    Set(value as? [String] ?? [])
}

final class BooSocketTestClient {
    enum ClientError: Swift.Error {
        case connectFailed(Int32)
        case writeFailed(Int32)
        case readFailed(Int32)
        case invalidJSON
        case messageTooLarge
    }

    let fd: Int32
    private var buffer = Data()
    private var isClosed = false

    init(path: String = BooSocketServer.shared.socketPath) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strlcpy(dest, ptr, 104)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            Darwin.close(fd)
            throw ClientError.connectFailed(error)
        }

        self.fd = fd
        configureSocket()
    }

    deinit {
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }

    func send(command: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: command)
        try writeLine(data)
    }

    func send(rawJSON: String) throws {
        try writeLine(Data(rawJSON.utf8))
    }

    func roundTrip(command: [String: Any], timeout: TimeInterval = 1.0) throws -> [String: Any] {
        try send(command: command)
        return try readRequiredJSONObject(timeout: timeout)
    }

    func roundTrip(rawJSON: String, timeout: TimeInterval = 1.0) throws -> [String: Any] {
        try send(rawJSON: rawJSON)
        return try readRequiredJSONObject(timeout: timeout)
    }

    func readJSONObject(timeout: TimeInterval = 1.0) throws -> [String: Any]? {
        guard let line = try readLine(timeout: timeout) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ClientError.invalidJSON
        }
        return json
    }

    private func readRequiredJSONObject(timeout: TimeInterval) throws -> [String: Any] {
        guard let response = try readJSONObject(timeout: timeout) else {
            throw ClientError.readFailed(ETIMEDOUT)
        }
        return response
    }

    private func configureSocket() {
        var flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            flags |= O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)
        }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private func writeLine(_ data: Data) throws {
        var line = data
        line.append(UInt8(ascii: "\n"))

        try line.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0

            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw ClientError.writeFailed(EPIPE)
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForIO(events: Int16(POLLOUT), timeout: 1.0)
                    continue
                }
                throw ClientError.writeFailed(errno)
            }
        }
    }

    private func readLine(timeout: TimeInterval) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                return line
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return nil
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if buffer.count > 65_536 {
                    throw ClientError.messageTooLarge
                }
                continue
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try waitForIO(events: Int16(POLLIN), timeout: remaining)
                continue
            }
            throw ClientError.readFailed(errno)
        }
    }

    private func waitForIO(events: Int16, timeout: TimeInterval) throws {
        if Thread.isMainThread {
            let step = min(max(timeout, 0), 0.01)
            if step > 0 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(step))
            }
            return
        }

        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let timeoutMilliseconds = max(1, Int32(timeout * 1000))
        while true {
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 { return }
            if result == 0 { throw ClientError.readFailed(ETIMEDOUT) }
            if errno == EINTR { continue }
            throw ClientError.readFailed(errno)
        }
    }
}
