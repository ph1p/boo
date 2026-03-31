import SwiftUI
import os.log

/// Adapts an external JS plugin (manifest + main.js) into the BooPlugin protocol.
/// Bridges external plugins into the same lifecycle as built-in Swift plugins.
@MainActor
final class ScriptPluginAdapter: BooPluginProtocol {
    enum DetailState: Equatable {
        case loading
        case error(String)
        case rendered
    }

    let manifest: PluginManifest
    let pluginFolderPath: String
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    // External plugins subscribe to all events since we can't
    // know which callbacks the script uses.
    var subscribedEvents: Set<PluginEvent> {
        [
            .cwdChanged, .processChanged, .remoteSessionChanged, .focusChanged,
            .terminalCreated, .terminalClosed, .remoteDirectoryListed
        ]
    }

    private let jscRuntime = JSCRuntime()
    private let logger = Logger(subsystem: "com.boo", category: "ScriptPlugin")

    /// Cached DSL output from last JS execution.
    private var cachedDSLElements: [DSLElement]?
    private var cachedError: String?

    init(manifest: PluginManifest, folderPath: String) {
        self.manifest = manifest
        self.pluginFolderPath = folderPath
    }

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        // External plugins don't enrich in v1.
    }

    // MARK: - React

    func react(context: TerminalContext) {
        executePlugin(context: context)
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard let template = manifest.statusBar?.template else {
            return StatusBarContent(
                text: manifest.name,
                icon: manifest.icon,
                tint: cachedError != nil ? .error : nil,
                accessibilityLabel: cachedError != nil ? "\(manifest.name): error" : manifest.name
            )
        }

        let text = substituteTemplate(template, context: context.terminal)
        return StatusBarContent(
            text: text,
            icon: manifest.icon,
            tint: cachedError != nil ? .error : nil,
            accessibilityLabel: cachedError != nil ? "\(manifest.name): error" : "\(manifest.name): \(text)"
        )
    }

    // MARK: - Detail View

    func detailState() -> DetailState {
        if let error = cachedError {
            return .error(error)
        }
        if cachedDSLElements != nil {
            return .rendered
        }
        return .loading
    }

    func makeDetailView(context: PluginContext) -> AnyView? {
        switch detailState() {
        case .error(let error):
            return AnyView(PluginErrorView(pluginName: manifest.name, error: error))
        case .loading:
            return AnyView(PluginLoadingView(pluginName: manifest.name))
        case .rendered:
            guard let elements = cachedDSLElements else {
                return AnyView(PluginLoadingView(pluginName: manifest.name))
            }
            let act = actions
            return AnyView(
                DSLRenderer(
                    elements: elements,
                    theme: AppSettings.shared.theme,
                    density: context.density,
                    onAction: { act?.handle($0) }
                ))
        }
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        executePlugin(context: context)
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        // Use cached output on focus switch — don't re-run
    }

    // MARK: - JS Execution

    private func executePlugin(context: TerminalContext) {
        let scriptPath = (pluginFolderPath as NSString).appendingPathComponent("main.js")

        guard let source = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            // No main.js — plugin is manifest-only (static panel)
            return
        }
        do {
            let settings = buildSettingsDict()
            let jsonOutput = try jscRuntime.execute(
                source: source, context: context, settings: settings)
            let elements = try DSLParser.parse(jsonOutput)
            cachedDSLElements = elements
            cachedError = nil
        } catch {
            cachedError = "\(error)"
            logger.error("JS error for \(self.pluginID): \(error.localizedDescription)")
        }
    }

    // MARK: - Settings

    private func buildSettingsDict() -> [String: Any] {
        guard let declarations = manifest.settings, !declarations.isEmpty else { return [:] }
        var dict: [String: Any] = [:]
        for setting in declarations {
            switch setting.type {
            case .bool:
                dict[setting.key] = AppSettings.shared.pluginBool(
                    pluginID, setting.key,
                    default: (setting.defaultValue?.value as? Bool) ?? false)
            case .string:
                dict[setting.key] = AppSettings.shared.pluginString(
                    pluginID, setting.key,
                    default: (setting.defaultValue?.value as? String) ?? "")
            case .int:
                dict[setting.key] = Int(
                    AppSettings.shared.pluginDouble(
                        pluginID, setting.key,
                        default: Double((setting.defaultValue?.value as? Int) ?? 0)))
            case .double:
                dict[setting.key] = AppSettings.shared.pluginDouble(
                    pluginID, setting.key,
                    default: (setting.defaultValue?.value as? Double) ?? 0)
            }
        }
        return dict
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
            result = result.replacingOccurrences(of: "{remote.host}", with: session.displayName)
        }
        return result
    }
}

// MARK: - Helper Views

struct PluginErrorView: View {
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

struct PluginLoadingView: View {
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
