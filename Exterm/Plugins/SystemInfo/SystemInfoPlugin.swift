import SwiftUI

/// Example built-in plugin demonstrating the ExtermPluginProtocol patterns.
///
/// Shows system resource usage (CPU load, memory, disk) in the sidebar
/// and a compact summary in the status bar. Refreshes every 10 seconds
/// via a background timer calling `onRequestCycleRerun`.
///
/// This plugin demonstrates:
/// - Manifest declaration with when-clause (`!remote` — hidden in SSH/Docker)
/// - Status bar content via `makeStatusBarContent`
/// - Sidebar detail view via `makeDetailView` using SwiftUI
/// - Dynamic section title via `sectionTitle`
/// - Background refresh via `onRequestCycleRerun`
/// - Host actions for terminal interaction
/// - Lifecycle callback (`cwdChanged`) for context-aware behavior
@MainActor
final class SystemInfoPlugin: ExtermPluginProtocol {
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "system-info",
        name: "System",
        version: "1.0.0",
        icon: "gauge.with.dots.needle.33percent",
        description: "System resource usage (CPU, memory, disk)",
        when: "!remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 35, template: nil),
        settings: nil
    )

    // MARK: - Cached State

    private var memoryUsage: Double = 0  // 0.0–1.0
    private var diskUsage: Double = 0  // 0.0–1.0
    private var diskFreeGB: Double = 0
    private var loadAverage: Double = 0
    private var refreshTimer: Timer?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.onRequestCycleRerun?()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Data Collection

    private func refresh() {
        memoryUsage = Self.getMemoryUsage()
        (diskUsage, diskFreeGB) = Self.getDiskUsage()
        loadAverage = Self.getLoadAverage()
    }

    private static func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return min(1, (active + wired + compressed) / total)
    }

    private static func getDiskUsage() -> (usage: Double, freeGB: Double) {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            )
        else { return (0, 0) }
        let total = (attrs[.systemSize] as? Int64) ?? 0
        let free = (attrs[.systemFreeSize] as? Int64) ?? 0
        guard total > 0 else { return (0, 0) }
        let usage = 1.0 - Double(free) / Double(total)
        let freeGB = Double(free) / 1_073_741_824
        return (usage, freeGB)
    }

    private static func getLoadAverage() -> Double {
        var loadavg = [Double](repeating: 0, count: 3)
        getloadavg(&loadavg, 3)
        return loadavg[0]
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? {
        let memPct = Int(memoryUsage * 100)
        let tint: DSLTint? = memoryUsage > 0.85 ? .error : (memoryUsage > 0.7 ? .warning : nil)
        return StatusBarContent(
            text: "Mem \(memPct)%",
            icon: "memorychip",
            tint: tint,
            accessibilityLabel: "Memory usage: \(memPct) percent"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: TerminalContext) -> String? {
        let memPct = Int(memoryUsage * 100)
        return "System (\(memPct)% mem)"
    }

    // MARK: - Detail View

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? {
        let theme = AppSettings.shared.theme
        let density = AppSettings.shared.sidebarDensity
        let fontSize = density == .compact ? 10.0 : 11.0

        return AnyView(
            SystemInfoDetailView(
                memoryUsage: memoryUsage,
                diskUsage: diskUsage,
                diskFreeGB: diskFreeGB,
                loadAverage: loadAverage,
                cwd: context.cwd,
                fontSize: fontSize,
                textColor: Color(nsColor: theme.chromeText),
                mutedColor: Color(nsColor: theme.chromeMuted),
                onDiskUsage: {
                    actionHandler.handle(DSLAction(type: "exec", path: nil, command: "df -h", text: nil))
                },
                onTopProcesses: {
                    actionHandler.handle(
                        DSLAction(
                            type: "exec", path: nil, command: "top -l 1 -n 10 -stats pid,command,cpu,mem", text: nil))
                }
            )
        )
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        // Refresh disk usage when directory changes (might be a different volume)
        (diskUsage, diskFreeGB) = Self.getDiskUsage()
    }
}

// MARK: - Detail View

private struct SystemInfoDetailView: View {
    let memoryUsage: Double
    let diskUsage: Double
    let diskFreeGB: Double
    let loadAverage: Double
    let cwd: String
    let fontSize: CGFloat
    let textColor: Color
    let mutedColor: Color
    let onDiskUsage: () -> Void
    let onTopProcesses: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ResourceRow(
                label: "Memory",
                value: "\(Int(memoryUsage * 100))%",
                ratio: memoryUsage,
                barColor: barColor(for: memoryUsage),
                fontSize: fontSize,
                textColor: textColor,
                mutedColor: mutedColor
            )

            ResourceRow(
                label: "Disk",
                value: String(format: "%.1f GB free", diskFreeGB),
                ratio: diskUsage,
                barColor: barColor(for: diskUsage),
                fontSize: fontSize,
                textColor: textColor,
                mutedColor: mutedColor
            )

            HStack {
                Text("Load avg")
                    .font(.system(size: fontSize))
                    .foregroundColor(mutedColor)
                Spacer()
                Text(String(format: "%.2f", loadAverage))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(textColor)
            }

            Divider().opacity(0.3)

            HStack(spacing: 6) {
                Button("df -h") { onDiskUsage() }
                    .buttonStyle(.plain)
                    .font(.system(size: fontSize - 1))
                    .foregroundColor(mutedColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(mutedColor.opacity(0.1))
                    .cornerRadius(3)

                Button("top") { onTopProcesses() }
                    .buttonStyle(.plain)
                    .font(.system(size: fontSize - 1))
                    .foregroundColor(mutedColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(mutedColor.opacity(0.1))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func barColor(for value: Double) -> Color {
        if value > 0.85 { return Color(nsColor: .systemRed) }
        if value > 0.7 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemGreen)
    }
}

private struct ResourceRow: View {
    let label: String
    let value: String
    let ratio: Double
    let barColor: Color
    let fontSize: CGFloat
    let textColor: Color
    let mutedColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: fontSize))
                    .foregroundColor(mutedColor)
                Spacer()
                Text(value)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(textColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(mutedColor.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(1, ratio)), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

}
