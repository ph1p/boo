import Foundation
import os.log

/// Executes plugin scripts, captures output, and handles timeouts.
/// ADR-3: NSTask/Process execution with timeout.
final class ScriptExecutor {

    struct ScriptResult {
        let output: String
        let exitCode: Int32
        let error: String?
        let timedOut: Bool
    }

    struct ScriptError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let logger = Logger(subsystem: "com.exterm", category: "ScriptExecutor")

    /// Execute a script synchronously (call from background thread).
    /// - Parameters:
    ///   - path: Absolute path to the script.
    ///   - workingDirectory: Working directory for the script.
    ///   - environment: Additional environment variables.
    ///   - timeout: Maximum execution time in seconds.
    /// - Returns: ScriptResult with stdout, exit code, and error info.
    func execute(
        path: String,
        workingDirectory: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 5.0
    ) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Merge environment
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ScriptResult(
                output: "", exitCode: -1, error: "Failed to launch: \(error.localizedDescription)", timedOut: false)
        }

        // Timeout handling
        let deadline = DispatchTime.now() + timeout
        let timedOut: Bool
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        let result = group.wait(timeout: deadline)
        if result == .timedOut {
            process.terminate()
            timedOut = true
            logger.warning("Script timed out after \(timeout)s: \(path)")
        } else {
            timedOut = false
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let exitCode = timedOut ? -1 : process.terminationStatus

        let error: String?
        if timedOut {
            error = "Script timed out after \(Int(timeout))s"
        } else if exitCode != 0 {
            error =
                stderr.isEmpty
                ? "Script exited with code \(exitCode)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            error = nil
        }

        return ScriptResult(output: stdout, exitCode: exitCode, error: error, timedOut: timedOut)
    }

    /// Execute a script asynchronously and deliver results on the main thread.
    func executeAsync(
        path: String,
        workingDirectory: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 5.0,
        completion: @escaping (ScriptResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.execute(
                path: path,
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout
            )
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Build environment variables from a TerminalContext for script execution.
    static func buildEnvironment(from context: TerminalContext) -> [String: String] {
        var env: [String: String] = [
            "EXTERM_CWD": context.cwd,
            "EXTERM_PANE_COUNT": "\(context.paneCount)",
            "EXTERM_TAB_COUNT": "\(context.tabCount)"
        ]

        // Environment type
        if let session = context.remoteSession {
            switch session {
            case .ssh(let host, _):
                env["EXTERM_ENV_TYPE"] = "ssh"
                env["EXTERM_REMOTE_HOST"] = host
            case .docker(let container):
                env["EXTERM_ENV_TYPE"] = "docker"
                env["EXTERM_REMOTE_HOST"] = container
            }
        } else {
            env["EXTERM_ENV_TYPE"] = "local"
        }

        // Git context
        if let git = context.gitContext {
            env["EXTERM_GIT_BRANCH"] = git.branch
            env["EXTERM_GIT_REPO_ROOT"] = git.repoRoot
            env["EXTERM_GIT_DIRTY"] = git.isDirty ? "true" : "false"
            env["EXTERM_GIT_CHANGED_COUNT"] = "\(git.changedFileCount)"
        }

        // Process
        if !context.processName.isEmpty {
            env["EXTERM_PROCESS"] = context.processName
        }

        return env
    }
}
