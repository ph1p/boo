import Cocoa

// MARK: - Environment Segment

/// Shows the terminal environment type (local/SSH/Docker) with a colored dot and text label.
/// Dual-channel indicator: color + text ensures WCAG 1.4.1 compliance (no color-only information).
final class EnvironmentSegment: StatusBarPlugin {
    let id = "environment"
    let position: StatusBarPosition = .left
    let priority = 0
    let displayName = "Connection"
    let collapsePriority = 10

    private var cachedSession: RemoteSessionType?
    private var cachedIsRemote: Bool = false

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowConnection && state.isRemote
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
        str.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.safeSize(withAttributes: attrs).width

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
                color = .booRemote
            case .container:
                color = .booDocker
            }
            return (color, "\(session.envType): \(session.displayName)")
        } else if state.isRemote {
            return (.booRemote, "remote")
        }
        return (.booLocal, "local")
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
    let displayName = "Git branch"
    let isClickable = true
    let collapsePriority = 30
    var hitRect: NSRect = .zero

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowGitBranch
            && state.gitBranch != nil
            && settings.isPluginEnabled("git-panel")
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
        iconStr.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: iconAttrs)
        cx += iconStr.safeSize(withAttributes: iconAttrs).width + 3

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.accentColor
        ]
        let maxBranchChars = settings.statusBarBranchMaxLength
        let displayBranch =
            branch.count > maxBranchChars
            ? String(branch.prefix(maxBranchChars)) + "\u{2026}"
            : branch
        let str = displayBranch as NSString
        str.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.safeSize(withAttributes: attrs).width

        // Show changed file count
        if state.gitChangedCount > 0 {
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.booRemote
            ]
            let countStr = " \(state.gitChangedCount)\u{25CF}" as NSString
            countStr.safeDraw(at: NSPoint(x: cx, y: y + 0.5), withAttributes: countAttrs)
            cx += countStr.safeSize(withAttributes: countAttrs).width
        }

        if state.gitRepoRoot != nil {
            let chevronAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: theme.accentColor.withAlphaComponent(0.6)
            ]
            let chevron = " \u{25BE}" as NSString
            chevron.safeDraw(at: NSPoint(x: cx, y: y + 1), withAttributes: chevronAttrs)
            cx += chevron.safeSize(withAttributes: chevronAttrs).width
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

    @MainActor private func showBranchMenu(in barView: StatusBarView, repoRoot: String) {
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
                for branch in (grouped[remoteName] ?? []).sorted() {
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
    let displayName = "Current path"
    let collapsePriority = 20

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.isPluginEnabled("file-tree-local")
            && settings.pluginBool("file-tree-local", "showPath", default: true)
    }

    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    /// The laid-out path, rebuilt only when the path or color changes. CoreText's
    /// attribute handling once aborted here (an exception inside noexcept frames
    /// that `@try` can't catch) when the string was laid out on every frame; a
    /// cached CTLine only touches attributes when the path actually changes.
    private struct Line {
        let path: String
        let style: StatusBarPathStyle
        let color: NSColor
        let line: CTLine
        let ascent: CGFloat
        let width: CGFloat
    }
    private var cached: Line?

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let line = layout(state.currentDirectory, style: settings.statusBarPathStyle, color: theme.textSecondary)
        ctx.saveGState()
        // The bar is flipped; CoreText draws upward from the baseline.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y + line.ascent)
        CTLineDraw(line.line, ctx)
        ctx.restoreGState()
        return line.width
    }

    private func layout(_ path: String, style: StatusBarPathStyle, color: NSColor) -> Line {
        if let cached, cached.path == path, cached.style == style, cached.color == color { return cached }
        let attributed = NSAttributedString(
            string: Self.drawable(Self.display(path, style: style)), attributes: [.font: font, .foregroundColor: color])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, nil, nil))
        let line = Line(path: path, style: style, color: color, line: ctLine, ascent: ascent, width: width)
        cached = line
        return line
    }

    /// The directory as the chosen style shows it.
    static func display(_ path: String, style: StatusBarPathStyle) -> String {
        let abbreviated = abbreviatePath(path)
        switch style {
        case .abbreviated:
            return abbreviated
        case .lastComponent:
            if abbreviated == "~" || abbreviated == "/" || abbreviated.isEmpty { return abbreviated }
            return (abbreviated as NSString).lastPathComponent
        case .compact:
            // fish-style: every component but the last cut to its first character
            // (two when it starts with a dot, so `.config` stays recognisable).
            var parts = abbreviated.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 1 else { return abbreviated }
            for i in 0..<(parts.count - 1) where !parts[i].isEmpty && parts[i] != "~" {
                parts[i] = String(parts[i].prefix(parts[i].hasPrefix(".") ? 2 : 1))
            }
            return parts.joined(separator: "/")
        }
    }

    /// Control characters (a directory name may hold any byte but `/` and NUL) have
    /// no glyph; drop them before they reach font fallback.
    static func drawable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .control }))
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
    let displayName = "Running process"
    let collapsePriority = 65

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        !state.runningProcess.isEmpty
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let process = state.runningProcess
        let barH = DensityMetrics.current.statusBarHeight
        let color = ProcessIcon.themeColor(for: process, theme: theme, isActive: true)
        var cx = x

        // Draw process icon if available
        let iconSize: CGFloat = 10
        if let customImg = ProcessIcon.customImage(for: process, color: color, size: iconSize) {
            let imgY = (barH - iconSize) / 2
            let imgRect = NSRect(x: cx, y: imgY, width: iconSize, height: iconSize)
            customImg.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            cx += iconSize + 3
        } else if let iconName = ProcessIcon.icon(for: process),
            let image = NSImage(systemSymbolName: iconName, accessibilityDescription: process)
        {
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            let imgSize = configured.size
            let imgY = (barH - imgSize.height) / 2
            let imgRect = NSRect(x: cx, y: imgY, width: imgSize.width, height: imgSize.height)

            drawStatusBarTintedIcon(configured, color: color, in: imgRect, ctx: ctx)

            cx += imgSize.width + 3
        }

        // Draw process name
        let label = ProcessIcon.displayName(for: process) ?? process
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color.withAlphaComponent(0.7)
        ]
        let str = label as NSString
        str.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.safeSize(withAttributes: attrs).width

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
    let displayName = "Pane & tab count"
    let collapsePriority = 80

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
            .foregroundColor: theme.textTertiary
        ]
        let str = info as NSString
        let size = str.safeSize(withAttributes: attrs)
        str.safeDraw(at: NSPoint(x: rx - size.width - 4, y: y), withAttributes: attrs)
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

// MARK: - System Info Segment

/// Shows system resource values (memory, disk, load) as text in the status bar.
/// Each metric is individually controllable via the system-info plugin settings.
/// Updated by SystemInfoPlugin via `updateValues()`.
final class SystemInfoSegment: StatusBarPlugin {
    let id = "system-info-text"
    let position: StatusBarPosition = .left
    let priority = 25
    let displayName = "System info"
    let collapsePriority = 75

    private var memoryPct: Int = 0
    private var diskFreeGB: Double = 0
    private var cpuPct: Int = 0
    private var batteryPct: Int = -1  // -1 = no battery
    private var batteryCharging: Bool = false
    private var memTint: NSColor?

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        guard !state.isRemote, settings.isPluginEnabled("system-info") else { return false }
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
        let mutedColor = theme.textSecondary
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
        let middotWidth = middot.safeSize(withAttributes: middotAttrs).width

        var cx = x
        for (i, part) in parts.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: part.1
            ]
            let str = part.0 as NSString
            str.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
            cx += str.safeSize(withAttributes: attrs).width
            if i < parts.count - 1 {
                middot.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: middotAttrs)
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
    let displayName = "Clock"
    let collapsePriority = 70

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowTime
    }

    func draw(
        at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.textSecondary
        ]
        let str = settings.statusBarClockFormat.string(from: Date()) as NSString
        let size = str.safeSize(withAttributes: attrs)
        str.safeDraw(at: NSPoint(x: rx - size.width - 4, y: y), withAttributes: attrs)
        return size.width + 8
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        "Time: \(AppSettings.shared.statusBarClockFormat.string(from: Date()))"
    }
}

// MARK: - Plugin Content Segment

/// Bridges a plugin's StatusBarContent into the StatusBarPlugin protocol.
/// Created dynamically when plugins contribute status bar content via their manifest.
/// Click behavior: activates the plugin's sidebar tab.
final class PluginContentSegment: StatusBarPlugin {
    let id: String
    let position: StatusBarPosition
    let priority: Int
    let pluginID: String
    let isClickable = true
    let collapsePriority = 60
    var displayName: String {
        PluginSettingsView.registeredManifests.first { $0.id == pluginID }?.name ?? pluginID
    }

    private var content: StatusBarContent?

    /// Called when this segment is clicked — set by StatusBarView to focus the plugin's sidebar tab.
    var onPluginClick: ((String) -> Void)?

    init(pluginID: String, position: StatusBarPosition, priority: Int) {
        self.id = "plugin.\(pluginID)"
        self.pluginID = pluginID
        self.position = position
        self.priority = priority
    }

    func updateContent(_ content: StatusBarContent) {
        self.content = content
    }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        content != nil && settings.isPluginEnabled(pluginID)
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        guard let content else { return 0 }
        return drawStatusBarIconLabel(
            icon: content.icon, text: content.text,
            tint: resolveTint(content.tint, theme: theme) ?? theme.chromeMuted,
            textColor: theme.chromeText, at: x, y: y, ctx: ctx)
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        onPluginClick?(pluginID)
        return true
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        content?.accessibilityLabel ?? content?.text
    }

    var tooltipText: String? { content?.text }

    private func resolveTint(_ tint: DSLTint?, theme: TerminalTheme) -> NSColor? {
        guard let tint else { return nil }
        switch tint {
        case .success: return theme.success
        case .error: return theme.error
        case .warning: return theme.warning
        case .accent: return theme.accentColor
        case .muted: return theme.chromeMuted
        }
    }
}
