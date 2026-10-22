import Darwin
import XCTest

@testable import Boo

final class PaneServersTests: XCTestCase {
    /// Opens a real listening socket in this process and checks libproc reports it.
    func testListeningTCPPortsFindsOwnListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0  // kernel picks a free port
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        XCTAssertTrue(PaneServers.listeningTCPPorts(pid: getpid()).contains(port))

        let found = PaneServers.scan([.init(pid: getpid(), location: "tests")])
        let server = try XCTUnwrap(found.first { $0.port == port })
        XCTAssertEqual(server.pid, getpid())
        XCTAssertEqual(server.location, "tests")
        XCTAssertEqual(server.url.absoluteString, "http://localhost:\(port)")
    }

    func testDescendantsStartsWithRootAndSkipsDeadPIDs() {
        XCTAssertEqual(ProcessTree.descendants(of: getpid(), limit: PaneServers.maxDescendants).first, getpid())
        XCTAssertTrue(PaneServers.listeningTCPPorts(pid: 999_999).isEmpty)
    }
}

final class PortTrackerTests: XCTestCase {
    private func server(_ port: UInt16, pid: pid_t = 1) -> PaneServer {
        PaneServer(port: port, pid: pid, processName: "node", location: "web")
    }

    func testFirstScanSeedsSilentlyThenReportsNew() {
        var tracker = PortTracker()
        let ws = UUID()
        XCTAssertEqual(tracker.update(workspace: ws, servers: [server(3000)]), [])
        XCTAssertEqual(tracker.update(workspace: ws, servers: [server(3000)]), [])
        XCTAssertEqual(tracker.update(workspace: ws, servers: [server(3000), server(5173)]), [server(5173)])
        // Same port, new process: a restart is news again.
        XCTAssertEqual(tracker.update(workspace: ws, servers: [server(3000, pid: 9)]), [server(3000, pid: 9)])
    }

    func testWorkspacesAreSeparateAndForgettable() {
        var tracker = PortTracker()
        let a = UUID()
        let b = UUID()
        _ = tracker.update(workspace: a, servers: [])
        XCTAssertEqual(tracker.update(workspace: b, servers: [server(8000)]), [])
        XCTAssertEqual(tracker.update(workspace: a, servers: [server(8000)]), [server(8000)])
        tracker.forget(workspace: a)
        XCTAssertEqual(tracker.update(workspace: a, servers: [server(9000)]), [])
    }

    @MainActor func testLabel() {
        XCTAssertEqual(PortMonitor.label(for: [server(3000), server(5173)]), "⇄ 3000 · 5173")
        XCTAssertEqual(PortMonitor.label(for: (1...4).map { server(UInt16(8000 + $0)) }), "⇄ 4 ports")
    }
}
