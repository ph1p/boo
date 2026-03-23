import Cocoa

// MARK: - Shared Helpers

/// Draw a tinted SF Symbol into a CGContext, flipping coordinates for correct orientation.
private func drawTintedIcon(_ image: NSImage, color: NSColor, in rect: NSRect, ctx: CGContext) {
    let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
        image.draw(in: drawRect)
        color.set()
        drawRect.fill(using: .sourceAtop)
        return true
    }
    ctx.saveGState()
    ctx.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    tinted.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .sourceOver, fraction: 1.0)
    ctx.restoreGState()
}

// MARK: - Environment Segment

/// Shows the terminal environment type (local/SSH/Docker) with a colored dot and text label.
/// Dual-channel indicator: color + text ensures WCAG 1.4.1 compliance (no color-only information).
final class EnvironmentSegment: StatusBarPlugin {
    let id = "environment"
    let position: StatusBarPosition = .left
    let priority = 0

    private var cachedSession: RemoteSessionType?
    private var cachedIsRemote: Bool = false

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowConnection
    }

    func update(state: StatusBarState) {
        cachedSession = state.remoteSession
        cachedIsRemote = state.isRemote
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let (dotColor, label) = environmentInfo(state: state)
        var cx = x

        // Draw colored dot — centered vertically in bar
        let dotSize: CGFloat = 6
        let dotY = (DensityMetrics.current.statusBarHeight - dotSize) / 2
        ctx.setFillColor(dotColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx, y: dotY, width: dotSize, height: dotSize))
        cx += dotSize + 4

        // Draw text label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: dotColor
        ]
        let str = label as NSString
        str.draw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.size(withAttributes: attrs).width

        return cx - x
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        false
    }

    /// Returns (dot color, text label) for the current environment.
    private func environmentInfo(state: StatusBarState) -> (NSColor, String) {
        if let session = state.remoteSession {
            let color: NSColor
            switch session {
            case .ssh, .mosh:
                color = .extermRemote
            case .container:
                color = .extermDocker
            }
            return (color, "\(session.envType): \(session.displayName)")
        } else if state.isRemote {
            return (.extermRemote, "remote")
        }
        return (.extermLocal, "local")
    }

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        if let session = state.remoteSession {
            return "Environment: \(session.envType) \(session.displayName)"
        } else if state.isRemote {
            return "Environment: remote"
        }
        return "Environment: local"
    }
}

// MARK: - Git Branch Segment

final class GitBranchSegment: StatusBarPlugin {
    let id = "git-branch"
    let position: StatusBarPosition = .left
    let priority = 10
    var hitRect: NSRect = .zero

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowGitBranch && state.gitBranch != nil
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        guard let branch = state.gitBranch else { return 0 }
        var cx = x

        let iconAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: theme.accentColor
        ]
        let iconStr = "\u{2387}" as NSString
        iconStr.draw(at: NSPoint(x: cx, y: y), withAttributes: iconAttrs)
        cx += iconStr.size(withAttributes: iconAttrs).width + 3

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.accentColor
        ]
        let str = branch as NSString
        str.draw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.size(withAttributes: attrs).width

        // Show changed file count
        if state.gitChangedCount > 0 {
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.extermRemote
            ]
            let countStr = " \(state.gitChangedCount)\u{25CF}" as NSString
            countStr.draw(at: NSPoint(x: cx, y: y + 0.5), withAttributes: countAttrs)
            cx += countStr.size(withAttributes: countAttrs).width
        }

        if state.gitRepoRoot != nil {
            let chevronAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: theme.accentColor.withAlphaComponent(0.6)
            ]
            let chevron = " \u{25BE}" as NSString
            chevron.draw(at: NSPoint(x: cx, y: y + 1), withAttributes: chevronAttrs)
            cx += chevron.size(withAttributes: chevronAttrs).width
        }

        let width = cx - x
        hitRect =
            state.gitRepoRoot != nil
            ? NSRect(x: x - 2, y: 0, width: width + 4, height: DensityMetrics.current.statusBarHeight)
            : .zero
        return width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point), let repoRoot = barView.gitRepoRoot else { return false }
        showBranchMenu(in: barView, repoRoot: repoRoot)
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        guard let branch = state.gitBranch else { return nil }
        return "Git: \(branch)"
    }

    private func showBranchMenu(in barView: StatusBarView, repoRoot: String) {
        let branches = StatusBarView.listBranches(repoRoot: repoRoot)
        guard !branches.local.isEmpty || !branches.remote.isEmpty else { return }

        let menu = NSMenu()

        let localHeader = NSMenuItem(title: "Local Branches", action: nil, keyEquivalent: "")
        localHeader.isEnabled = false
        menu.addItem(localHeader)
        menu.addItem(.separator())

        for branch in branches.local {
            let item = NSMenuItem(title: branch, action: #selector(barView.gitBranchSelected(_:)), keyEquivalent: "")
            item.target = barView
            item.representedObject = branch
            if branch == barView.gitBranch { item.state = .on }
            menu.addItem(item)
        }

        if !branches.remote.isEmpty {
            menu.addItem(.separator())
            let remoteHeader = NSMenuItem(title: "Remote Branches", action: nil, keyEquivalent: "")
            remoteHeader.isEnabled = false
            menu.addItem(remoteHeader)
            menu.addItem(.separator())

            var grouped: [String: [String]] = [:]
            for ref in branches.remote {
                let parts = ref.split(separator: "/", maxSplits: 1)
                let remoteName = String(parts[0])
                let branchName = parts.count > 1 ? String(parts[1]) : ref
                grouped[remoteName, default: []].append(branchName)
            }

            for remoteName in grouped.keys.sorted() {
                for branch in grouped[remoteName]!.sorted() {
                    if branches.local.contains(branch) { continue }
                    let displayTitle = "\(remoteName)/\(branch)"
                    let item = NSMenuItem(
                        title: displayTitle, action: #selector(barView.gitBranchSelected(_:)), keyEquivalent: "")
                    item.target = barView
                    item.representedObject = branch
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
            }
        }

        let menuPoint = NSPoint(x: hitRect.minX, y: 0)
        menu.popUp(positioning: menu.items.last, at: menuPoint, in: barView)
    }
}

// MARK: - Path Segment

final class PathSegment: StatusBarPlugin {
    let id = "path"
    let position: StatusBarPosition = .left
    let priority = 20

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.pluginBool("file-tree-local", "showPath", default: true)
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.7)
        ]
        let str = abbreviatePath(state.currentDirectory) as NSString
        str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        return str.size(withAttributes: attrs).width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        "Path: \(abbreviatePath(state.currentDirectory))"
    }
}

// MARK: - Process Segment

final class ProcessSegment: StatusBarPlugin {
    let id = "process"
    let position: StatusBarPosition = .left
    let priority = 30

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.pluginBool("file-tree-local", "showProcess", default: true) && !state.runningProcess.isEmpty
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let process = state.runningProcess
        let barH = DensityMetrics.current.statusBarHeight
        let color = ProcessIcon.themeColor(for: process, theme: theme, isActive: true)
        var cx = x

        // Draw process icon if available
        if let iconName = ProcessIcon.icon(for: process),
            let image = NSImage(systemSymbolName: iconName, accessibilityDescription: process)
        {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            let imgSize = configured.size
            let imgY = (barH - imgSize.height) / 2
            let imgRect = NSRect(x: cx, y: imgY, width: imgSize.width, height: imgSize.height)

            drawTintedIcon(configured, color: color, in: imgRect, ctx: ctx)

            cx += imgSize.width + 3
        }

        // Draw process name
        let label = ProcessIcon.displayName(for: process) ?? process
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color.withAlphaComponent(0.7)
        ]
        let str = label as NSString
        str.draw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.size(withAttributes: attrs).width

        return cx - x
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        guard !state.runningProcess.isEmpty else { return nil }
        let label = ProcessIcon.displayName(for: state.runningProcess) ?? state.runningProcess
        return "Process: \(label)"
    }
}

// MARK: - Pane Info Segment

final class PaneInfoSegment: StatusBarPlugin {
    let id = "pane-info"
    let position: StatusBarPosition = .right
    let priority = 40

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowPaneInfo
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        var info = "\(state.paneCount) pane\(state.paneCount == 1 ? "" : "s")"
        if state.tabCount > 1 { info += " \u{2022} \(state.tabCount) tabs" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.5)
        ]
        let str = info as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: rx - size.width - 4, y: y), withAttributes: attrs)
        return size.width + 8
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        var info = "\(state.paneCount) pane\(state.paneCount == 1 ? "" : "s")"
        if state.tabCount > 1 { info += ", \(state.tabCount) tabs" }
        return info
    }
}

// MARK: - File Tree Icon Segment

final class FileTreeIconSegment: StatusBarPlugin {
    let id = "filetree-icon"
    let position: StatusBarPosition = .right
    let priority = 5
    let associatedPanelID: String? = "file-tree-local"
    var hitRect: NSRect = .zero
    /// Whether any file-tree plugin is available in the current context.
    var isAvailable: Bool = true

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool { isAvailable }

    func update(state: StatusBarState) {}

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let barH = DensityMetrics.current.statusBarHeight
        let isActive =
            state.visibleSidebarPlugins.contains("file-tree-local")
            || state.visibleSidebarPlugins.contains("file-tree-remote")
        let color = isActive ? theme.accentColor : theme.chromeMuted.withAlphaComponent(0.5)

        let image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Files")
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)

        let cellWidth: CGFloat = 24
        hitRect = NSRect(x: rx - cellWidth, y: 0, width: cellWidth, height: barH)
        if let img = configured {
            let imgSize = img.size
            let drawX = rx - cellWidth + (cellWidth - imgSize.width) / 2
            let drawY = (barH - imgSize.height) / 2
            let imgRect = NSRect(x: drawX, y: drawY, width: imgSize.width, height: imgSize.height)
            drawTintedIcon(img, color: color, in: imgRect, ctx: ctx)
        }

        return cellWidth
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        barView.onSidebarPluginToggle?("file-tree-local")
        barView.onSidebarPluginToggle?("file-tree-remote")
        return true
    }

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        let isActive =
            state.visibleSidebarPlugins.contains("file-tree-local")
            || state.visibleSidebarPlugins.contains("file-tree-remote")
        return isActive ? "Files, selected" : "Files"
    }
}

// MARK: - Generic Plugin Icon Segment

/// A clickable status bar icon that toggles a sidebar plugin panel.
/// Plugins register themselves by providing their manifest info.
final class PluginIconSegment: StatusBarPlugin {
    let id: String
    let position: StatusBarPosition
    let priority: Int
    let associatedPanelID: String?
    private let sfSymbol: String
    private let label: String
    /// Whether this plugin is currently available (context-dependent).
    var isAvailable: Bool = true
    private var hitRect: NSRect = .zero

    init(pluginID: String, sfSymbol: String, label: String, position: StatusBarPosition = .right, priority: Int) {
        self.id = "\(pluginID)-icon"
        self.associatedPanelID = pluginID
        self.sfSymbol = sfSymbol
        self.label = label
        self.position = position
        self.priority = priority
    }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool { isAvailable }
    func update(state: StatusBarState) {}

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let barH = DensityMetrics.current.statusBarHeight
        let isActive = state.visibleSidebarPlugins.contains(associatedPanelID ?? "")
        let color = isActive ? theme.accentColor : theme.chromeMuted.withAlphaComponent(0.5)

        let image = NSImage(systemSymbolName: sfSymbol, accessibilityDescription: label)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)

        let cellWidth: CGFloat = 24
        hitRect = NSRect(x: rx - cellWidth, y: 0, width: cellWidth, height: barH)
        if let img = configured {
            let imgSize = img.size
            let drawX = rx - cellWidth + (cellWidth - imgSize.width) / 2
            let drawY = (barH - imgSize.height) / 2
            let imgRect = NSRect(x: drawX, y: drawY, width: imgSize.width, height: imgSize.height)
            drawTintedIcon(img, color: color, in: imgRect, ctx: ctx)
        }

        return cellWidth
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        guard hitRect.contains(point) else { return false }
        if let panelID = associatedPanelID {
            barView.onSidebarPluginToggle?(panelID)
        }
        return true
    }

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        let isActive = state.visibleSidebarPlugins.contains(associatedPanelID ?? "")
        return isActive ? "\(label), selected" : label
    }
}

// MARK: - System Info Segment

/// Shows system resource values (memory, disk, load) as text in the status bar.
/// Each metric is individually controllable via the system-info plugin settings.
/// Updated by SystemInfoPlugin via `updateValues()`.
final class SystemInfoSegment: StatusBarPlugin {
    let id = "system-info-text"
    let position: StatusBarPosition = .left
    let priority = 25

    private var memoryPct: Int = 0
    private var diskFreeGB: Double = 0
    private var cpuPct: Int = 0
    private var batteryPct: Int = -1  // -1 = no battery
    private var batteryCharging: Bool = false
    private var memTint: NSColor?

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        guard !state.isRemote else { return false }
        let s = settings
        return s.pluginBool("system-info", "statusBarCPU", default: false)
            || s.pluginBool("system-info", "statusBarMemory", default: false)
            || s.pluginBool("system-info", "statusBarDisk", default: false)
            || s.pluginBool("system-info", "statusBarBattery", default: false)
    }

    func updateValues(
        memoryPct: Int, diskFreeGB: Double, cpuPct: Int,
        batteryPct: Int, batteryCharging: Bool, tint: NSColor?
    ) {
        self.memoryPct = memoryPct
        self.diskFreeGB = diskFreeGB
        self.cpuPct = cpuPct
        self.batteryPct = batteryPct
        self.batteryCharging = batteryCharging
        self.memTint = tint
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let mutedColor = theme.chromeMuted.withAlphaComponent(0.6)
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        var parts: [(String, NSColor)] = []
        if settings.pluginBool("system-info", "statusBarCPU", default: false) {
            let tint: NSColor = cpuPct > 80 ? .systemRed : (cpuPct > 60 ? .systemOrange : mutedColor)
            parts.append(("CPU \(cpuPct)%", tint))
        }
        if settings.pluginBool("system-info", "statusBarMemory", default: false) {
            parts.append(("Mem \(memoryPct)%", memTint ?? mutedColor))
        }
        if settings.pluginBool("system-info", "statusBarDisk", default: false) {
            parts.append(("Disk \(String(format: "%.0f", diskFreeGB))G", mutedColor))
        }
        if settings.pluginBool("system-info", "statusBarBattery", default: false), batteryPct >= 0 {
            let label = batteryCharging ? "\(batteryPct)%+" : "\(batteryPct)%"
            let tint: NSColor = batteryPct < 15 ? .systemRed : (batteryPct < 30 ? .systemOrange : mutedColor)
            parts.append(("Bat \(label)", tint))
        }

        let middot = " \u{00B7} " as NSString
        let middotAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: mutedColor
        ]
        let middotWidth = middot.size(withAttributes: middotAttrs).width

        var cx = x
        for (i, part) in parts.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: part.1
            ]
            let str = part.0 as NSString
            str.draw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
            cx += str.size(withAttributes: attrs).width
            if i < parts.count - 1 {
                middot.draw(at: NSPoint(x: cx, y: y), withAttributes: middotAttrs)
                cx += middotWidth
            }
        }

        return cx - x
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        var parts: [String] = []
        let s = AppSettings.shared
        if s.pluginBool("system-info", "statusBarCPU", default: false) {
            parts.append("CPU \(cpuPct)%")
        }
        if s.pluginBool("system-info", "statusBarMemory", default: false) {
            parts.append("Memory \(memoryPct)%")
        }
        if s.pluginBool("system-info", "statusBarDisk", default: false) {
            parts.append("Disk \(String(format: "%.0f", diskFreeGB))GB free")
        }
        if s.pluginBool("system-info", "statusBarBattery", default: false), batteryPct >= 0 {
            parts.append("Battery \(batteryPct)%")
        }
        return parts.isEmpty ? nil : "System: " + parts.joined(separator: ", ")
    }
}

// MARK: - Time Segment

final class TimeSegment: StatusBarPlugin {
    let id = "time"
    let position: StatusBarPosition = .right
    let priority = 50

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowTime
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.6)
        ]
        let str = formatter.string(from: Date()) as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: rx - size.width - 4, y: y), withAttributes: attrs)
        return size.width + 8
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        "Time: \(formatter.string(from: Date()))"
    }
}
