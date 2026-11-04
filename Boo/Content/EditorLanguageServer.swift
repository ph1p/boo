import Foundation

// Language servers for editor tabs. The editor page runs @codemirror/lsp-client;
// this side starts the server (only when its binary is on the user's PATH) and
// relays JSON-RPC between the server's stdio and the page.
//
// One server runs per project root and server binary, shared by every editor
// tab in that project, and stops when the last of them closes. Each page runs
// its own client, so the relay makes several clients look like one to the
// server: it initializes the server once and answers later `initialize`
// requests from the cached result, renumbers request ids, routes responses
// and per-document notifications back to the page they belong to, and
// answers the server's own requests itself.

// MARK: - Server specs

/// A language server Boo can start, and the languages it serves.
struct LanguageServerSpec: Hashable, Sendable {
    let executable: String
    let arguments: [String]
    /// Files whose directory is a project root, checked nearest first.
    let rootMarkers: [String]

    private init(_ executable: String, _ arguments: [String] = [], markers: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.rootMarkers = markers
    }

    private static let node = ["package.json"]
    private static let python = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"]
    private static let gradle = ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"]

    static let typescript = LanguageServerSpec(
        "typescript-language-server", ["--stdio"], markers: ["tsconfig.json", "jsconfig.json"] + node)
    static let css = LanguageServerSpec("vscode-css-language-server", ["--stdio"], markers: node)
    static let html = LanguageServerSpec("vscode-html-language-server", ["--stdio"], markers: node)
    static let json = LanguageServerSpec("vscode-json-language-server", ["--stdio"], markers: node)
    static let basedpyright = LanguageServerSpec(
        "basedpyright-langserver", ["--stdio"], markers: ["pyrightconfig.json"] + python)
    static let pyright = LanguageServerSpec(
        "pyright-langserver", ["--stdio"], markers: ["pyrightconfig.json"] + python)
    static let pylsp = LanguageServerSpec("pylsp", markers: python)
    static let rust = LanguageServerSpec("rust-analyzer", markers: ["Cargo.toml"])
    static let go = LanguageServerSpec("gopls", markers: ["go.work", "go.mod"])
    static let clangd = LanguageServerSpec(
        "clangd", markers: ["compile_commands.json", "compile_flags.txt", ".clangd", "CMakeLists.txt", "Makefile"])
    static let swift = LanguageServerSpec("sourcekit-lsp", markers: ["Package.swift", "buildServer.json"])
    static let bash = LanguageServerSpec("bash-language-server", ["start"])
    static let yaml = LanguageServerSpec("yaml-language-server", ["--stdio"])
    static let lua = LanguageServerSpec("lua-language-server", markers: [".luarc.json", ".luarc.jsonc"])
    static let rubyLsp = LanguageServerSpec("ruby-lsp", markers: ["Gemfile"])
    static let solargraph = LanguageServerSpec("solargraph", ["stdio"], markers: ["Gemfile"])
    static let intelephense = LanguageServerSpec("intelephense", ["--stdio"], markers: ["composer.json"])
    static let phpactor = LanguageServerSpec("phpactor", ["language-server"], markers: ["composer.json"])
    static let java = LanguageServerSpec("jdtls", markers: ["pom.xml"] + gradle)
    static let kotlin = LanguageServerSpec("kotlin-language-server", markers: gradle + ["pom.xml"])
    static let csharp = LanguageServerSpec("csharp-ls", markers: ["global.json", "Directory.Build.props"])
    static let dart = LanguageServerSpec("dart", ["language-server"], markers: ["pubspec.yaml"])
    static let haskell = LanguageServerSpec(
        "haskell-language-server-wrapper", ["--lsp"], markers: ["stack.yaml", "cabal.project", "hie.yaml"])
    static let docker = LanguageServerSpec("docker-langserver", ["--stdio"])
    static let toml = LanguageServerSpec("taplo", ["lsp", "stdio"])
    static let markdown = LanguageServerSpec("marksman", ["server"])

    /// The servers for an editor language name (see languages.ts), most
    /// preferred first. The first one installed runs.
    static func candidates(for language: String) -> [LanguageServerSpec] {
        switch language {
        case "TypeScript", "TSX", "JavaScript", "JSX": return [.typescript]
        case "CSS", "SCSS", "LESS": return [.css]
        case "HTML": return [.html]
        case "JSON": return [.json]
        case "Python": return [.basedpyright, .pyright, .pylsp]
        case "Rust": return [.rust]
        case "Go": return [.go]
        case "C", "C++", "Objective-C", "Objective-C++": return [.clangd]
        case "Swift": return [.swift]
        case "Shell": return [.bash]
        case "YAML": return [.yaml]
        case "Lua": return [.lua]
        case "Ruby": return [.rubyLsp, .solargraph]
        case "PHP": return [.intelephense, .phpactor]
        case "Java": return [.java]
        case "Kotlin": return [.kotlin]
        case "C#": return [.csharp]
        case "Dart": return [.dart]
        case "Haskell": return [.haskell]
        case "Dockerfile": return [.docker]
        case "TOML": return [.toml]
        case "Markdown": return [.markdown]
        default: return []
        }
    }

    /// The LSP language identifier for a file in `language`.
    static func languageId(language: String, path: String) -> String {
        switch language {
        case "TypeScript": return "typescript"
        case "TSX": return "typescriptreact"
        case "JavaScript": return "javascript"
        case "JSX": return "javascriptreact"
        case "JSON":
            let ext = (path as NSString).pathExtension.lowercased()
            return ext == "json" ? "json" : "jsonc"
        case "C++": return "cpp"
        case "Objective-C": return "objective-c"
        case "Objective-C++": return "objective-cpp"
        case "C#": return "csharp"
        case "Shell": return "shellscript"
        default: return language.lowercased()
        }
    }

    /// The project root for `path`: the nearest directory holding a root marker,
    /// else the nearest git checkout, else the file's directory. Never the home
    /// directory or `/`, where a server would crawl everything.
    static func root(for path: String, markers: [String], fileManager: FileManager = .default) -> String {
        let start = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        var gitDir: String?
        var dir = start
        while dir != "/" && dir != home && !dir.isEmpty {
            let has = { (name: String) in
                fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
            }
            if markers.contains(where: has) { return dir }
            if gitDir == nil, has(".git") {
                gitDir = dir
                // Without markers nothing further up can win.
                if markers.isEmpty { break }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return gitDir ?? start
    }

    /// The login shell's environment, plus the usual install locations of
    /// node-based servers. Blocks on the login shell: call off the main thread.
    static func environment() -> [String: String] {
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/Library/pnpm",
            home + "/.bun/bin", home + "/.volta/bin", home + "/.npm-global/bin",
            home + "/.local/share/mise/shims", home + "/.asdf/shims", home + "/.nix-profile/bin",
            home + "/.cargo/bin", home + "/go/bin", home + "/.pyenv/shims", home + "/.rbenv/shims",
            home + "/.dotnet/tools", home + "/.ghcup/bin", home + "/.composer/vendor/bin"
        ]
        return LoginShellEnvironment.shared.environment(wait: true, extraPaths: extra)
    }
}

// MARK: - Framing

/// Splits a server's stdout into JSON messages (LSP's `Content-Length` framing)
/// and frames outgoing ones.
struct LanguageServerFraming {
    private var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)

    /// Adds bytes read from the server; returns the messages they complete.
    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var messages: [String] = []
        // Consume through `start`, then drop the consumed bytes once.
        var start = buffer.startIndex
        while let end = buffer.range(of: Self.separator, in: start..<buffer.endIndex) {
            let header = String(decoding: buffer[start..<end.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(header) else {
                // Not a header we understand: skip it rather than stall.
                start = end.upperBound
                continue
            }
            let bodyStart = end.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            messages.append(String(decoding: buffer[bodyStart..<bodyEnd], as: UTF8.self))
            start = bodyEnd
        }
        buffer = Data(buffer[start...])
        return messages
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func frame(_ message: String) -> Data {
        let body = Data(message.utf8)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

// MARK: - Hub

/// Starts language servers and hands editors connections to them.
@MainActor
final class LanguageServerHub {
    static let shared = LanguageServerHub()

    private var servers: [String: LanguageServer] = [:]

    /// Connects an editor showing `path` in `language` to its server. Calls
    /// `completion` with nil when no server serves the language or its binary
    /// isn't installed. `deliver` receives the server's messages for the editor.
    func connect(
        language: String,
        path: String,
        deliver: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (LanguageServerConnection?) -> Void
    ) {
        let candidates = LanguageServerSpec.candidates(for: language)
        guard !candidates.isEmpty else { return completion(nil) }
        let languageId = LanguageServerSpec.languageId(language: language, path: path)
        let uri = URL(fileURLWithPath: path).absoluteString
        DispatchQueue.global(qos: .userInitiated).async {
            let environment = LanguageServerSpec.environment()
            let found = candidates.lazy.compactMap { spec in
                BinaryScanner.path(of: spec.executable, in: environment["PATH"] ?? "").map { (spec, $0) }
            }.first
            let root = found.map { LanguageServerSpec.root(for: path, markers: $0.0.rootMarkers) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let (spec, executable) = found, let root else {
                        let names = candidates.map(\.executable).joined(separator: ", ")
                        debugLog("[LSP] \(names) not found on PATH; no language server for \(language)")
                        return completion(nil)
                    }
                    let server = self.server(spec: spec, executable: executable, root: root, environment: environment)
                    completion(server?.attach(uri: uri, languageId: languageId, deliver: deliver))
                }
            }
        }
    }

    private func server(
        spec: LanguageServerSpec, executable: String, root: String, environment: [String: String]
    ) -> LanguageServer? {
        let key = spec.executable + "\u{0}" + root
        if let server = servers[key] { return server }
        guard
            let server = LanguageServer(
                executable: executable, arguments: spec.arguments, root: root, environment: environment)
        else { return nil }
        server.onStop = { [weak self, weak server] in
            if let self, let server, self.servers[key] === server { self.servers[key] = nil }
        }
        servers[key] = server
        return server
    }
}

// MARK: - Connection

/// One editor's link to a shared server.
@MainActor
final class LanguageServerConnection {
    let uri: String
    let rootUri: String
    let languageId: String
    fileprivate let id: Int
    fileprivate weak var server: LanguageServer?
    fileprivate let deliver: @MainActor (String) -> Void
    /// Called when the server exits on its own, e.g. a broken install that
    /// quits at once. Not called after `close()`.
    var onExit: (@MainActor () -> Void)?

    fileprivate init(
        id: Int, uri: String, rootUri: String, languageId: String, server: LanguageServer,
        deliver: @escaping @MainActor (String) -> Void
    ) {
        self.id = id
        self.uri = uri
        self.rootUri = rootUri
        self.languageId = languageId
        self.server = server
        self.deliver = deliver
    }

    /// False once the server exited or the connection was closed.
    var isAlive: Bool { server?.isRunning ?? false }

    /// Sends a JSON-RPC message from the editor.
    func send(_ message: String) {
        server?.handle(message, from: self)
    }

    /// Closes the editor's documents; stops the server if it was the last editor.
    func close() {
        onExit = nil
        server?.detach(self)
        server = nil
    }
}

// MARK: - Server

/// A running language server process and the editors sharing it.
@MainActor
final class LanguageServer {
    let root: String
    var onStop: (() -> Void)?

    private let process = Process()
    private let input: FileHandle
    private let writer = DispatchQueue(label: "boo.lsp.writer")
    private var connections: [Int: LanguageServerConnection] = [:]
    private var nextConnectionId = 1
    private var nextRequestId = 1
    /// Requests sent on behalf of editors, by the id the server saw.
    private var pending: [Int: (connection: Int, id: Any)] = [:]
    private var initializeId: Int?
    private var initializeResult: [String: Any]?
    private var initializeWaiters: [(connection: Int, id: Any)] = []
    private var sentInitialized = false
    private var shutdownId: Int?
    /// The editor whose `didOpen` the server received for each document.
    private var owners: [String: Int] = [:]
    private var stopping = false

    fileprivate var isRunning: Bool { process.isRunning && !stopping }
    /// Whether the process still runs, stopping or not.
    var isProcessRunning: Bool { process.isRunning }

    init?(executable: String, arguments: [String], root: String, environment: [String: String]) {
        self.root = root
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        // Writing after the server died must fail with EPIPE, not kill Boo.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = stdin.fileHandleForWriting
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let name = (executable as NSString).lastPathComponent
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    debugLog("[LSP] \(name) exited (\(status))")
                    self?.didExit()
                }
            }
        }
        do {
            try process.run()
        } catch {
            debugLog("[LSP] Starting \(name) failed: \(error.localizedDescription)")
            return nil
        }
        debugLog("[LSP] Started \(name) in \(root)")
        Self.read(stdout.fileHandleForReading) { [weak self] message in self?.receive(message) }
        Self.drain(stderr.fileHandleForReading, name: name)
    }

    /// Reads framed messages on a background thread, handling them on the main thread in order.
    private nonisolated static func read(
        _ handle: FileHandle, onMessage: @escaping @MainActor @Sendable (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var framing = LanguageServerFraming()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                for message in framing.append(data) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onMessage(message) } }
                }
            }
        }
    }

    /// Logs the server's stderr so it never fills the pipe and blocks it.
    private nonisolated static func drain(_ handle: FileHandle, name: String) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { debugLog("[LSP] \(name): \(text)") }
            }
        }
    }

    func attach(
        uri: String, languageId: String, deliver: @escaping @MainActor (String) -> Void
    ) -> LanguageServerConnection? {
        guard isRunning else { return nil }
        let connection = LanguageServerConnection(
            id: nextConnectionId, uri: uri, rootUri: URL(fileURLWithPath: root, isDirectory: true).absoluteString,
            languageId: languageId, server: self, deliver: deliver)
        nextConnectionId += 1
        connections[connection.id] = connection
        return connection
    }

    fileprivate func detach(_ connection: LanguageServerConnection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        for (uri, owner) in owners where owner == connection.id {
            owners[uri] = nil
            write(["jsonrpc": "2.0", "method": "textDocument/didClose", "params": ["textDocument": ["uri": uri]]])
        }
        pending = pending.filter { $0.value.connection != connection.id }
        initializeWaiters.removeAll { $0.connection == connection.id }
        if connections.isEmpty { stop() }
    }

    // MARK: Editor to server

    fileprivate func handle(_ text: String, from connection: LanguageServerConnection) {
        guard connections[connection.id] != nil, var message = Self.parse(text) else { return }
        let method = message["method"] as? String
        let id = message["id"]
        switch (method, id) {
        case ("initialize"?, let id?):
            if let result = initializeResult {
                var reply = result
                reply["id"] = id
                send(reply, to: connection.id)
                return
            }
            initializeWaiters.append((connection.id, id))
            guard initializeId == nil else { return }
            let serverId = takeRequestId()
            initializeId = serverId
            message["id"] = serverId
            write(message)
        case ("initialized"?, nil):
            guard !sentInitialized else { return }
            sentInitialized = true
            write(message)
        case ("shutdown"?, let id?):
            // Other editors still use the server; it stops when the last one leaves.
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()], to: connection.id)
        case ("exit"?, _):
            return
        case ("$/cancelRequest"?, nil):
            guard let original = (message["params"] as? [String: Any])?["id"],
                let serverId = pending.first(where: {
                    $0.value.connection == connection.id && Self.sameId($0.value.id, original)
                })?.key
            else { return }
            message["params"] = ["id": serverId]
            write(message)
        case (_?, let id?):
            let serverId = takeRequestId()
            pending[serverId] = (connection.id, id)
            message["id"] = serverId
            write(message)
        case (let method?, nil):
            if let uri = Self.documentURI(message) {
                // Two tabs on one file: the server knows only the first.
                if method == "textDocument/didOpen" {
                    if let owner = owners[uri], owner != connection.id { return }
                    owners[uri] = connection.id
                } else if owners[uri] != connection.id {
                    return
                } else if method == "textDocument/didClose" {
                    owners[uri] = nil
                }
            }
            write(text)
        default:
            // Replies to server requests, which the relay answers itself.
            return
        }
    }

    // MARK: Server to editor

    private func receive(_ text: String) {
        guard let message = Self.parse(text) else { return }
        let method = message["method"] as? String
        if let method, let id = message["id"] {
            answer(method: method, id: id, params: message["params"])
            return
        }
        if method == nil, let id = (message["id"] as? NSNumber)?.intValue {
            if id == initializeId {
                initializeId = nil
                if message["result"] != nil { initializeResult = message }
                for waiter in initializeWaiters {
                    var reply = message
                    reply["id"] = waiter.id
                    send(reply, to: waiter.connection)
                }
                initializeWaiters = []
            } else if id == shutdownId {
                write(["jsonrpc": "2.0", "method": "exit"])
            } else if let request = pending.removeValue(forKey: id) {
                var reply = message
                reply["id"] = request.id
                send(reply, to: request.connection)
            }
            return
        }
        guard let method else { return }
        switch method {
        case "window/logMessage", "window/showMessage":
            if let line = (message["params"] as? [String: Any])?["message"] as? String {
                debugLog("[LSP] \(line)")
            }
        case "$/progress", "telemetry/event":
            return
        default:
            if let uri = (message["params"] as? [String: Any])?["uri"] as? String, let owner = owners[uri] {
                connections[owner]?.deliver(text)
            } else {
                for connection in connections.values { connection.deliver(text) }
            }
        }
    }

    /// Answers a request from the server. Pages can't act on them: they edit one
    /// file and have no settings for the server to read.
    private func answer(method: String, id: Any, params: Any?) {
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "workspace/configuration":
            let items = (params as? [String: Any])?["items"] as? [Any] ?? []
            reply["result"] = items.map { _ in NSNull() }
        case "workspace/workspaceFolders":
            let uri = URL(fileURLWithPath: root, isDirectory: true).absoluteString
            reply["result"] = [["uri": uri, "name": (root as NSString).lastPathComponent]]
        case "workspace/applyEdit":
            reply["result"] = ["applied": false]
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create",
            "window/showMessageRequest", "window/showDocument":
            reply["result"] = NSNull()
        default:
            reply["error"] = ["code": -32601, "message": "\(method) is not supported"]
        }
        write(reply)
    }

    // MARK: Lifecycle

    private func markStopped() {
        stopping = true
        onStop?()
        onStop = nil
    }

    private func stop() {
        guard !stopping else { return }
        markStopped()
        if sentInitialized {
            let id = takeRequestId()
            shutdownId = id
            write(["jsonrpc": "2.0", "id": id, "method": "shutdown"])
        } else {
            write(["jsonrpc": "2.0", "method": "exit"])
        }
        // Servers that ignore shutdown still go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func didExit() {
        markStopped()
        let orphans = connections.values
        connections.removeAll()
        pending.removeAll()
        for connection in orphans {
            connection.server = nil
            connection.onExit?()
            connection.onExit = nil
        }
        initializeWaiters.removeAll()
        writer.async { [input] in try? input.close() }
    }

    // MARK: Helpers

    private func takeRequestId() -> Int {
        defer { nextRequestId += 1 }
        return nextRequestId
    }

    private func send(_ message: [String: Any], to connection: Int) {
        guard let text = Self.serialize(message) else { return }
        connections[connection]?.deliver(text)
    }

    private func write(_ message: [String: Any]) {
        if let text = Self.serialize(message) { write(text) }
    }

    private func write(_ text: String) {
        let data = LanguageServerFraming.frame(text)
        writer.async { [input] in try? input.write(contentsOf: data) }
    }

    private static func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func serialize(_ message: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func documentURI(_ message: [String: Any]) -> String? {
        ((message["params"] as? [String: Any])?["textDocument"] as? [String: Any])?["uri"] as? String
    }

    private static func sameId(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) ?? false
    }
}
