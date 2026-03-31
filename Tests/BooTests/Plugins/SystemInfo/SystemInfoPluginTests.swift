import XCTest

@testable import Boo

@MainActor
final class SystemInfoPluginTests: XCTestCase {
    private struct StubShellService: ShellService {
        func run(executable: String, arguments: [String], cwd: String?) async throws -> String { "" }
    }

    private struct StubSystemInfoService: SystemInfoService {
        var memoryUsageValue: Double = 0.42
        var memoryUsedGBValue: Double = 6.5
        var memoryTotalGBValue: Double = 16
        var diskUsageValue: Double = 0.55
        var diskFreeGBValue: Double = 120
        var loadAverageValue: Double = 1.25
        var cpuUsageValue: Double = 0.37
        var uptimeValue: TimeInterval = 7200
        var networkInValue: UInt64 = 0
        var networkOutValue: UInt64 = 0
        var batteryValue: BatteryInfo? = nil

        func memoryUsage() -> Double { memoryUsageValue }
        func memoryTotals() -> (usedGB: Double, totalGB: Double) { (memoryUsedGBValue, memoryTotalGBValue) }
        func diskUsage() -> (usage: Double, freeGB: Double) { (diskUsageValue, diskFreeGBValue) }
        func loadAverage() -> Double { loadAverageValue }
        func cpuUsage() -> Double { cpuUsageValue }
        func uptime() -> TimeInterval { uptimeValue }
        func networkThroughput() -> (bytesIn: UInt64, bytesOut: UInt64) { (networkInValue, networkOutValue) }
        func batteryInfo() -> BatteryInfo? { batteryValue }
    }

    private final class StubPluginServices: PluginServices {
        let shell: ShellService = StubShellService()
        let system: SystemInfoService

        init(system: SystemInfoService) {
            self.system = system
        }
    }

    private func makePluginContext(terminal: TerminalContext) -> PluginContext {
        PluginContext(
            terminal: terminal,
            theme: ThemeSnapshot(from: AppSettings.shared.theme),
            density: .comfortable,
            settings: PluginSettingsReader(pluginID: "system-info")
        )
    }

    func testHiddenInRemoteSession() {
        let plugin = SystemInfoPlugin()

        let remoteContext = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: .ssh(host: "server"),
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        XCTAssertFalse(
            plugin.isVisible(for: remoteContext),
            "System info should be hidden in remote sessions")
    }

    func testVisibleLocally() {
        let plugin = SystemInfoPlugin()

        let localContext = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        XCTAssertTrue(
            plugin.isVisible(for: localContext),
            "System info should be visible in local sessions")
    }

    func testStatusBarContent() {
        let plugin = SystemInfoPlugin()
        let terminal = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let ctx = makePluginContext(terminal: terminal)

        let content = plugin.makeStatusBarContent(context: ctx)
        XCTAssertNotNil(content)
        XCTAssertTrue(content!.text.hasPrefix("Mem "))
        XCTAssertEqual(content!.icon, "memorychip")
    }

    func testSectionTitle() {
        let plugin = SystemInfoPlugin()
        let terminal = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let ctx = makePluginContext(terminal: terminal)

        let title = plugin.sectionTitle(context: ctx)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.hasPrefix("System ("))
    }

    func testCwdChangeRefreshesDisplayedMetrics() {
        let plugin = SystemInfoPlugin()
        plugin.services = StubPluginServices(system: StubSystemInfoService())
        let terminal = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let ctx = makePluginContext(terminal: terminal)
        plugin.cwdChanged(newPath: terminal.cwd, context: terminal)

        XCTAssertEqual(plugin.makeStatusBarContent(context: ctx)?.text, "Mem 42%")
        XCTAssertEqual(plugin.sectionTitle(context: ctx), "System (CPU 37% / Mem 42%)")
    }

    func testNewMetricsPopulated() {
        let plugin = SystemInfoPlugin()
        // CPU usage should be 0.0-1.0
        XCTAssertGreaterThanOrEqual(plugin.cpuUsage, 0)
        XCTAssertLessThanOrEqual(plugin.cpuUsage, 1)
        // Memory totals should be positive
        XCTAssertGreaterThan(plugin.memoryTotalGB, 0)
        XCTAssertGreaterThanOrEqual(plugin.memoryUsedGB, 0)
        // Uptime should be positive
        XCTAssertGreaterThan(plugin.uptimeSeconds, 0)
    }

    func testSectionTitleIncludesCPU() {
        let plugin = SystemInfoPlugin()
        let terminal = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let ctx = makePluginContext(terminal: terminal)
        let title = plugin.sectionTitle(context: ctx)!
        XCTAssertTrue(title.contains("CPU"), "Section title should include CPU info")
        XCTAssertTrue(title.contains("Mem"), "Section title should include Mem info")
    }

    func testManifestHasNewSettings() {
        let plugin = SystemInfoPlugin()
        let settingKeys = (plugin.manifest.settings ?? []).map(\.key)
        XCTAssertTrue(settingKeys.contains("statusBarCPU"))
        XCTAssertTrue(settingKeys.contains("statusBarBattery"))
    }

    func testRegisteredInBuiltins() {
        let registry = PluginRegistry()
        registry.registerBuiltins()
        XCTAssertNotNil(
            registry.plugin(for: "system-info"),
            "SystemInfoPlugin should be registered in builtins")
    }
}
