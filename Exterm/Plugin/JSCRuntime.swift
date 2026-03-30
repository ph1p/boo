import Foundation
import JavaScriptCore
import os.log

/// JavaScriptCore runtime for inline plugin transforms.
/// ADR-3: JSC for fast inline logic without shell overhead.
final class JSCRuntime {

    struct JSError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let logger = Logger(subsystem: "com.exterm", category: "JSCRuntime")

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
        var ctxDict = buildContextDict(from: context)
        if !settings.isEmpty {
            ctxDict["settings"] = settings
        }

        // All JSC work runs on a dedicated thread (JSContext is thread-bound).
        // The calling thread waits with a deadline so infinite loops don't hang.
        var output: String?
        var thrownError: (any Error)?

        let group = DispatchGroup()
        group.enter()

        let jsThread = Thread {
            defer { group.leave() }
            do {
                output = try self.runJS(
                    source: source, functionName: functionName, ctxDict: ctxDict)
            } catch {
                thrownError = error
            }
        }
        jsThread.qualityOfService = .userInitiated
        jsThread.start()

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            jsThread.cancel()
            throw JSError(message: "JS transform timed out after \(Int(timeout))s")
        }

        if let err = thrownError { throw err }
        guard let result = output else {
            throw JSError(message: "Function '\(functionName)' returned null/undefined")
        }
        return result
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
            "isRemote": context.isRemote
        ]

        if let session = context.remoteSession {
            dict["envType"] = session.envType
            dict["remoteHost"] = session.displayName
        } else {
            dict["envType"] = "local"
        }

        if let git = context.gitContext {
            dict["git"] =
                [
                    "branch": git.branch,
                    "repoRoot": git.repoRoot,
                    "isDirty": git.isDirty,
                    "changedFileCount": git.changedFileCount
                ] as [String: Any]
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
