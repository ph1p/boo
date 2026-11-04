import XCTest

@testable import Boo

final class EditorLanguageServerTests: XCTestCase {
    // MARK: - Framing

    func testFramingSplitsMessagesAcrossChunks() {
        var framing = LanguageServerFraming()
        let data = LanguageServerFraming.frame(#"{"id":1}"#) + LanguageServerFraming.frame(#"{"id":2}"#)
        let cut = data.count - 3
        XCTAssertEqual(framing.append(data.prefix(5)), [])
        XCTAssertEqual(framing.append(data[5..<cut]), [#"{"id":1}"#])
        XCTAssertEqual(framing.append(data[cut...]), [#"{"id":2}"#])
    }

    func testFramingCountsBytesNotCharacters() {
        var framing = LanguageServerFraming()
        let message = #"{"text":"größe ✓"}"#
        let framed = LanguageServerFraming.frame(message)
        XCTAssertTrue(String(decoding: framed, as: UTF8.self).hasPrefix("Content-Length: \(message.utf8.count)\r\n"))
        XCTAssertEqual(framing.append(framed), [message])
    }

    func testFramingReadsExtraHeadersAndSkipsUnknownOnes() {
        var framing = LanguageServerFraming()
        let body = #"{"ok":true}"#
        let input =
            "X-Junk: 1\r\n\r\n"
            + "Content-Type: application/vscode-jsonrpc\r\ncontent-length: \(body.utf8.count)\r\n\r\n\(body)"
        XCTAssertEqual(framing.append(Data(input.utf8)), [body])
    }

    // MARK: - Specs

    func testLanguagesMapToServers() {
        XCTAssertEqual(LanguageServerSpec.candidates(for: "TSX"), [.typescript])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "JavaScript"), [.typescript])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "SCSS"), [.css])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "HTML"), [.html])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "JSON"), [.json])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "Python"), [.basedpyright, .pyright, .pylsp])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "C++"), [.clangd])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "Rust"), [.rust])
        XCTAssertEqual(LanguageServerSpec.candidates(for: "Plain Text"), [])
    }

    func testLanguageIds() {
        XCTAssertEqual(LanguageServerSpec.languageId(language: "TSX", path: "/a/b.tsx"), "typescriptreact")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "JSX", path: "/a/b.jsx"), "javascriptreact")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "JSON", path: "/a/b.json"), "json")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "JSON", path: "/a/b.jsonc"), "jsonc")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "SCSS", path: "/a/b.scss"), "scss")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "C++", path: "/a/b.cc"), "cpp")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "Shell", path: "/a/b.sh"), "shellscript")
        XCTAssertEqual(LanguageServerSpec.languageId(language: "Python", path: "/a/b.py"), "python")
    }

    // MARK: - Roots

    private func makeTree(_ paths: [String]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-lsp-\(UUID().uuidString)").path
        for path in paths {
            let full = (root as NSString).appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: full, contents: Data())
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    func testRootIsNearestMarker() throws {
        let tree = try makeTree([".git/", "package.json", "app/tsconfig.json", "app/src/main.ts"])
        let root = LanguageServerSpec.root(
            for: tree + "/app/src/main.ts", markers: LanguageServerSpec.typescript.rootMarkers)
        XCTAssertEqual(root, tree + "/app")
    }

    func testRootFallsBackToGitCheckout() throws {
        let tree = try makeTree([".git/", "src/style.css"])
        let root = LanguageServerSpec.root(for: tree + "/src/style.css", markers: LanguageServerSpec.css.rootMarkers)
        XCTAssertEqual(root, tree)
    }

    func testRootFallsBackToFileDirectory() throws {
        let tree = try makeTree(["notes/a.json"])
        let root = LanguageServerSpec.root(for: tree + "/notes/a.json", markers: ["no-such-marker"])
        XCTAssertEqual(root, tree + "/notes")
    }

    func testLocateFindsExecutablesOnPath() throws {
        let tree = try makeTree(["bin/plain"])
        let tool = tree + "/bin/tool"
        FileManager.default.createFile(atPath: tool, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(BinaryScanner.path(of: "tool", in: "/nonexistent:\(tree)/bin"), tool)
        XCTAssertNil(BinaryScanner.path(of: "plain", in: tree + "/bin"))
    }
}

// MARK: - Relay

/// Two editors share one fake server (a Python script speaking LSP framing).
@MainActor
final class EditorLanguageServerRelayTests: XCTestCase {
    private static let fakeServer = #"""
        import json, sys
        out = sys.stdout.buffer
        def send(msg):
            body = json.dumps(msg).encode()
            out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            out.flush()
        inits = 0
        config = None
        while True:
            length = None
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    sys.exit(0)
                line = line.strip()
                if not line:
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1])
            msg = json.loads(sys.stdin.buffer.read(length))
            method = msg.get("method")
            if method == "initialize":
                inits += 1
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {}, "inits": inits}})
            elif method == "initialized":
                send({"jsonrpc": "2.0", "id": "cfg", "method": "workspace/configuration",
                      "params": {"items": [{}, {}]}})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
            elif method == "exit":
                sys.exit(0)
            elif method == "textDocument/didOpen":
                uri = msg["params"]["textDocument"]["uri"]
                send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                      "params": {"uri": uri, "diagnostics": []}})
            elif "id" in msg and method:
                send({"jsonrpc": "2.0", "id": msg["id"], "result": dict(msg.get("params"), config=config)})
            elif msg.get("id") == "cfg":
                config = msg.get("result")
        """#

    private var received: [String: [[String: Any]]] = [:]

    private func messages(_ name: String) -> [[String: Any]] { received[name] ?? [] }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func connect(_ server: LanguageServer, _ name: String) throws -> LanguageServerConnection {
        try XCTUnwrap(
            server.attach(uri: "file:///p/\(name).ts", languageId: "typescript") { [weak self] text in
                let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                self?.received[name, default: []].append(message ?? [:])
            })
    }

    private func send(_ connection: LanguageServerConnection, _ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0"].merging(message) { a, _ in a })
        connection.send(String(decoding: data, as: UTF8.self))
    }

    func testEditorsShareOneServer() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "needs python3")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("boo-fake-lsp-\(UUID()).py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: script) }

        let server = try XCTUnwrap(
            LanguageServer(
                executable: python, arguments: ["-I", script.path], root: NSTemporaryDirectory(),
                environment: ProcessInfo.processInfo.environment))
        let a = try connect(server, "a")
        let b = try connect(server, "b")

        // The server is initialized once; both editors get the result under their own ids.
        try send(a, ["id": 1, "method": "initialize", "params": [:]])
        try send(b, ["id": 7, "method": "initialize", "params": [:]])
        waitUntil { messages("a").count == 1 && messages("b").count == 1 }
        XCTAssertEqual(messages("a")[0]["id"] as? Int, 1)
        XCTAssertEqual(messages("b")[0]["id"] as? Int, 7)
        let inits = { (name: String) in (self.messages(name)[0]["result"] as? [String: Any])?["inits"] as? Int }
        XCTAssertEqual(inits("a"), 1)
        XCTAssertEqual(inits("b"), 1)

        // `initialized` goes out once; the server's workspace/configuration request
        // after it is answered by the relay, not forwarded to an editor.
        try send(a, ["method": "initialized", "params": [:]])
        try send(b, ["method": "initialized", "params": [:]])

        // Equal request ids from both editors don't collide.
        try send(a, ["id": 2, "method": "test/echo", "params": ["from": "a"]])
        waitUntil { messages("a").count == 2 }
        try send(b, ["id": 2, "method": "test/echo", "params": ["from": "b"]])
        waitUntil { messages("b").count == 2 }
        let result = { (name: String) in self.messages(name)[1]["result"] as? [String: Any] }
        XCTAssertEqual(messages("a")[1]["id"] as? Int, 2)
        XCTAssertEqual(messages("b")[1]["id"] as? Int, 2)
        XCTAssertEqual(result("a")?["from"] as? String, "a")
        XCTAssertEqual(result("b")?["from"] as? String, "b")
        XCTAssertEqual((result("b")?["config"] as? [Any])?.count, 2)

        // Diagnostics reach only the editor that opened the document.
        try send(b, ["method": "textDocument/didOpen", "params": ["textDocument": ["uri": "file:///p/b.ts"]]])
        waitUntil { messages("b").count == 3 }
        XCTAssertEqual(messages("b")[2]["method"] as? String, "textDocument/publishDiagnostics")
        XCTAssertEqual(messages("a").count, 2)

        // Closing the last editor shuts the server down.
        a.close()
        XCTAssertTrue(b.isAlive)
        b.close()
        let process = server
        waitUntil { !process.isProcessRunning }
    }

    func testServerExitIsReported() throws {
        let server = try XCTUnwrap(
            LanguageServer(
                executable: "/bin/sh", arguments: ["-c", "read line; exit 1"], root: NSTemporaryDirectory(),
                environment: ProcessInfo.processInfo.environment))
        let connection = try connect(server, "a")
        var exited = false
        connection.onExit = { exited = true }
        try send(connection, ["id": 1, "method": "initialize", "params": [:]])
        waitUntil { exited }
        XCTAssertFalse(connection.isAlive)
    }
}
