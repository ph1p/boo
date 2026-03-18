import SwiftUI
import os.log

/// Adapts a script-based plugin (manifest + script folder) into the ExtermPlugin protocol.
/// Bridges external JSON plugins into the same lifecycle as built-in Swift plugins.
@MainActor
final class ScriptPluginAdapter: ExtermPluginProtocol {
    let pluginID: String
    let manifest: PluginManifest
    let pluginFolderPath: String

    private let scriptExecutor = ScriptExecutor()
    private let jscRuntime = JSCRuntime()
    private let logger = Logger(subsystem: "com.exterm", category: "ScriptPlugin")

    /// Cached DSL output from last script execution.
    private var cachedDSLElements: [DSLElement]?
    private var cachedError: String?

    var whenClause: WhenClauseNode? {
        guard let when = manifest.when else { return nil }
        return try? WhenClauseParser.parse(when)
    }

    init(manifest: PluginManifest, folderPath: String) {
        self.pluginID = manifest.id
        self.manifest = manifest
        self.pluginFolderPath = folderPath
    }

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        // Script plugins don't enrich by default in v1.
        // Future: manifest can declare "enrich": true with a script that outputs context additions.
    }

    // MARK: - React

    func react(context: TerminalContext) {
        // Trigger async script execution on react, cache results
        executePluginScript(context: context)
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? {
        guard let template = manifest.statusBar?.template else {
            // No template — use plugin name
            return StatusBarContent(
                text: manifest.name,
                icon: manifest.icon,
                tint: cachedError != nil ? .error : nil,
                accessibilityLabel: cachedError != nil ? "\(manifest.name): error" : manifest.name
            )
        }

        let text = substituteTemplate(template, context: context)
        return StatusBarContent(
            text: text,
            icon: manifest.icon,
            tint: cachedError != nil ? .error : nil,
            accessibilityLabel: cachedError != nil ? "\(manifest.name): error" : "\(manifest.name): \(text)"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? {
        if let error = cachedError {
            return AnyView(ScriptPluginErrorView(pluginName: manifest.name, error: error))
        }
        guard let elements = cachedDSLElements else {
            return AnyView(ScriptPluginLoadingView(pluginName: manifest.name))
        }
        let theme = AppSettings.shared.theme
        let density = AppSettings.shared.sidebarDensity
        return AnyView(DSLRenderer(
            elements: elements,
            theme: theme,
            density: density,
            onAction: { actionHandler.handle($0) }
        ))
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        executePluginScript(context: context)
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        // Use cached output on focus switch — don't re-run script
    }

    // MARK: - Script Execution

    private func executePluginScript(context: TerminalContext) {
        // Find script path from manifest
        // Convention: look for scripts declared in manifest, or fall back to main.sh / main.js
        let scriptPath: String
        let isJS: Bool

        if manifest.runtime == .js {
            scriptPath = (pluginFolderPath as NSString).appendingPathComponent("main.js")
            isJS = true
        } else {
            // Look for any executable script
            let candidates = ["main.sh", "fetch-data.sh", "main.py", "main.rb"]
            let found = candidates.first { name in
                let path = (pluginFolderPath as NSString).appendingPathComponent(name)
                return FileManager.default.isExecutableFile(atPath: path)
            }
            guard let scriptName = found else {
                // No script — plugin is manifest-only (static panel)
                return
            }
            scriptPath = (pluginFolderPath as NSString).appendingPathComponent(scriptName)
            isJS = false
        }

        let env = ScriptExecutor.buildEnvironment(from: context)

        if isJS {
            // Read JS source and execute via JSC
            guard let source = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
                cachedError = "Cannot read script: \(scriptPath)"
                return
            }
            do {
                let jsonOutput = try jscRuntime.execute(source: source, context: context)
                let elements = try DSLParser.parse(jsonOutput)
                cachedDSLElements = elements
                cachedError = nil
            } catch {
                cachedError = "\(error)"
                logger.error("JSC error for \(self.pluginID): \(error.localizedDescription)")
            }
        } else {
            // Execute shell script async
            scriptExecutor.executeAsync(
                path: scriptPath,
                workingDirectory: pluginFolderPath,
                environment: env,
                timeout: 5.0
            ) { [weak self] result in
                guard let self = self else { return }
                if let error = result.error {
                    self.cachedError = error
                    self.cachedDSLElements = nil
                    self.logger.error("Script error for \(self.pluginID): \(error)")
                } else {
                    do {
                        let elements = try DSLParser.parse(result.output)
                        self.cachedDSLElements = elements
                        self.cachedError = nil
                    } catch {
                        self.cachedError = "Invalid output: \(error)"
                        self.logger.error("Parse error for \(self.pluginID): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Template Substitution

    private func substituteTemplate(_ template: String, context: TerminalContext) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{cwd}", with: context.cwd)
        result = result.replacingOccurrences(of: "{process.name}", with: context.processName)
        if let git = context.gitContext {
            result = result.replacingOccurrences(of: "{git.branch}", with: git.branch)
            result = result.replacingOccurrences(of: "{git.changedCount}", with: "\(git.changedFileCount)")
        }
        if let session = context.remoteSession {
            switch session {
            case .ssh(let host):
                result = result.replacingOccurrences(of: "{remote.host}", with: host)
            case .docker(let container):
                result = result.replacingOccurrences(of: "{remote.host}", with: container)
            }
        }
        return result
    }
}

// MARK: - Helper Views

struct ScriptPluginErrorView: View {
    let pluginName: String
    let error: String

    var body: some View {
        let theme = AppSettings.shared.theme
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                Text("\(pluginName) error")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
            }
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: theme.chromeMuted))
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pluginName) error: \(error)")
    }
}

struct ScriptPluginLoadingView: View {
    let pluginName: String

    var body: some View {
        let theme = AppSettings.shared.theme
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Loading...")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: theme.chromeMuted))
        }
        .padding(12)
        .accessibilityLabel("\(pluginName), loading")
    }
}
