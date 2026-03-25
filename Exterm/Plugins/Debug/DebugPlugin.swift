import SwiftUI

/// Built-in debug plugin that logs every lifecycle event and displays live state.
/// Useful for diagnosing issues with process detection, remote sessions, CWD tracking, etc.
@MainActor
final class DebugPlugin: ExtermPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "debug",
        name: "Debug",
        version: "1.0.0",
        icon: "ladybug.fill",
        description: "Logs all plugin lifecycle events and displays live terminal state",
        when: nil,
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 99, template: nil),
        settings: [
            PluginManifest.SettingManifest(
                key: "maxEntries", type: .double, label: "Max log entries",
                defaultValue: AnyCodableValue(200.0), options: nil)
        ]
    )

    var prefersOuterScrollView: Bool { false }

    var subscribedEvents: Set<PluginEvent> {
        [.cwdChanged, .processChanged, .remoteSessionChanged, .focusChanged,
         .terminalCreated, .terminalClosed, .remoteDirectoryListed]
    }

    // MARK: - Log Storage

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let event: String
        let detail: String
    }

    private(set) var entries: [LogEntry] = []
    var maxEntries: Int = 200

    /// Last enrichment context values for display.
    private var lastEnrichCwd: String?
    private var lastEnrichProcess: String?
    private var lastEnrichRemote: String?

    private func log(_ event: String, _ detail: String = "") {
        NSLog("[DebugPlugin] \(event)\(detail.isEmpty ? "" : ": \(detail)")")
        let entry = LogEntry(timestamp: Date(), event: event, detail: detail)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: - Phase 1: Enrich

    func enrich(context: EnrichmentContext) {
        lastEnrichCwd = context.cwd
        lastEnrichProcess = context.processName
        lastEnrichRemote = context.remoteSession?.displayName

        var parts: [String] = ["cwd=\(context.cwd)"]
        if !context.processName.isEmpty { parts.append("process=\(context.processName)") }
        if let r = context.remoteSession { parts.append("remote=\(r.displayName)") }
        if let branch = context.gitBranch { parts.append("git=\(branch)") }
        parts.append("panes=\(context.paneCount) tabs=\(context.tabCount)")
        log("enrich", parts.joined(separator: " | "))
    }

    // MARK: - Phase 2: React

    func react(context: TerminalContext) {
        var parts: [String] = ["cwd=\(context.cwd)"]
        if !context.processName.isEmpty { parts.append("process=\(context.processName)") }
        if let r = context.remoteSession { parts.append("remote=\(r.displayName)") }
        if let git = context.gitContext {
            var gitParts = ["branch=\(git.branch)"]
            if git.isDirty { gitParts.append("dirty(\(git.changedFileCount))") }
            if git.stagedCount > 0 { gitParts.append("staged(\(git.stagedCount))") }
            if git.aheadCount > 0 { gitParts.append("ahead(\(git.aheadCount))") }
            if git.behindCount > 0 { gitParts.append("behind(\(git.behindCount))") }
            parts.append("git=\(gitParts.joined(separator: ","))")
        }
        if !context.enrichedData.isEmpty {
            let keys = context.enrichedData.keys.sorted()
            parts.append("enriched=[\(keys.joined(separator: ","))]")
        }
        log("react", parts.joined(separator: " | "))
    }

    // MARK: - Lifecycle Events

    func cwdChanged(newPath: String, context: TerminalContext) {
        log("cwdChanged", "path=\(newPath) | process=\(context.processName) | remote=\(context.remoteSession?.displayName ?? "nil")")
    }

    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        log("remoteSessionChanged", "session=\(session?.displayName ?? "nil") | type=\(session?.envType ?? "local") | cwd=\(context.cwd)")
    }

    func processChanged(name: String, context: TerminalContext) {
        let category = ProcessIcon.category(for: name) ?? "unknown"
        log("processChanged", "name=\(name.isEmpty ? "(empty)" : name) | category=\(category) | cwd=\(context.cwd)")
    }

    func terminalCreated(terminalID: UUID) {
        log("terminalCreated", "id=\(terminalID.uuidString.prefix(8))")
    }

    func terminalClosed(terminalID: UUID) {
        log("terminalClosed", "id=\(terminalID.uuidString.prefix(8))")
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        log("focusChanged", "id=\(terminalID.uuidString.prefix(8)) | cwd=\(context.cwd) | process=\(context.processName)")
    }

    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) {
        let dirs = entries.filter(\.isDirectory).count
        let files = entries.count - dirs
        log("remoteDirectoryListed", "path=\(path) | dirs=\(dirs) files=\(files)")
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        let eventCount = entries.count
        let lastEvent = entries.last?.event ?? "idle"
        return StatusBarContent(
            text: "\(eventCount) \(lastEvent)",
            icon: "ladybug.fill",
            tint: nil,
            accessibilityLabel: "Debug: \(eventCount) events, last: \(lastEvent)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        "Debug (\(entries.count) events)"
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        maxEntries = Int(context.settings.double("maxEntries", default: 200))

        return AnyView(
            DebugDetailView(
                entries: entries,
                context: context.terminal,
                theme: context.theme,
                density: context.density,
                onClear: { [weak self] in
                    self?.entries.removeAll()
                    self?.onRequestCycleRerun?()
                },
                onCopyLog: { [weak self] in
                    guard let self else { return }
                    let text = self.entries.map { entry in
                        let ts = Self.timeFormatter.string(from: entry.timestamp)
                        return "[\(ts)] \(entry.event)\(entry.detail.isEmpty ? "" : ": \(entry.detail)")"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            )
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Detail View

private struct DebugDetailView: View {
    let entries: [DebugPlugin.LogEntry]
    let context: TerminalContext
    let theme: ThemeSnapshot
    let density: SidebarDensity
    let onClear: () -> Void
    let onCopyLog: () -> Void

    @State private var showState = true
    @State private var filter = ""

    private var fontSize: CGFloat { density == .compact ? 9.0 : 10.0 }
    private var textColor: Color { Color(nsColor: theme.chromeText) }
    private var mutedColor: Color { Color(nsColor: theme.chromeMuted) }
    private var accentColor: Color { Color(nsColor: theme.accentColor) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 4) {
                Button(showState ? "Log" : "State") {
                    showState.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: fontSize))
                .foregroundColor(accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(accentColor.opacity(0.1))
                .cornerRadius(3)

                Spacer()

                Button("Copy") { onCopyLog() }
                    .buttonStyle(.plain)
                    .font(.system(size: fontSize))
                    .foregroundColor(mutedColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(mutedColor.opacity(0.1))
                    .cornerRadius(3)

                Button("Clear") { onClear() }
                    .buttonStyle(.plain)
                    .font(.system(size: fontSize))
                    .foregroundColor(mutedColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(mutedColor.opacity(0.1))
                    .cornerRadius(3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if showState {
                stateView
            } else {
                logView
            }
        }
    }

    // MARK: - State View

    private var stateView: some View {
        VStack(alignment: .leading, spacing: 6) {
            stateRow("Terminal", context.terminalID.uuidString.prefix(8).description)
            stateRow("CWD", context.cwd)
            stateRow("Process", context.processName.isEmpty ? "(none)" : context.processName)
            if !context.processName.isEmpty {
                stateRow("Category", ProcessIcon.category(for: context.processName) ?? "unknown")
            }
            stateRow("Remote", context.remoteSession?.displayName ?? "local")
            if let remoteCwd = context.remoteCwd {
                stateRow("Remote CWD", remoteCwd)
            }
            stateRow("Panes", "\(context.paneCount)")
            stateRow("Tabs", "\(context.tabCount)")

            Divider().opacity(0.3).padding(.vertical, 2)

            if let git = context.gitContext {
                stateRow("Git Branch", git.branch)
                stateRow("Git Root", git.repoRoot)
                stateRow("Dirty", "\(git.isDirty) (\(git.changedFileCount) changed, \(git.stagedCount) staged)")
                stateRow("Ahead/Behind", "\(git.aheadCount)/\(git.behindCount)")
                if let commit = git.lastCommitShort {
                    stateRow("Last Commit", commit)
                }
            } else {
                stateRow("Git", "not active")
            }

            if !context.enrichedData.isEmpty {
                Divider().opacity(0.3).padding(.vertical, 2)
                ForEach(context.enrichedData.keys.sorted(), id: \.self) { key in
                    stateRow(key, "\(context.enrichedData[key] ?? "" as AnyHashable)")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(mutedColor)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Log View

    private var logView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filter
            HStack {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: fontSize))
                    .foregroundColor(mutedColor)
                TextField("Filter events...", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .foregroundColor(textColor)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let filtered = filteredEntries
                        ForEach(filtered) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: entries.count) { _ in
                    if let last = filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredEntries: [DebugPlugin.LogEntry] {
        if filter.isEmpty { return entries }
        let lower = filter.lowercased()
        return entries.filter {
            $0.event.lowercased().contains(lower) || $0.detail.lowercased().contains(lower)
        }
    }

    private func logRow(_ entry: DebugPlugin.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundColor(mutedColor.opacity(0.7))
            Text(entry.event)
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(eventColor(entry.event))
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundColor(textColor.opacity(0.8))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private func eventColor(_ event: String) -> Color {
        switch event {
        case "cwdChanged": return Color(nsColor: .systemBlue)
        case "processChanged": return Color(nsColor: .systemOrange)
        case "remoteSessionChanged": return Color(nsColor: .systemPurple)
        case "focusChanged": return Color(nsColor: .systemTeal)
        case "terminalCreated", "terminalClosed": return Color(nsColor: .systemGreen)
        case "remoteDirectoryListed": return Color(nsColor: .systemIndigo)
        case "enrich": return mutedColor
        case "react": return mutedColor.opacity(0.7)
        default: return textColor
        }
    }
}
