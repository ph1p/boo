import Cocoa

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
            switch session {
            case .ssh(let host, _):
                // Amber for SSH
                return (
                    NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0),
                    "ssh: \(host)"
                )
            case .docker(let container):
                // Blue for Docker
                return (
                    NSColor(calibratedRed: 0.13, green: 0.59, blue: 0.95, alpha: 1.0),
                    "docker: \(container)"
                )
            }
        } else if state.isRemote {
            // Remote detected but no specific session type
            return (
                NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0),
                "remote"
            )
        }
        // Green for local
        return (
            NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.31, alpha: 1.0),
            "local"
        )
    }

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        if let session = state.remoteSession {
            switch session {
            case .ssh(let host, _):
                return "Environment: SSH to \(host)"
            case .docker(let container):
                return "Environment: Docker \(container)"
            }
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
                .foregroundColor: NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0)
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

        let menuPoint = NSPoint(x: hitRect.minX, y: barView.barHeight)
        menu.popUp(positioning: nil, at: menuPoint, in: barView)
    }
}

// MARK: - Path Segment

final class PathSegment: StatusBarPlugin {
    let id = "path"
    let position: StatusBarPosition = .left
    let priority = 20

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowPath
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.7)
        ]
        let str = StatusBarView.abbreviatePath(state.currentDirectory) as NSString
        str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        return str.size(withAttributes: attrs).width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        "Path: \(StatusBarView.abbreviatePath(state.currentDirectory))"
    }
}

// MARK: - Process Segment

final class ProcessSegment: StatusBarPlugin {
    let id = "process"
    let position: StatusBarPosition = .left
    let priority = 30

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        settings.statusBarShowShell && !state.runningProcess.isEmpty
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.5)
        ]
        let str = state.runningProcess as NSString
        str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        return str.size(withAttributes: attrs).width
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool { false }
    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        guard !state.runningProcess.isEmpty else { return nil }
        return "Process: \(state.runningProcess)"
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

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool { true }

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
        if let img = configured {
            let imgSize = img.size
            let drawX = rx - cellWidth + (cellWidth - imgSize.width) / 2
            let drawY = (barH - imgSize.height) / 2
            let imgRect = NSRect(x: drawX, y: drawY, width: imgSize.width, height: imgSize.height)
            hitRect = NSRect(x: rx - cellWidth, y: 0, width: cellWidth, height: barH)

            let tinted = NSImage(size: imgSize, flipped: false) { rect in
                img.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }

            ctx.saveGState()
            ctx.translateBy(x: imgRect.origin.x, y: imgRect.origin.y + imgRect.height)
            ctx.scaleBy(x: 1, y: -1)
            tinted.draw(
                in: NSRect(origin: .zero, size: imgRect.size), from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()
        } else {
            hitRect = NSRect(x: rx - cellWidth, y: 0, width: cellWidth, height: barH)
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
        if let img = configured {
            let imgSize = img.size
            let drawX = rx - cellWidth + (cellWidth - imgSize.width) / 2
            let drawY = (barH - imgSize.height) / 2
            let imgRect = NSRect(x: drawX, y: drawY, width: imgSize.width, height: imgSize.height)
            hitRect = NSRect(x: rx - cellWidth, y: 0, width: cellWidth, height: barH)

            let tinted = NSImage(size: imgSize, flipped: false) { rect in
                img.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }

            ctx.saveGState()
            ctx.translateBy(x: imgRect.origin.x, y: imgRect.origin.y + imgRect.height)
            ctx.scaleBy(x: 1, y: -1)
            tinted.draw(
                in: NSRect(origin: .zero, size: imgRect.size), from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()
        } else {
            hitRect = NSRect(x: rx - cellWidth, y: 0, width: cellWidth, height: barH)
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
