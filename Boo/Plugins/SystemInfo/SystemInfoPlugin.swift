import SwiftUI

/// Built-in plugin showing system resource usage (CPU, memory, disk, network, battery).
@MainActor
final class SystemInfoPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices? {
        didSet { model.service = services?.system ?? HostSystemInfoService() }
    }
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
                key: "statusBarCPU", type: .bool, label: "CPU",
                defaultValue: AnyCodableValue(false), options: nil, group: "Status Bar"),
            PluginManifest.SettingManifest(
                key: "statusBarMemory", type: .bool, label: "Memory",
                defaultValue: AnyCodableValue(false), options: nil, group: "Status Bar"),
            PluginManifest.SettingManifest(
                key: "statusBarDisk", type: .bool, label: "Disk",
                defaultValue: AnyCodableValue(false), options: nil, group: "Status Bar"),
            PluginManifest.SettingManifest(
                key: "statusBarBattery", type: .bool, label: "Battery",
                description: "The segment appears once one of these is on.",
                defaultValue: AnyCodableValue(false), options: nil, group: "Status Bar")
        ]
    )

    var subscribedEvents: Set<PluginEvent> { [.cwdChanged, .focusChanged] }

    // MARK: - Metrics

    /// Samples the metrics; the sidebar panel observes it for live updates.
    let model = SystemInfoModel()

    var memoryUsage: Double { model.state.memoryUsage }
    var memoryUsedGB: Double { model.state.memoryUsedGB }
    var memoryTotalGB: Double { model.state.memoryTotalGB }
    var diskFreeGB: Double { model.state.diskFreeGB }
    var cpuUsage: Double { model.state.cpuUsage }
    var uptimeSeconds: TimeInterval { model.state.uptimeSeconds }
    var battery: BatteryInfo? { model.state.battery }

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
            SystemInfoPanelView(
                model: model,
                theme: context.theme.source,
                fontScale: context.fontScale,
                run: { command in
                    act?.handle(DSLAction(type: "exec", path: nil, command: command, text: nil))
                }
            )
        )
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        model.refresh()
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        model.refresh()
    }
}
