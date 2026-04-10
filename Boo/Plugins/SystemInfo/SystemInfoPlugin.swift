import SwiftUI

/// Built-in plugin showing system resource usage (CPU, memory, disk, network, battery).
@MainActor
final class SystemInfoPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
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
        capabilities: PluginManifest.Capabilities(statusBarSegment: true, sidebarTab: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 35, template: nil),
        settings: [
            PluginManifest.SettingManifest(
                key: "statusBarMemory", type: .bool, label: "Show memory in status bar",
                defaultValue: AnyCodableValue(false), options: nil),
            PluginManifest.SettingManifest(
                key: "statusBarDisk", type: .bool, label: "Show disk in status bar",
                defaultValue: AnyCodableValue(false), options: nil),
            PluginManifest.SettingManifest(
                key: "statusBarCPU", type: .bool, label: "Show CPU in status bar",
                defaultValue: AnyCodableValue(false), options: nil),
            PluginManifest.SettingManifest(
                key: "statusBarBattery", type: .bool, label: "Show battery in status bar",
                defaultValue: AnyCodableValue(false), options: nil)
        ]
    )

    var subscribedEvents: Set<PluginEvent> { [.cwdChanged, .focusChanged] }

    // MARK: - Cached State

    private(set) var memoryUsage: Double = 0  // 0.0-1.0
    private(set) var memoryUsedGB: Double = 0
    private(set) var memoryTotalGB: Double = 0
    private(set) var diskUsage: Double = 0  // 0.0-1.0
    private(set) var diskFreeGB: Double = 0
    private(set) var loadAverage: Double = 0
    private(set) var cpuUsage: Double = 0  // 0.0-1.0
    private(set) var uptimeSeconds: TimeInterval = 0
    private(set) var battery: BatteryInfo?
    private(set) var networkBytesIn: UInt64 = 0
    private(set) var networkBytesOut: UInt64 = 0

    // For computing network rate (delta between refreshes)
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private(set) var netRateIn: UInt64 = 0  // bytes/sec
    private(set) var netRateOut: UInt64 = 0  // bytes/sec
    private var lastRefreshTime: Date?

    init() {
        refresh()
    }

    // MARK: - Data Collection

    private func refresh() {
        let sys: SystemInfoService = services?.system ?? HostSystemInfoService()

        memoryUsage = sys.memoryUsage()
        let totals = sys.memoryTotals()
        memoryUsedGB = totals.usedGB
        memoryTotalGB = totals.totalGB
        (diskUsage, diskFreeGB) = sys.diskUsage()
        loadAverage = sys.loadAverage()
        cpuUsage = sys.cpuUsage()
        uptimeSeconds = sys.uptime()
        battery = sys.batteryInfo()

        let net = sys.networkThroughput()
        let now = Date()
        if let prev = lastRefreshTime {
            let elapsed = now.timeIntervalSince(prev)
            if elapsed > 0 {
                let deltaIn = net.bytesIn >= prevNetIn ? net.bytesIn - prevNetIn : 0
                let deltaOut = net.bytesOut >= prevNetOut ? net.bytesOut - prevNetOut : 0
                let rateIn = Double(deltaIn) / elapsed
                let rateOut = Double(deltaOut) / elapsed
                netRateIn = rateIn.isFinite ? UInt64(min(rateIn, Double(UInt64.max))) : 0
                netRateOut = rateOut.isFinite ? UInt64(min(rateOut, Double(UInt64.max))) : 0
            }
        }
        prevNetIn = net.bytesIn
        prevNetOut = net.bytesOut
        networkBytesIn = net.bytesIn
        networkBytesOut = net.bytesOut
        lastRefreshTime = now
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
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

    func sectionTitle(context: PluginContext) -> String? {
        let memPct = Int(memoryUsage * 100)
        let cpuPct = Int(cpuUsage * 100)
        return "System (CPU \(cpuPct)% / Mem \(memPct)%)"
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        let act = actions

        return AnyView(
            SystemInfoDetailView(
                cpuUsage: cpuUsage,
                memoryUsage: memoryUsage,
                memoryUsedGB: memoryUsedGB,
                memoryTotalGB: memoryTotalGB,
                diskUsage: diskUsage,
                diskFreeGB: diskFreeGB,
                loadAverage: loadAverage,
                uptimeSeconds: uptimeSeconds,
                battery: battery,
                netRateIn: netRateIn,
                netRateOut: netRateOut,
                cwd: context.terminal.cwd,
                fontScale: context.fontScale,
                textColor: Color(nsColor: context.theme.chromeText),
                mutedColor: Color(nsColor: context.theme.chromeMuted),
                onDiskUsage: {
                    act?.handle(DSLAction(type: "exec", path: nil, command: "df -h", text: nil))
                },
                onTopProcesses: {
                    act?.handle(
                        DSLAction(
                            type: "exec", path: nil, command: "top -l 1 -n 10 -stats pid,command,cpu,mem",
                            text: nil))
                },
                onNetworkInfo: {
                    act?.handle(
                        DSLAction(
                            type: "exec", path: nil, command: "netstat -ib", text: nil))
                },
                onUptimeInfo: {
                    act?.handle(
                        DSLAction(
                            type: "exec", path: nil, command: "uptime", text: nil))
                }
            )
        )
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        refresh()
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        refresh()
    }
}

// MARK: - Formatting Helpers

private func formatBytes(_ bytes: UInt64) -> String {
    if bytes < 1024 { return "\(bytes) B/s" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.1f KB/s", kb) }
    let mb = kb / 1024
    return String(format: "%.1f MB/s", mb)
}

private func formatUptime(_ seconds: TimeInterval) -> String {
    let days = Int(seconds) / 86400
    let hours = (Int(seconds) % 86400) / 3600
    let mins = (Int(seconds) % 3600) / 60
    if days > 0 {
        return "\(days)d \(hours)h \(mins)m"
    } else if hours > 0 {
        return "\(hours)h \(mins)m"
    } else {
        return "\(mins)m"
    }
}

// MARK: - Detail View

private struct SystemInfoDetailView: View {
    let cpuUsage: Double
    let memoryUsage: Double
    let memoryUsedGB: Double
    let memoryTotalGB: Double
    let diskUsage: Double
    let diskFreeGB: Double
    let loadAverage: Double
    let uptimeSeconds: TimeInterval
    let battery: BatteryInfo?
    let netRateIn: UInt64
    let netRateOut: UInt64
    let cwd: String
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let onDiskUsage: () -> Void
    let onTopProcesses: () -> Void
    let onNetworkInfo: () -> Void
    let onUptimeInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // CPU
            ResourceRow(
                label: "CPU",
                value: "\(Int(cpuUsage * 100))%",
                ratio: cpuUsage,
                barColor: barColor(for: cpuUsage),
                fontScale: fontScale,
                textColor: textColor,
                mutedColor: mutedColor
            )

            // Memory
            ResourceRow(
                label: "Memory",
                value: String(format: "%.1f / %.0f GB", memoryUsedGB, memoryTotalGB),
                ratio: memoryUsage,
                barColor: barColor(for: memoryUsage),
                fontScale: fontScale,
                textColor: textColor,
                mutedColor: mutedColor
            )

            // Disk
            ResourceRow(
                label: "Disk",
                value: String(format: "%.1f GB free", diskFreeGB),
                ratio: diskUsage,
                barColor: barColor(for: diskUsage),
                fontScale: fontScale,
                textColor: textColor,
                mutedColor: mutedColor
            )

            // Battery (if present)
            if let bat = battery {
                ResourceRow(
                    label: bat.isCharging ? "Battery (charging)" : (bat.isPluggedIn ? "Battery (plugged)" : "Battery"),
                    value: "\(Int(bat.level * 100))%",
                    ratio: bat.level,
                    barColor: batteryColor(for: bat),
                    fontScale: fontScale,
                    textColor: textColor,
                    mutedColor: mutedColor
                )
            }

            Divider().opacity(0.3)

            // Load + Uptime + Network in compact rows
            HStack {
                Text("Load avg")
                    .font(fontScale.font(.base))
                    .foregroundColor(mutedColor)
                Spacer()
                Text(String(format: "%.2f", loadAverage))
                    .font(fontScale.font(.base, design: .monospaced))
                    .foregroundColor(textColor)
            }

            HStack {
                Text("Uptime")
                    .font(fontScale.font(.base))
                    .foregroundColor(mutedColor)
                Spacer()
                Text(formatUptime(uptimeSeconds))
                    .font(fontScale.font(.base, design: .monospaced))
                    .foregroundColor(textColor)
            }

            HStack {
                Text("Network")
                    .font(fontScale.font(.base))
                    .foregroundColor(mutedColor)
                Spacer()
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(fontScale.font(.xs))
                            .foregroundColor(mutedColor)
                        Text(formatBytes(netRateIn))
                            .font(fontScale.font(.base, design: .monospaced))
                            .foregroundColor(textColor)
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(fontScale.font(.xs))
                            .foregroundColor(mutedColor)
                        Text(formatBytes(netRateOut))
                            .font(fontScale.font(.base, design: .monospaced))
                            .foregroundColor(textColor)
                    }
                }
            }

            Divider().opacity(0.3)

            // Quick actions
            HStack(spacing: 6) {
                QuickActionButton(label: "df -h", fontScale: fontScale, color: mutedColor, action: onDiskUsage)
                QuickActionButton(label: "top", fontScale: fontScale, color: mutedColor, action: onTopProcesses)
                QuickActionButton(label: "netstat", fontScale: fontScale, color: mutedColor, action: onNetworkInfo)
                QuickActionButton(label: "uptime", fontScale: fontScale, color: mutedColor, action: onUptimeInfo)
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

    private func batteryColor(for bat: BatteryInfo) -> Color {
        if bat.isCharging { return Color(nsColor: .systemGreen) }
        if bat.level < 0.15 { return Color(nsColor: .systemRed) }
        if bat.level < 0.3 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemGreen)
    }
}

private struct QuickActionButton: View {
    let label: String
    let fontScale: SidebarFontScale
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(label) { action() }
            .buttonStyle(.plain)
            .font(fontScale.font(.sm))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(3)
    }
}

private struct ResourceRow: View {
    let label: String
    let value: String
    let ratio: Double
    let barColor: Color
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(fontScale.font(.base))
                    .foregroundColor(mutedColor)
                Spacer()
                Text(value)
                    .font(fontScale.font(.base, design: .monospaced))
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
