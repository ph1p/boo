import XCTest

@testable import Exterm

@MainActor
final class SystemInfoPluginTests: XCTestCase {

    func testManifest() {
        let plugin = SystemInfoPlugin()
        XCTAssertEqual(plugin.pluginID, "system-info")
        XCTAssertEqual(plugin.manifest.id, "system-info")
        XCTAssertEqual(plugin.manifest.name, "System")
        XCTAssertEqual(plugin.manifest.icon, "gauge.with.dots.needle.33percent")
        XCTAssertEqual(plugin.manifest.when, "!remote")
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
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        let content = plugin.makeStatusBarContent(context: context)
        XCTAssertNotNil(content)
        XCTAssertTrue(content!.text.hasPrefix("Mem "))
        XCTAssertEqual(content!.icon, "memorychip")
    }

    func testSectionTitle() {
        let plugin = SystemInfoPlugin()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        let title = plugin.sectionTitle(context: context)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.hasPrefix("System ("))
    }

    func testDetailView() {
        let plugin = SystemInfoPlugin()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        let view = plugin.makeDetailView(context: context, actionHandler: DSLActionHandler())
        XCTAssertNotNil(view, "Detail view should be returned for local context")
    }

    func testRegisteredInBuiltins() {
        let registry = PluginRegistry()
        registry.registerBuiltins()
        XCTAssertNotNil(
            registry.plugin(for: "system-info"),
            "SystemInfoPlugin should be registered in builtins")
    }
}
