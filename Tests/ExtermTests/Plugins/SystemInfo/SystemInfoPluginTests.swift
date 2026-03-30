import XCTest

@testable import Exterm

@MainActor
final class SystemInfoPluginTests: XCTestCase {

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

    func testDetailView() {
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

        let view = plugin.makeDetailView(context: ctx)
        XCTAssertNotNil(view, "Detail view should be returned for local context")
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
