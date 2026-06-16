import Foundation
import JavaScriptCore
import os.log

/// JavaScriptCore runtime for inline plugin transforms.
/// ADR-3: JSC for fast inline logic without shell overhead.
final class JSCRuntime: @unchecked Sendable {

    struct JSError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Mutable holder shared across the JS thread boundary. JSC work is serialized
    /// onto one thread and the caller only reads after `group.wait`, so access is
    /// race-free in practice.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private let logger = Logger(subsystem: "com.boo", category: "JSCRuntime")

    /// Execute a JavaScript transform function against a terminal context.
    /// - Parameters:
    ///   - source: JavaScript source code containing a function.
    ///   - functionName: Name of the function to call (default: "transform").
    ///   - context: Terminal context passed as JS object argument.
    ///   - timeout: Maximum execution time in seconds.
    /// - Returns: JSON string output from the function.
    func execute(
        source: String,
        functionName: String = "transform",
        context: TerminalContext,
        settings: [String: Any] = [:],
        timeout: TimeInterval = 1.0
    ) throws -> String {
        var dict = buildContextDict(from: context)
        if !settings.isEmpty {
            dict["settings"] = settings
        }
        // Box the dict so it crosses the thread boundary as an @unchecked Sendable
        // holder (see Box doc) instead of a bare non-Sendable dictionary.
        let ctxDict = Box(dict)

        // All JSC work runs on a dedicated thread (JSContext is thread-bound).
        // The calling thread waits with a deadline so infinite loops don't hang.
        let output = Box<String?>(nil)
        let thrownError = Box<(any Error)?>(nil)

        let group = DispatchGroup()
        group.enter()

        // Run JSC on a dedicated serial queue rather than a raw detached Thread.
        // A bare Thread's first JSContext use traps (SIGTRAP) on headless hosts
        // (e.g. CI runners with no GUI session); a libdispatch-managed worker
        // does not. A fresh queue per call keeps a timed-out block from blocking
        // later calls. The autorelease pool is still required for JSC.
        let queue = DispatchQueue(label: "com.boo.jsc.execute", qos: .userInitiated)
        queue.async {
            defer { group.leave() }
            autoreleasepool {
                do {
                    output.value = try self.runJS(
                        source: source, functionName: functionName, ctxDict: ctxDict.value)
                } catch {
                    thrownError.value = error
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            throw JSError(message: "JS transform timed out after \(Int(timeout))s")
        }

        if let err = thrownError.value { throw err }
        guard let result = output.value else {
            throw JSError(message: "Function '\(functionName)' returned null/undefined")
        }
        return result
    }

    /// Call a plugin's `onAction(name, ctx)` function and return the resulting DSL action.
    /// Returns nil if the function doesn't exist or returns null.
    func callAction(
        source: String,
        actionName: String,
        context: TerminalContext,
        settings: [String: Any] = [:],
        timeout: TimeInterval = 1.0
    ) -> DSLAction? {
        var dict = buildContextDict(from: context)
        if !settings.isEmpty {
            dict["settings"] = settings
        }
        // Box the dict so it crosses the thread boundary as an @unchecked Sendable
        // holder (see Box doc) instead of a bare non-Sendable dictionary.
        let ctxDict = Box(dict)

        let output = Box<DSLAction?>(nil)
        let group = DispatchGroup()
        group.enter()

        // Serial queue instead of a raw Thread — see execute() for why a bare
        // Thread traps (SIGTRAP) on headless hosts. The autorelease pool stays.
        let queue = DispatchQueue(label: "com.boo.jsc.action", qos: .userInitiated)
        queue.async { [self] in
            defer { group.leave() }
            autoreleasepool {
                guard let jsContext = JSContext() else { return }
                jsContext.exceptionHandler = { _, _ in }
                jsContext.setObject(ctxDict.value, forKeyedSubscript: "ctx" as NSString)
                injectHostFunctions(into: jsContext, cwd: ctxDict.value["cwd"] as? String ?? "/")
                jsContext.evaluateScript(source)

                guard let fn = jsContext.objectForKeyedSubscript("onAction"),
                    !fn.isUndefined
                else { return }

                let result = fn.call(withArguments: [actionName, ctxDict.value as Any])
                guard let value = result, !value.isUndefined, !value.isNull,
                    let dict = value.toObject() as? [String: Any],
                    let type = dict["type"] as? String
                else { return }

                output.value = DSLAction(
                    type: type,
                    path: dict["path"] as? String,
                    command: dict["command"] as? String,
                    text: dict["text"] as? String,
                    url: dict["url"] as? String,
                    title: dict["title"] as? String
                )
            }
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            return nil
        }
        return output.value
    }

    /// Run all JSC work on the current thread (must be called from the JS thread).
    private func runJS(source: String, functionName: String, ctxDict: [String: Any]) throws -> String {
        guard let jsContext = JSContext() else {
            throw JSError(message: "Failed to create JavaScript context")
        }

        var jsError: String?
        jsContext.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "Unknown JS error"
        }

        jsContext.setObject(ctxDict, forKeyedSubscript: "ctx" as NSString)
        injectHostFunctions(into: jsContext, cwd: ctxDict["cwd"] as? String ?? "/")
        jsContext.evaluateScript(source)
        if let err = jsError {
            throw JSError(message: "JS parse error: \(err)")
        }

        let fn: JSValue
        if let direct = jsContext.objectForKeyedSubscript(functionName), !direct.isUndefined {
            fn = direct
        } else {
            let alternate = functionName == "transform" ? "render" : "transform"
            if let fallback = jsContext.objectForKeyedSubscript(alternate), !fallback.isUndefined {
                fn = fallback
            } else {
                throw JSError(message: "Function '\(functionName)' (or '\(alternate)') not found in script")
            }
        }

        let result = fn.call(withArguments: [ctxDict as Any])

        if let err = jsError {
            throw JSError(message: "JS error: \(err)")
        }

        guard let value = result, !value.isUndefined, !value.isNull else {
            throw JSError(message: "Function '\(functionName)' returned null/undefined")
        }

        if value.isString {
            return value.toString()
        }

        let jsonData = try JSONSerialization.data(
            withJSONObject: value.toObject() as Any, options: [])
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    // MARK: - Host Functions

    /// Inject host-provided functions into the JS context.
    /// These give plugins controlled access to the filesystem.
    private func injectHostFunctions(into jsContext: JSContext, cwd: String) {
        let readFile: @convention(block) (String) -> String? = { path in
            guard let resolved = Self.resolvePath(path, under: cwd) else { return nil }
            return try? String(contentsOfFile: resolved, encoding: .utf8)
        }
        jsContext.setObject(readFile, forKeyedSubscript: "readFile" as NSString)

        let fileExists: @convention(block) (String) -> Bool = { path in
            guard let resolved = Self.resolvePath(path, under: cwd) else { return false }
            return FileManager.default.fileExists(atPath: resolved)
        }
        jsContext.setObject(fileExists, forKeyedSubscript: "fileExists" as NSString)

        let listDir: @convention(block) (String) -> [[String: Any]]? = { path in
            guard let resolved = Self.resolvePath(path, under: cwd) else { return nil }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resolved) else { return nil }
            return entries.prefix(500).map { name in
                var isDir: ObjCBool = false
                let full = (resolved as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                return ["name": name, "isDirectory": isDir.boolValue]
            }
        }
        jsContext.setObject(listDir, forKeyedSubscript: "listDir" as NSString)

        let readJSON: @convention(block) (String) -> Any? = { path in
            guard let resolved = Self.resolvePath(path, under: cwd),
                let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
                let json = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return json
        }
        jsContext.setObject(readJSON, forKeyedSubscript: "readJSON" as NSString)

        let allowedEnvVars: Set<String> = [
            "HOME", "USER", "SHELL", "TERM", "LANG", "PATH",
            "EDITOR", "VISUAL", "XDG_CONFIG_HOME"
        ]
        let getEnv: @convention(block) (String) -> String? = { name in
            guard allowedEnvVars.contains(name) else { return nil }
            return ProcessInfo.processInfo.environment[name]
        }
        jsContext.setObject(getEnv, forKeyedSubscript: "getEnv" as NSString)

        let pluginLogger = logger
        let log: @convention(block) (String) -> Void = { message in
            pluginLogger.debug("[Plugin] \(message)")
        }
        jsContext.setObject(log, forKeyedSubscript: "log" as NSString)
    }

    /// Resolve a path relative to cwd. Absolute paths must be under cwd (security boundary).
    private static func resolvePath(_ path: String, under cwd: String) -> String? {
        if (path as NSString).isAbsolutePath {
            let resolved = (path as NSString).standardizingPath
            let cwdPrefix = (cwd as NSString).standardizingPath
            guard resolved.hasPrefix(cwdPrefix + "/") || resolved == cwdPrefix else { return nil }
            return resolved
        }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// Build a JavaScript-compatible dictionary from TerminalContext.
    private func buildContextDict(from context: TerminalContext) -> [String: Any] {
        var dict: [String: Any] = [
            "cwd": context.cwd,
            "paneCount": context.paneCount,
            "tabCount": context.tabCount,
            "processName": context.processName,
            "isRemote": context.isRemote,
            "terminalID": context.terminalID.uuidString,
            "environmentLabel": context.environmentLabel
        ]

        if let session = context.remoteSession {
            dict["envType"] = session.envType
            dict["remoteHost"] = session.displayName
        } else {
            dict["envType"] = "local"
        }

        if let remoteCwd = context.remoteCwd {
            dict["remoteCwd"] = remoteCwd
        }

        if let git = context.gitContext {
            var gitDict: [String: Any] = [
                "branch": git.branch,
                "repoRoot": git.repoRoot,
                "isDirty": git.isDirty,
                "changedFileCount": git.changedFileCount,
                "stagedCount": git.stagedCount,
                "aheadCount": git.aheadCount,
                "behindCount": git.behindCount
            ]
            if let lastCommit = git.lastCommitShort {
                gitDict["lastCommitShort"] = lastCommit
            }
            dict["git"] = gitDict
        }

        // Expose plugin-contributed enriched data
        if !context.enrichedData.isEmpty {
            var enriched: [String: Any] = [:]
            for (key, value) in context.enrichedData {
                enriched[key] = value
            }
            dict["enrichedData"] = enriched
        }

        return dict
    }
}
