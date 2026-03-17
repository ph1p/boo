import XCTest
@testable import Exterm

final class PTYProcessTests: XCTestCase {

    func testSpawnAndIsRunning() throws {
        let pty = PTYProcess()
        try pty.spawn(cols: 80, rows: 24, workingDirectory: "/tmp")
        XCTAssertTrue(pty.isRunning)
        XCTAssertGreaterThan(pty.pid, 0)
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        pty.terminate()
    }

    func testTerminate() throws {
        let pty = PTYProcess()
        try pty.spawn(cols: 80, rows: 24, workingDirectory: "/tmp")
        pty.terminate()
        XCTAssertFalse(pty.isRunning)
        XCTAssertEqual(pty.masterFD, -1)
    }

    func testOnExitedCalledWhenProcessExits() throws {
        let pty = PTYProcess()
        try pty.spawn(cols: 80, rows: 24, shell: "/bin/sh", workingDirectory: "/tmp")

        var exitCalled = false
        pty.onExited = {
            exitCalled = true
        }

        // Kill the child process to trigger exit
        kill(pty.pid, SIGTERM)

        // Pump the run loop so the main-thread DispatchQueue.main.async can fire
        let deadline = Date().addingTimeInterval(5.0)
        while !exitCalled && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(exitCalled, "onExited should be called when shell process exits")
        XCTAssertFalse(pty.isRunning)
    }

    func testWriteAndRead() throws {
        let pty = PTYProcess()
        try pty.spawn(cols: 80, rows: 24, shell: "/bin/sh", workingDirectory: "/tmp")

        pty.write(Data("echo hello\n".utf8))

        Thread.sleep(forTimeInterval: 0.5)
        let data = pty.read(maxBytes: 4096)
        XCTAssertNotNil(data)
        if let data = data {
            XCTAssertGreaterThan(data.count, 0)
        }
        pty.terminate()
    }

    func testSetSize() throws {
        let pty = PTYProcess()
        try pty.spawn(cols: 80, rows: 24, workingDirectory: "/tmp")
        pty.setSize(cols: 120, rows: 40)
        pty.terminate()
    }

    func testOnExitedCallbackWiring() {
        var called = false
        let pty = PTYProcess()
        pty.onExited = { called = true }
        pty.onExited?()
        XCTAssertTrue(called)
    }

    func testOnExitedNilByDefault() {
        let pty = PTYProcess()
        XCTAssertNil(pty.onExited)
    }
}
