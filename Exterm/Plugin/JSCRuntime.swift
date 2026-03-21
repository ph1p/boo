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
        timeout: TimeInterval = 1.0
    ) throws -> String {
        let jsContext = JSContext()!

        // Capture exceptions
        var jsError: String?
        jsContext.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "Unknown JS error"
        }

        // Inject context as global object
        let ctxDict = buildContextDict(from: context)
        jsContext.setObject(ctxDict, forKeyedSubscript: "ctx" as NSString)

        // Evaluate the source
        jsContext.evaluateScript(source)
        if let err = jsError {
            throw JSError(message: "JS parse error: \(err)")
        }

        // Call the function — try requested name first, then fall back to "render"/"transform"
        let fn: JSValue
        if let direct = jsContext.objectForKeyedSubscript(functionName), !direct.isUndefined {
            fn = direct
        } else {
            // Try the alternate name so both "render" and "transform" work
            let alternate = functionName == "transform" ? "render" : "transform"
            if let fallback = jsContext.objectForKeyedSubscript(alternate), !fallback.isUndefined {
                fn = fallback
            } else {
                throw JSError(message: "Function '\(functionName)' (or '\(alternate)') not found in script")
            }
        }

        // Execute with timeout via GCD
        var result: JSValue?
        var timedOut = false

        let group = DispatchGroup()
        group.enter()

        let workItem = DispatchWorkItem {
            result = fn.call(withArguments: [ctxDict as Any])
            group.leave()
        }

        // JSC must run on the thread that created the context
        workItem.perform()

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            timedOut = true
        }

        if timedOut {
            throw JSError(message: "JS transform timed out after \(Int(timeout))s")
        }

        if let err = jsError {
            throw JSError(message: "JS error: \(err)")
        }

        guard let value = result, !value.isUndefined, !value.isNull else {
            throw JSError(message: "Function '\(functionName)' returned null/undefined")
        }

        // Convert result to JSON string
        if value.isString {
            return value.toString()
        }

        // Serialize object/array to JSON
        let jsonData = try JSONSerialization.data(
            withJSONObject: value.toObject() as Any,
            options: []
        )
        return String(data: jsonData, encoding: .utf8) ?? "{}"
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
