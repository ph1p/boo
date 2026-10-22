import AppKit

/// Listening ports of processes started in the active workspace.
final class PortsSegment: StatusBarPlugin {
    let id = "ports"
    let position: StatusBarPosition = .right
    let priority = 55
    var hitRect: NSRect = .zero
    /// Retained while the menu is open (menu items hold their target weakly).
    private var menuTarget: PortsMenuTarget?

    init() {
        MainActor.assumeIsolated { PortMonitor.shared.start() }
    }

    var tooltipText: String? { "Listening ports — click for actions" }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowPorts && MainActor.assumeIsolated { !PortMonitor.shared.servers.isEmpty }
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let label = MainActor.assumeIsolated { PortMonitor.label(for: PortMonitor.shared.servers) }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: theme.textSecondary
        ]
        hitRect = Self.drawLabel(label, attrs: attrs, endingAt: rx, y: y)
        return hitRect.width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        MainActor.assumeIsolated {
            let target = menuTarget ?? PortsMenuTarget()
            menuTarget = target
            target.makeMenu(PortMonitor.shared.servers)
                .popUp(positioning: nil, at: NSPoint(x: hitRect.minX, y: 0), in: barView)
        }
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        MainActor.assumeIsolated {
            let ports = PortMonitor.shared.servers.map { String($0.port) }
            return "Listening ports: " + ports.joined(separator: ", ")
        }
    }
}

/// Builds the ports menu and handles picks.
@MainActor
final class PortsMenuTarget: NSObject {
    func makeMenu(_ servers: [PaneServer]) -> NSMenu {
        let menu = NSMenu()
        for server in servers {
            let uptime = server.startedAt.map { " · up " + formatCompactAge($0) } ?? ""
            let item = NSMenuItem(
                title: "\(server.hostLabel)  \(server.detail)\(uptime)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(entry("Open in Browser Tab", #selector(openTab(_:)), server))
            submenu.addItem(entry("Open in Default Browser", #selector(openExternal(_:)), server))
            submenu.addItem(entry("Copy URL", #selector(copyURL(_:)), server))
            if server.tabID != nil {
                submenu.addItem(entry("Go to Pane", #selector(jump(_:)), server))
            }
            submenu.addItem(.separator())
            submenu.addItem(entry("Stop (SIGTERM)", #selector(stop(_:)), server))
            submenu.addItem(entry("Force Kill…", #selector(forceKill(_:)), server))
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private func entry(_ title: String, _ action: Selector, _ server: PaneServer) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = Box(server)
        return item
    }

    private final class Box: NSObject {
        let server: PaneServer
        init(_ server: PaneServer) { self.server = server }
    }

    private func server(_ sender: NSMenuItem) -> PaneServer? { (sender.representedObject as? Box)?.server }

    @objc func openTab(_ sender: NSMenuItem) {
        guard let server = server(sender) else { return }
        WindowManager.shared.activeController?.handleOpenTab(.browser(url: server.url))
    }

    @objc func openExternal(_ sender: NSMenuItem) {
        guard let server = server(sender) else { return }
        NSWorkspace.shared.open(server.url)
    }

    @objc func copyURL(_ sender: NSMenuItem) {
        guard let server = server(sender) else { return }
        PluginActions.copyToPasteboard(server.url.absoluteString)
    }

    @objc func jump(_ sender: NSMenuItem) {
        guard let server = server(sender) else { return }
        PortMonitor.shared.jump(to: server)
    }

    @objc func stop(_ sender: NSMenuItem) {
        guard let server = server(sender) else { return }
        PortMonitor.shared.stop(server, force: false)
    }

    @objc func forceKill(_ sender: NSMenuItem) {
        guard let server = server(sender) else { return }
        PortMonitor.shared.stop(server, force: true)
    }
}
