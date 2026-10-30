import AppKit

/// "⎈ context/namespace" while the Kube plugin is enabled; red when a rule
/// switches profile for the context. Click to switch context or namespace.
final class KubeSegment: StatusBarPlugin {
    let id = "kube"
    let position: StatusBarPosition = .right
    let priority = 54
    let displayName = "Kubernetes context"
    let isClickable = true
    let collapsePriority = 50
    var hitRect: NSRect = .zero
    /// Retained while the menu is open (menu items hold their target weakly).
    private var menuTarget: KubeMenuTarget?

    init() {
        MainActor.assumeIsolated { KubeStore.shared.start() }
    }

    var tooltipText: String? {
        MainActor.assumeIsolated {
            let store = KubeStore.shared
            return store.isGuardedContext(store.context)
                ? "Kube context matches a profile rule — click to switch" : "Kube context — click to switch"
        }
    }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        MainActor.assumeIsolated { KubeStore.shared.isEnabled && KubeStore.shared.context != nil }
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let (label, guarded) = MainActor.assumeIsolated {
            let store = KubeStore.shared
            return ("⎈ \(store.context ?? "")/\(store.namespace)", store.isGuardedContext(store.context))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: guarded ? .semibold : .medium),
            .foregroundColor: guarded ? NSColor.systemRed : theme.textSecondary
        ]
        hitRect = Self.drawLabel(label, attrs: attrs, endingAt: rx, y: y)
        return hitRect.width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        MainActor.assumeIsolated {
            let target = menuTarget ?? KubeMenuTarget()
            menuTarget = target
            KubeStore.shared.loadNamespaces()
            target.makeMenu().popUp(positioning: nil, at: NSPoint(x: hitRect.minX, y: 0), in: barView)
        }
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        MainActor.assumeIsolated {
            let store = KubeStore.shared
            return "Kube context \(store.context ?? "none"), namespace \(store.namespace)"
        }
    }
}

/// Builds the context/namespace menu and handles picks.
@MainActor
final class KubeMenuTarget: NSObject {
    func makeMenu() -> NSMenu {
        let store = KubeStore.shared
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Context"))
        for name in store.config.contextNames {
            let item = NSMenuItem(title: name, action: #selector(pickContext(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == store.context ? .on : .off
            menu.addItem(item)
        }
        let namespaces = NSMenuItem(title: "Namespace", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for name in store.namespaces.isEmpty ? [store.namespace] : store.namespaces {
            let item = NSMenuItem(title: name, action: #selector(pickNamespace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == store.namespace ? .on : .off
            submenu.addItem(item)
        }
        namespaces.submenu = submenu
        menu.addItem(.separator())
        menu.addItem(namespaces)
        return menu
    }

    @objc func pickContext(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        KubeStore.shared.useContext(name)
    }

    @objc func pickNamespace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        KubeStore.shared.useNamespace(name)
    }
}
