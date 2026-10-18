import SwiftUI

/// State behind a timeline tab: the session's transcript, re-read while the
/// tab is visible so a running agent's timeline keeps growing.
@MainActor
final class AgentTimelineModel: ObservableObject {
    let sessionID: String
    let label: String
    /// The tab showing this timeline; its window is looked up per use since
    /// the tab can move between windows.
    var tabID: UUID?

    @Published private(set) var timeline: AgentTimeline?
    @Published private(set) var transcript: URL?
    @Published private(set) var isMissing = false
    private var timer: Timer?
    private var isLoading = false
    /// Ticks skipped since the last transcript search while it is missing.
    private var missingTicks = 0

    static let refreshInterval: TimeInterval = 3

    /// Re-search for a missing transcript every this many ticks only.
    static let missingBackoff = 5

    init(sessionID: String, label: String) {
        self.sessionID = sessionID
        self.label = label
    }

    private var controller: MainWindowController? {
        tabID.flatMap { AgentInbox.locateInWindows($0)?.controller } ?? WindowManager.shared.activeController
    }

    func startRefreshing() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    /// Timer reload: skipped while the tab's window can't be seen, and backed
    /// off while the transcript can't be found (each search scans every project).
    private func tick() {
        guard controller?.window?.occlusionState.contains(.visible) ?? false else { return }
        if transcript == nil {
            missingTicks += 1
            guard missingTicks >= Self.missingBackoff else { return }
            missingTicks = 0
        }
        reload()
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        let sessionID = sessionID
        let known = transcript
        DispatchQueue.global(qos: .userInitiated).async {
            let url = known ?? AgentTimeline.transcriptURL(sessionID: sessionID)
            let timeline = url.flatMap { AgentTimelineStore.shared.load($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.transcript = url
                self.isMissing = timeline == nil
                if timeline != self.timeline { self.timeline = timeline }
            }
        }
    }

    func open(_ path: String) { controller?.handleOpenTab(.file(path: path)) }

    func openTranscript() {
        guard let transcript else { return }
        NSWorkspace.shared.activateFileViewerSelecting([transcript])
    }

    /// `path` relative to the session's folder when inside it.
    func display(_ path: String) -> String {
        guard let cwd = timeline?.cwd, path.hasPrefix(cwd + "/") else {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return String(path.dropFirst(cwd.count + 1))
    }
}

/// Timeline tab: what an agent session did, one card per prompt, with the
/// tools it ran, the files it changed, tokens and cost. Repeated calls show as
/// one row with a count; three or more in a row are flagged as a loop.
struct AgentTimelineView: View {
    @ObservedObject var model: AgentTimelineModel
    @State private var expanded: Set<Int> = []
    @State private var problemsOnly = false

    private var t: Tokens { Tokens(theme: AppSettings.shared.theme) }
    private var mono: Font {
        .custom(AppSettings.shared.editorFontName, size: max(10, CGFloat(AppSettings.shared.editorFontSize) - 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let timeline = model.timeline {
                header(timeline)
                Rectangle().fill(t.separator).frame(height: 1)
                turnList(timeline)
            } else {
                placeholder(
                    model.isMissing
                        ? "No transcript found for session \(model.sessionID).\nTimelines are available for Claude Code sessions."
                        : "Loading timeline…")
            }
        }
        .background(t.chromeBg)
        .onAppear { model.startRefreshing() }
        .onDisappear { model.stopRefreshing() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(t.textSecondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private func header(_ timeline: AgentTimeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeline.title ?? model.label)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text).lineLimit(1)
                    Text(subtitle(timeline)).font(.system(size: 11)).foregroundStyle(t.textSecondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.money(timeline.cost, exact: timeline.costIsExact))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(t.text)
                        .help(
                            timeline.costIsExact
                                ? "Cost reported by Claude Code when the session ended"
                                : "Estimated from token counts at list prices; Claude Code reports the exact cost when the session ends"
                        )
                    Text(tokenSummary(timeline)).font(.system(size: 10)).foregroundStyle(t.textTertiary)
                        .help(tokenDetail(timeline))
                }
            }
            HStack(spacing: 6) {
                stat("\(timeline.turns.count) prompt\(timeline.turns.count == 1 ? "" : "s")", icon: "text.bubble")
                stat("\(timeline.toolCount) tool call\(timeline.toolCount == 1 ? "" : "s")", icon: "wrench")
                if timeline.loopCount > 0 {
                    stat(
                        "\(timeline.loopCount) repeated call\(timeline.loopCount == 1 ? "" : "s")",
                        icon: "arrow.triangle.2.circlepath", color: t.color(\.warning))
                }
                Spacer()
                Toggle("Loops & failures only", isOn: $problemsOnly).toggleStyle(.checkbox)
                    .font(.system(size: 11)).foregroundStyle(t.textSecondary)
                Button("Transcript") { model.openTranscript() }.disabled(model.transcript == nil)
            }
            if !timeline.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Text("Changed").font(.system(size: 10)).foregroundStyle(t.textTertiary)
                        ForEach(timeline.files, id: \.path) { file in
                            Button {
                                model.open(file.path)
                            } label: {
                                Text(
                                    file.edits > 1
                                        ? "\(model.display(file.path)) ×\(file.edits)" : model.display(file.path)
                                )
                                .font(.system(size: 10)).foregroundStyle(t.text)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(t.separator))
                            }
                            .buttonStyle(.plain)
                            .help(file.path)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func subtitle(_ timeline: AgentTimeline) -> String {
        var parts = [model.label]
        if let model = timeline.models.last { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
        if let branch = timeline.branch { parts.append(branch) }
        if let start = timeline.start {
            parts.append("started \(formatAgentRelativeDate(start))")
            if let end = timeline.end { parts.append(formatAgentRuntime(end.timeIntervalSince(start))) }
        }
        return parts.joined(separator: " · ")
    }

    private func tokenSummary(_ timeline: AgentTimeline) -> String {
        let usage = timeline.usage + timeline.subagentUsage
        return "\(Self.tokens(usage.total)) tokens · \(Self.tokens(usage.output)) out"
    }

    private func tokenDetail(_ timeline: AgentTimeline) -> String {
        let u = timeline.usage
        var lines = [
            "Input: \(Self.tokens(u.input))", "Output: \(Self.tokens(u.output))",
            "Cache read: \(Self.tokens(u.cacheRead))", "Cache write: \(Self.tokens(u.cacheWrite))"
        ]
        if timeline.subagentUsage.total > 0 {
            lines.append(
                "Subagents: \(Self.tokens(timeline.subagentUsage.total)) tokens, \(Self.money(timeline.subagentCost, exact: false))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func stat(_ text: String, icon: String, color: Color? = nil) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11)).foregroundStyle(color ?? t.textSecondary)
    }

    // MARK: Turns

    private func turnList(_ timeline: AgentTimeline) -> some View {
        let turns =
            problemsOnly
            ? timeline.turns.filter { $0.hasLoop || $0.tools.contains { $0.failures > 0 } } : timeline.turns
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if turns.isEmpty {
                        placeholder(problemsOnly ? "No repeated or failed tool calls." : "No prompts yet.")
                            .padding(.top, 40)
                    }
                    ForEach(turns) { turn in
                        turnRow(turn, peak: timeline.turns.map(\.cost).max() ?? 0).id(turn.id)
                        Rectangle().fill(t.separator).frame(height: 1)
                    }
                }
            }
            .onAppear { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
            .onChange(of: timeline.turns.count) { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
        }
    }

    private func turnRow(_ turn: AgentTimeline.Turn, peak: Double) -> some View {
        let isExpanded = expanded.contains(turn.id)
        let tools = problemsOnly ? turn.tools.filter { $0.isLoop || $0.failures > 0 } : turn.tools
        let shown = isExpanded || tools.count <= 8 ? tools : Array(tools.prefix(6))
        return HStack(alignment: .top, spacing: 10) {
            Text(turn.start.map(Self.time) ?? "")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(t.textTertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                prompt(turn, isExpanded: isExpanded)
                meta(turn, peak: peak)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, tool in toolRow(tool) }
                if shown.count < tools.count {
                    Button("Show all \(tools.count) tool rows") { expanded.insert(turn.id) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                if let reply = turn.reply {
                    Text(reply).font(.system(size: 11)).foregroundStyle(t.textSecondary)
                        .lineLimit(isExpanded ? nil : 2).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(turn.hasLoop ? t.color(\.warning).opacity(0.06) : .clear)
    }

    private func prompt(_ turn: AgentTimeline.Turn, isExpanded: Bool) -> some View {
        let icon: String
        switch turn.kind {
        case .prompt: icon = "person.fill"
        case .command: icon = "command"
        case .compacted: icon = "arrow.down.right.and.arrow.up.left"
        }
        return Button {
            if isExpanded { expanded.remove(turn.id) } else { expanded.insert(turn.id) }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(t.accent).frame(width: 14)
                    .padding(.top, 2)
                Text(turn.prompt.isEmpty ? "(no prompt)" : turn.prompt)
                    .font(.system(size: 12, weight: turn.kind == .compacted ? .regular : .medium))
                    .foregroundStyle(turn.kind == .compacted ? t.textSecondary : t.text)
                    .lineLimit(isExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meta(_ turn: AgentTimeline.Turn, peak: Double) -> some View {
        var parts: [String] = []
        if turn.toolCount > 0 { parts.append("\(turn.toolCount) tool\(turn.toolCount == 1 ? "" : "s")") }
        if let duration = turn.duration, duration >= 1 { parts.append(Self.duration(duration)) }
        if turn.usage.output > 0 { parts.append("\(Self.tokens(turn.usage.output)) out") }
        if turn.context > 0 { parts.append("context \(Self.tokens(turn.context))") }
        return HStack(spacing: 6) {
            Text(parts.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(t.textTertiary)
            if turn.interrupted {
                Text("interrupted").font(.system(size: 10)).foregroundStyle(t.color(\.warning))
            }
            Spacer()
            if turn.cost > 0 {
                // Bar: share of the most expensive prompt, to spot the costly ones.
                RoundedRectangle(cornerRadius: 2).fill(t.accent.opacity(0.5))
                    .frame(width: max(2, 60 * CGFloat(peak > 0 ? turn.cost / peak : 0)), height: 4)
                Text(Self.money(turn.cost, exact: true)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(t.textSecondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.leading, 20)
    }

    private func toolRow(_ tool: AgentTimeline.Tool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.icon(for: tool.name)).font(.system(size: 9)).foregroundStyle(t.textTertiary)
                .frame(width: 14)
            Text(Self.shortName(tool.name)).font(.system(size: 10, weight: .semibold)).foregroundStyle(t.textSecondary)
            Group {
                if let file = tool.file {
                    Button(model.display(file)) { model.open(file) }.buttonStyle(.link)
                } else {
                    Text(tool.name == "Read" ? model.display(tool.summary) : tool.summary)
                        .foregroundStyle(t.text)
                }
            }
            .font(mono).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if tool.failures > 0 {
                Label(tool.count > 1 ? "\(tool.failures) failed" : "failed", systemImage: "xmark.circle")
                    .font(.system(size: 10)).foregroundStyle(t.color(\.error))
            }
            if tool.count > 1 {
                Text("×\(tool.count)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tool.isLoop ? t.color(\.warning) : t.textSecondary)
                    .help(tool.isLoop ? "Same call \(tool.count) times in a row — the agent may be stuck" : "")
            }
        }
        .padding(.leading, 20)
    }

    // MARK: Formatting

    static func icon(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task": return "person.2"
        case "Skill": return "sparkles"
        case "TodoWrite": return "checklist"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece" : "wrench"
        }
    }

    /// `mcp__boo__split_pane` → `boo: split_pane`.
    static func shortName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.count == 2 ? "\(parts[0]): \(parts[1])" : String(tool.dropFirst(5))
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...: return "\(count / 1000)k"
        case 1000...: return String(format: "%.1fk", Double(count) / 1000)
        default: return "\(count)"
        }
    }

    static func money(_ amount: Double, exact: Bool) -> String {
        let value = String(format: "$%.2f", amount)
        return exact ? value : "≈ \(value)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
}
