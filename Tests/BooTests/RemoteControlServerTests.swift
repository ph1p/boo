import XCTest

@testable import Boo

/// Live HTTP tests for the Remote Control server: lifecycle, auth,
/// command whitelist, and the embedded web UI resource.
final class RemoteControlServerTests: XCTestCase {

    private let port: UInt16 = 48899
    private var base: String { "http://127.0.0.1:\(port)" }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(RemoteControlServer.shared.start(port: port))
    }

    override func tearDown() {
        RemoteControlServer.shared.onCommand = nil
        RemoteControlServer.shared.stop()
        super.tearDown()
    }

    private func request(
        path: String, method: String = "GET", body: [String: Any]? = nil, token: String? = nil
    ) throws -> (status: Int, body: Data) {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.timeoutInterval = 5
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let expectation = expectation(description: "response")
        nonisolated(unsafe) var result: (Int, Data) = (0, Data())
        let task = URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, data ?? Data())
            }
            expectation.fulfill()
        }
        task.resume()
        wait(for: [expectation], timeout: 10)
        return result
    }

    // MARK: - Lifecycle

    func testStartStop() {
        XCTAssertTrue(RemoteControlServer.shared.isRunning)
        XCTAssertFalse(RemoteControlServer.shared.token.isEmpty)
        RemoteControlServer.shared.stop()
        XCTAssertFalse(RemoteControlServer.shared.isRunning)
    }

    func testTokenRegeneratedOnRestart() {
        let first = RemoteControlServer.shared.token
        RemoteControlServer.shared.stop()
        XCTAssertTrue(RemoteControlServer.shared.start(port: port))
        XCTAssertNotEqual(first, RemoteControlServer.shared.token)
    }

    func testAccessURLContainsToken() {
        let url = RemoteControlServer.shared.accessURL
        XCTAssertTrue(url.hasPrefix("http://"))
        XCTAssertTrue(url.contains(":\(port)/#\(RemoteControlServer.shared.token)"))
    }

    // MARK: - Web UI

    func testServesIndexPage() throws {
        let (status, body) = try request(path: "/")
        XCTAssertEqual(status, 200)
        let html = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("Boo Remote Control"))
    }

    func testServesWasmModule() throws {
        let (status, body) = try request(path: "/ghostty-vt.wasm")
        XCTAssertEqual(status, 200)
        // WebAssembly magic number: \0asm
        XCTAssertTrue(body.starts(with: [0x00, 0x61, 0x73, 0x6D]))
    }

    func testUnknownPathIs404() throws {
        let (status, _) = try request(path: "/nope")
        XCTAssertEqual(status, 404)
    }

    // MARK: - Auth

    func testAPIRejectsMissingToken() throws {
        let (status, _) = try request(path: "/api/cmd", method: "POST", body: ["cmd": "get_state"])
        XCTAssertEqual(status, 401)
    }

    func testAPIRejectsWrongToken() throws {
        let (status, _) = try request(
            path: "/api/cmd", method: "POST", body: ["cmd": "get_state"], token: "wrong")
        XCTAssertEqual(status, 401)
    }

    // MARK: - Commands

    func testAllowedCommandRoutedToHandler() throws {
        RemoteControlServer.shared.onCommand = { cmd, _, reply in
            reply(["ok": true, "echo": cmd])
        }
        let (status, body) = try request(
            path: "/api/cmd", method: "POST", body: ["cmd": "get_state"],
            token: RemoteControlServer.shared.token)
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["echo"] as? String, "get_state")
    }

    func testDisallowedCommandIs403() throws {
        RemoteControlServer.shared.onCommand = { _, _, reply in reply(["ok": true]) }
        let (status, _) = try request(
            path: "/api/cmd", method: "POST", body: ["cmd": "set_theme"],
            token: RemoteControlServer.shared.token)
        XCTAssertEqual(status, 403)
    }

    func testInvalidJSONIs400() throws {
        var req = URLRequest(url: URL(string: base + "/api/cmd")!)
        req.httpMethod = "POST"
        req.httpBody = Data("not json".utf8)
        req.setValue(
            "Bearer \(RemoteControlServer.shared.token)", forHTTPHeaderField: "Authorization")
        let expectation = expectation(description: "response")
        nonisolated(unsafe) var status = 0
        URLSession.shared.dataTask(with: req) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(status, 400)
    }
}
