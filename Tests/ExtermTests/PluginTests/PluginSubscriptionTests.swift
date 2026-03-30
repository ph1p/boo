import XCTest

@testable import Exterm

// MARK: - Mock Plugins for Subscription Testing

@MainActor
private final class CwdOnlyPlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "test-cwd-only", name: "CWD Only", version: "1.0.0", icon: "folder",
        description: nil, when: nil, runtime: nil, capabilities: nil, statusBar: nil, settings: nil)
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var subscribedEvents: Set<PluginEvent> { [.cwdChanged] }

    var cwdCallCount = 0
    var focusCallCount = 0
    var processCallCount = 0

    func cwdChanged(newPath: String, context: TerminalContext) { cwdCallCount += 1 }
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) { focusCallCount += 1 }
    func processChanged(name: String, context: TerminalContext) { processCallCount += 1 }
}

@MainActor
private final class NoEventsPlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "test-no-events", name: "Silent", version: "1.0.0", icon: "moon",
        description: nil, when: nil, runtime: nil, capabilities: nil, statusBar: nil, settings: nil)
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var subscribedEvents: Set<PluginEvent> { [] }

    var anyCallCount = 0

    func cwdChanged(newPath: String, context: TerminalContext) { anyCallCount += 1 }
    func processChanged(name: String, context: TerminalContext) { anyCallCount += 1 }
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) { anyCallCount += 1 }
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) { anyCallCount += 1 }
    func terminalCreated(terminalID: UUID) { anyCallCount += 1 }
    func terminalClosed(terminalID: UUID) { anyCallCount += 1 }
    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) { anyCallCount += 1 }
}

@MainActor
private final class AllEventsPlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "test-all-events", name: "All", version: "1.0.0", icon: "star",
        description: nil, when: nil, runtime: nil, capabilities: nil, statusBar: nil, settings: nil)
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var subscribedEvents: Set<PluginEvent> {
        [.cwdChanged, .processChanged, .remoteSessionChanged, .focusChanged,
         .terminalCreated, .terminalClosed, .remoteDirectoryListed]
    }

    var events: [String] = []

    func cwdChanged(newPath: String, context: TerminalContext) { events.append("cwd") }
    func processChanged(name: String, context: TerminalContext) { events.append("process") }
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) { events.append("remote") }
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) { events.append("focus") }
    func terminalCreated(terminalID: UUID) { events.append("created") }
    func terminalClosed(terminalID: UUID) { events.append("closed") }
    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) { events.append("listing") }
}

@MainActor
private final class ProcessAndRemotePlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "test-proc-remote", name: "ProcRemote", version: "1.0.0", icon: "globe",
        description: nil, when: nil, runtime: nil, capabilities: nil, statusBar: nil, settings: nil)
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var subscribedEvents: Set<PluginEvent> { [.processChanged, .remoteSessionChanged] }

    var processCallCount = 0
    var remoteCallCount = 0
    var cwdCallCount = 0

    func processChanged(name: String, context: TerminalContext) { processCallCount += 1 }
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) { remoteCallCount += 1 }
    func cwdChanged(newPath: String, context: TerminalContext) { cwdCallCount += 1 }
}

// MARK: - Tests

@MainActor
final class PluginSubscriptionTests: XCTestCase {

    private func makeContext() -> TerminalContext {
        TerminalContext(
            terminalID: UUID(), cwd: "/tmp", remoteSession: nil,
            gitContext: nil, processName: "", paneCount: 1, tabCount: 1)
    }

    // MARK: - Basic Subscription Filtering

    func testCwdOnlyPluginReceivesOnlyCwd() {
        let registry = PluginRegistry()
        let plugin = CwdOnlyPlugin()
        registry.register(plugin)

        let ctx = makeContext()
        registry.notifyCwdChanged(newPath: "/test", context: ctx)
        registry.notifyProcessChanged(name: "vim", context: ctx)
        registry.notifyFocusChanged(terminalID: UUID(), context: ctx)

        XCTAssertEqual(plugin.cwdCallCount, 1)
        XCTAssertEqual(plugin.processCallCount, 0, "Should not receive process events")
        XCTAssertEqual(plugin.focusCallCount, 0, "Should not receive focus events")
    }

    func testNoEventsPluginReceivesNothing() {
        let registry = PluginRegistry()
        let plugin = NoEventsPlugin()
        registry.register(plugin)

        let ctx = makeContext()
        registry.notifyCwdChanged(newPath: "/a", context: ctx)
        registry.notifyProcessChanged(name: "vim", context: ctx)
        registry.notifyRemoteSessionChanged(session: .ssh(host: "h"), context: ctx)
        registry.notifyFocusChanged(terminalID: UUID(), context: ctx)
        registry.notifyTerminalCreated(terminalID: UUID())
        registry.notifyTerminalClosed(terminalID: UUID())
        registry.notifyRemoteDirectoryListed(path: "/", entries: [])

        XCTAssertEqual(plugin.anyCallCount, 0, "Plugin with empty subscriptions should receive nothing")
    }

    func testAllEventsPluginReceivesEverything() {
        let registry = PluginRegistry()
        let plugin = AllEventsPlugin()
        registry.register(plugin)

        let ctx = makeContext()
        registry.notifyCwdChanged(newPath: "/a", context: ctx)
        registry.notifyProcessChanged(name: "vim", context: ctx)
        registry.notifyRemoteSessionChanged(session: nil, context: ctx)
        registry.notifyFocusChanged(terminalID: UUID(), context: ctx)
        registry.notifyTerminalCreated(terminalID: UUID())
        registry.notifyTerminalClosed(terminalID: UUID())
        registry.notifyRemoteDirectoryListed(path: "/", entries: [])

        XCTAssertEqual(plugin.events, ["cwd", "process", "remote", "focus", "created", "closed", "listing"])
    }

    func testProcessAndRemotePluginFiltersCorrectly() {
        let registry = PluginRegistry()
        let plugin = ProcessAndRemotePlugin()
        registry.register(plugin)

        let ctx = makeContext()
        registry.notifyCwdChanged(newPath: "/a", context: ctx)
        registry.notifyProcessChanged(name: "vim", context: ctx)
        registry.notifyRemoteSessionChanged(session: .ssh(host: "h"), context: ctx)
        registry.notifyFocusChanged(terminalID: UUID(), context: ctx)

        XCTAssertEqual(plugin.processCallCount, 1)
        XCTAssertEqual(plugin.remoteCallCount, 1)
        XCTAssertEqual(plugin.cwdCallCount, 0, "Not subscribed to cwd")
    }

    // MARK: - Multiple Plugins Mixed Subscriptions

    func testMixedSubscriptionsDeliverCorrectly() {
        let registry = PluginRegistry()
        let cwdPlugin = CwdOnlyPlugin()
        let allPlugin = AllEventsPlugin()
        let noPlugin = NoEventsPlugin()
        registry.register(cwdPlugin)
        registry.register(allPlugin)
        registry.register(noPlugin)

        let ctx = makeContext()
        registry.notifyCwdChanged(newPath: "/test", context: ctx)
        registry.notifyProcessChanged(name: "node", context: ctx)

        XCTAssertEqual(cwdPlugin.cwdCallCount, 1)
        XCTAssertEqual(cwdPlugin.processCallCount, 0)
        XCTAssertEqual(allPlugin.events, ["cwd", "process"])
        XCTAssertEqual(noPlugin.anyCallCount, 0)
    }

    // MARK: - Built-in Plugin Subscriptions

    func testBuiltinPluginSubscriptions() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        // Verify each built-in plugin has narrowed subscriptions (not all default)
        let git = registry.plugin(for: "git-panel")!
        XCTAssertTrue(git.subscribedEvents.contains(.cwdChanged))
        XCTAssertTrue(git.subscribedEvents.contains(.focusChanged))
        XCTAssertFalse(git.subscribedEvents.contains(.processChanged), "Git doesn't need process events")
        XCTAssertFalse(git.subscribedEvents.contains(.remoteDirectoryListed))

        let aiAgent = registry.plugin(for: "ai-agent")!
        XCTAssertTrue(aiAgent.subscribedEvents.contains(.processChanged))
        XCTAssertTrue(aiAgent.subscribedEvents.contains(.cwdChanged))
        XCTAssertTrue(aiAgent.subscribedEvents.contains(.focusChanged))
        XCTAssertFalse(aiAgent.subscribedEvents.contains(.remoteDirectoryListed))

        let bookmarks = registry.plugin(for: "bookmarks")!
        XCTAssertTrue(bookmarks.subscribedEvents.isEmpty, "Bookmarks has no lifecycle callbacks")

        let docker = registry.plugin(for: "docker")!
        XCTAssertTrue(docker.subscribedEvents.isEmpty, "Docker has no lifecycle callbacks")

        let debug = registry.plugin(for: "debug")!
        XCTAssertEqual(debug.subscribedEvents.count, 7, "Debug subscribes to all events")

        let remote = registry.plugin(for: "file-tree-remote")!
        XCTAssertTrue(remote.subscribedEvents.contains(.processChanged))
        XCTAssertTrue(remote.subscribedEvents.contains(.remoteDirectoryListed))
        XCTAssertFalse(remote.subscribedEvents.contains(.cwdChanged))

        let sysInfo = registry.plugin(for: "system-info")!
        XCTAssertTrue(sysInfo.subscribedEvents.contains(.cwdChanged))
        XCTAssertTrue(sysInfo.subscribedEvents.contains(.focusChanged))
        XCTAssertFalse(sysInfo.subscribedEvents.contains(.processChanged))
    }

    // MARK: - Subscription Prevents Unnecessary Work

    func testFocusFloodOnlyHitsSubscribers() {
        let registry = PluginRegistry()
        let cwdPlugin = CwdOnlyPlugin()
        let allPlugin = AllEventsPlugin()
        registry.register(cwdPlugin)
        registry.register(allPlugin)

        let ctx = makeContext()
        // Simulate 100 rapid focus events (like the sidebar rebuild loop)
        for _ in 0..<100 {
            registry.notifyFocusChanged(terminalID: UUID(), context: ctx)
        }

        XCTAssertEqual(cwdPlugin.focusCallCount, 0, "CWD-only plugin should not be called")
        XCTAssertEqual(allPlugin.events.filter { $0 == "focus" }.count, 100)
    }

    func testProcessFloodOnlyHitsSubscribers() {
        let registry = PluginRegistry()
        let cwdPlugin = CwdOnlyPlugin()
        let procPlugin = ProcessAndRemotePlugin()
        registry.register(cwdPlugin)
        registry.register(procPlugin)

        let ctx = makeContext()
        for i in 0..<50 {
            registry.notifyProcessChanged(name: "process-\(i)", context: ctx)
        }

        XCTAssertEqual(cwdPlugin.processCallCount, 0)
        XCTAssertEqual(procPlugin.processCallCount, 50)
    }
}
