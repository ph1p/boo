import SwiftUI

struct TasksPanelView: View {
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    @ObservedObject var store = TaskRunStore.shared
    let cwd: String
    let repoRoot: String?
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    let onRun: (ProjectTask, String) -> Void
    let onRunHere: (ProjectTask) -> Void

    @State private var groups: [ProjectTaskGroup] = []
    @State private var scannedFor = ""

    var body: some View {
        let _ = settings.revision
        let t = Tokens.current

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(t.accent)
                Text("TASKS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(t.muted)
                    .tracking(0.8)
                Spacer()
                Button(action: scan) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
                .help("Rescan tasks")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "play.square.stack")
                        .font(.system(size: 24))
                        .foregroundStyle(t.textTertiary)
                    Text(cwd.isEmpty ? "Tasks run in local terminals" : "No tasks found")
                        .font(fontScale.font(.base))
                        .foregroundStyle(t.textTertiary)
                    Text("package.json, Makefile, justfile, Cargo.toml, Package.swift")
                        .font(fontScale.font(.xs))
                        .foregroundStyle(t.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        if groups.count > 1 {
                            Text((group.root as NSString).lastPathComponent)
                                .font(fontScale.font(.xs).weight(.semibold))
                                .foregroundStyle(t.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                        }
                        ForEach(store.ordered(group)) { task in
                            TaskRow(
                                task: task, run: store.lastRun(of: task, in: group.root),
                                isRunning: store.isRunning(task, in: group.root), fontScale: fontScale, t: t,
                                onRun: { onRun(task, group.root) },
                                onRunHere: { onRunHere(task) })
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(t.bg)
        .onAppear { if scannedFor != scanKey { scan() } }
        .onChange(of: scanKey) { _, _ in scan() }
    }

    private var scanKey: String { cwd + "\u{0}" + (repoRoot ?? "") }

    private func scan() {
        scannedFor = scanKey
        groups = ProjectTaskScanner.groups(cwd: cwd, repoRoot: repoRoot)
    }
}

struct TaskRow: View {
    let task: ProjectTask
    let run: TaskRun?
    let isRunning: Bool
    let fontScale: SidebarFontScale
    let t: Tokens
    let onRun: () -> Void
    let onRunHere: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(task.tool)
                .font(.system(size: fontScale.size(.xs) - 1, weight: .medium, design: .monospaced))
                .foregroundStyle(t.textTertiary)
                .frame(width: 34, alignment: .leading)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                if !task.detail.isEmpty {
                    Text(task.detail)
                        .font(.system(size: fontScale.size(.xs), design: .monospaced))
                        .foregroundStyle(t.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .help("Run in a new tab")
            } else {
                status
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? t.hoverFill : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onRun() }
        .help(task.command)
        .contextMenu {
            Button("Run in New Tab") { onRun() }
            Button("Run in Current Terminal") { onRunHere() }
            Divider()
            Button("Copy Command") { PluginActions.copyToPasteboard(task.command) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Runs \(task.command) in a new tab")
    }

    @ViewBuilder private var status: some View {
        if isRunning {
            ProgressView().controlSize(.mini)
        } else if let run, run.duration != nil {
            let failed = (run.exitCode ?? 0) != 0
            HStack(spacing: 3) {
                Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(failed ? t.error : t.success)
                Text(failed ? "exit \(run.exitCode ?? 0)" : Self.duration(run.duration ?? 0))
                    .font(.system(size: fontScale.size(.xs), design: .monospaced))
                    .foregroundStyle(t.textTertiary)
            }
            .help("\(failed ? "Failed" : "Passed") \(run.startedAt.formatted(.relative(presentation: .named)))")
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m \(Int(seconds) % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
