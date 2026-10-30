import Cocoa

@MainActor class StatusBarView: NSView {
    var currentDirectory: String = ""
    var paneCount: Int = 0
    var tabCount: Int = 0
    var runningProcess: String = ""

    /// Called when user picks a branch from the popup.
    var onBranchSwitch: ((String) -> Void)?
    /// Called when the sidebar toggle button is clicked.
    var onSidebarToggle: (() -> Void)?
    /// Whether the sidebar is currently visible.
    var sidebarVisible: Bool = true
    /// Whether the sidebar toggle should be hidden (no active plugins).
    var sidebarToggleHidden: Bool = false
    /// Whether the focused terminal session is remote.
    var isRemote: Bool = false
    /// The remote session type (SSH/Docker) if active.
    var remoteSession: RemoteSessionType?

    var barHeight: CGFloat { DensityMetrics.current.statusBarHeight }
    nonisolated(unsafe) private var settingsObserver: Any?
    nonisolated(unsafe) private var agentInboxObserver: Any?
    nonisolated(unsafe) private var orchestratorObservers: [Any] = []

    // Git state (shared with GitBranchSegment)
    var gitBranch: String?
    var gitRepoRoot: String?
    var gitChangedCount: Int = 0

    /// Status bar contents from plugin cycle results.
    /// Setting this property creates/updates/removes PluginContentSegment instances
    /// for external plugins only. Built-in plugins handle their own status bar rendering.
    var pluginStatusBarContents: [(pluginID: String, content: StatusBarContent)] = [] {
        didSet { syncPluginSegments() }
    }

    /// Set of plugin IDs that are external (loaded from ~/.boo/plugins/).
    /// Only external plugins get PluginContentSegment instances.
    var externalPluginIDs: Set<String> = []

    /// Called when a plugin's status bar segment is clicked. Receives the plugin ID.
    var onPluginSegmentClick: ((String) -> Void)?

    /// Active plugin content segments keyed by plugin ID.
    private var pluginSegments: [String: PluginContentSegment] = [:]

    // Plugin arrays sorted by priority
    private(set) var leftPlugins: [StatusBarPlugin] = []
    private(set) var rightPlugins: [StatusBarPlugin] = []

    /// Segments drawn in the last pass with their hit rects. Clicks, hover and
    /// accessibility go through this, so hidden or collapsed segments can never
    /// claim a point through a stale rect.
    var drawnSegments: [(plugin: StatusBarPlugin, rect: NSRect)] = []
    /// Visible segments left out of the last draw because the bar was too narrow.
    var collapsedSegmentIDs: Set<String> = []
    /// One-shot timer that repaints the clock when its displayed value changes.
    nonisolated(unsafe) var clockTimer: Timer?
    /// Hit rect for the sidebar toggle button.
    var sidebarToggleRect: NSRect = .zero

    /// Cached accessibility child elements, rebuilt after each draw.
    var accessibilityElements: [NSAccessibilityElement] = []

    /// ID of the currently hovered segment (nil = none).
    var hoveredSegmentID: String?
    /// Whether the sidebar toggle is hovered.
    var isSidebarToggleHovered: Bool = false
    private var statusBarTrackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateStatusBarTrackingArea()

        registerDefaultPlugins()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        agentInboxObserver = NotificationCenter.default.addObserver(
            forName: .agentInboxChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        orchestratorObservers = [
            Notification.Name.approvalsChanged, .orchestratorChanged, .keyTableChanged, .portsChanged,
            .kubeContextChanged, .rulesChanged, .syncStatusChanged, .agentBudgetChanged,
            .remoteControlChanged
        ].map {
            name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    // MARK: - Plugin Registration

    let systemInfoSegment = SystemInfoSegment()
    let broadcastSegment = BroadcastSegment()
    let recordingSegment = RecordingSegment()
    let keyTableSegment = KeyTableSegment()

    private func registerDefaultPlugins() {
        registerPlugin(keyTableSegment)
        registerPlugin(broadcastSegment)
        registerPlugin(recordingSegment)
        registerPlugin(EnvironmentSegment())
        registerPlugin(GitBranchSegment())
        registerPlugin(PathSegment())
        registerPlugin(ProcessSegment())
        registerPlugin(systemInfoSegment)
        registerPlugin(PaneInfoSegment())
        registerPlugin(TimeSegment())
        registerPlugin(AgentInboxSegment())
        registerPlugin(PortsSegment())
        registerPlugin(KubeSegment())
        registerPlugin(SyncSegment())
        registerPlugin(RemoteControlSegment())
        registerPlugin(OrchestratorSegment())
    }

    func registerPlugin(_ plugin: StatusBarPlugin) {
        switch plugin.position {
        case .left:
            leftPlugins.append(plugin)
            leftPlugins.sort { $0.priority < $1.priority }
        case .right:
            rightPlugins.append(plugin)
            rightPlugins.sort { $0.priority < $1.priority }
        }
    }

    /// Remove all external status bar segments (pushed via IPC socket).
    func unregisterExternalSegments() {
        leftPlugins.removeAll { $0 is ExternalStatusBarSegment }
        rightPlugins.removeAll { $0 is ExternalStatusBarSegment }
    }

    /// Sync PluginContentSegment instances with the latest plugin cycle output.
    /// Only creates segments for external plugins — built-in plugins have their
    /// own dedicated StatusBarPlugin implementations.
    private func syncPluginSegments() {
        // Filter to external plugins only
        let externalContents = pluginStatusBarContents.filter { externalPluginIDs.contains($0.pluginID) }
        let currentIDs = Set(externalContents.map(\.pluginID))
        let existingIDs = Set(pluginSegments.keys)
        var structuralChange = false

        // Remove segments for plugins no longer contributing
        let removedIDs = existingIDs.subtracting(currentIDs)
        if !removedIDs.isEmpty {
            for removedID in removedIDs {
                pluginSegments.removeValue(forKey: removedID)
            }
            let removedSegmentIDs = Set(removedIDs.map { "plugin.\($0)" })
            leftPlugins.removeAll { removedSegmentIDs.contains($0.id) }
            rightPlugins.removeAll { removedSegmentIDs.contains($0.id) }
            structuralChange = true
        }

        // Create or update segments
        for (pluginID, content) in externalContents {
            if let existing = pluginSegments[pluginID] {
                existing.updateContent(content)
            } else {
                let segment = PluginContentSegment(
                    pluginID: pluginID, position: .left, priority: 35)
                segment.onPluginClick = { [weak self] id in
                    self?.onPluginSegmentClick?(id)
                }
                segment.updateContent(content)
                pluginSegments[pluginID] = segment
                registerPlugin(segment)
                structuralChange = true
            }
        }

        if structuralChange {
            needsDisplay = true
        }
    }

    // MARK: - State

    func update(directory: String, paneCount: Int, tabCount: Int, runningProcess: String) {
        let dirChanged = directory != currentDirectory
        let changed =
            dirChanged || paneCount != self.paneCount || tabCount != self.tabCount
            || runningProcess != self.runningProcess
        self.currentDirectory = directory
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.runningProcess = runningProcess
        if dirChanged { refreshGitBranch() }
        if changed { needsDisplay = true }
    }

    var currentState: StatusBarState {
        StatusBarState(
            currentDirectory: currentDirectory,
            paneCount: paneCount,
            tabCount: tabCount,
            runningProcess: runningProcess,
            isRemote: isRemote,
            remoteSession: remoteSession,
            gitBranch: gitBranch,
            gitRepoRoot: gitRepoRoot,
            gitChangedCount: gitChangedCount,
            sidebarVisible: sidebarVisible
        )
    }

    // MARK: - Git

    private func refreshGitBranch() {
        let dir = currentDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (branch, repoRoot) = Self.detectGitInfo(in: dir)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.gitBranch != branch || self.gitRepoRoot != repoRoot {
                    self.gitBranch = branch
                    self.gitRepoRoot = repoRoot
                    self.needsDisplay = true
                }
            }
        }
    }

    /// Returns (branchName, repoRoot) or (nil, nil).
    nonisolated static func detectGitInfo(in directory: String) -> (String?, String?) {
        var dir = directory
        while !dir.isEmpty && dir != "/" {
            let gitDir = (dir as NSString).appendingPathComponent(".git")
            let gitHead = (gitDir as NSString).appendingPathComponent("HEAD")
            if let contents = try? String(contentsOfFile: gitHead, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                if trimmed.hasPrefix(prefix) {
                    return (String(trimmed.dropFirst(prefix.count)), dir)
                }
                if trimmed.count >= 7 {
                    return (String(trimmed.prefix(7)), dir)
                }
                return (nil, nil)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return (nil, nil)
    }

    struct GitBranches {
        var local: [String]
        var remote: [String]  // e.g. "origin/feature-x"
    }

    static func listBranches(repoRoot: String) -> GitBranches {
        let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
        var local = Set<String>()
        var remote = Set<String>()

        readRefs(at: (gitDir as NSString).appendingPathComponent("refs/heads"), into: &local)

        let remotesPath = (gitDir as NSString).appendingPathComponent("refs/remotes")
        if let remotes = try? FileManager.default.contentsOfDirectory(atPath: remotesPath) {
            for remoteName in remotes {
                let remotePath = (remotesPath as NSString).appendingPathComponent(remoteName)
                var refs = Set<String>()
                readRefs(at: remotePath, into: &refs)
                for ref in refs where ref != "HEAD" {
                    remote.insert("\(remoteName)/\(ref)")
                }
            }
        }

        let packedPath = (gitDir as NSString).appendingPathComponent("packed-refs")
        if let packed = try? String(contentsOfFile: packedPath, encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                let l = String(line)
                if l.hasPrefix("#") || l.hasPrefix("^") { continue }
                let parts = l.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let ref = String(parts[1])
                if ref.hasPrefix("refs/heads/") {
                    local.insert(String(ref.dropFirst("refs/heads/".count)))
                } else if ref.hasPrefix("refs/remotes/") {
                    let r = String(ref.dropFirst("refs/remotes/".count))
                    if !r.hasSuffix("/HEAD") { remote.insert(r) }
                }
            }
        }

        return GitBranches(local: local.sorted(), remote: remote.sorted())
    }

    private static func readRefs(at path: String, into set: inout Set<String>) {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return }
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            if !isDir.boolValue {
                set.insert(file)
            }
        }
    }

    // MARK: - Hover Tracking

    func updateStatusBarTrackingArea() {
        guard statusBarTrackingArea?.rect != bounds else { return }
        if let existing = statusBarTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        statusBarTrackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateStatusBarTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var changed = false

        // Check sidebar toggle
        let toggleHover = sidebarToggleRect.contains(point)
        if toggleHover != isSidebarToggleHovered {
            isSidebarToggleHovered = toggleHover
            changed = true
        }

        // Check clickable segments
        let plugin = toggleHover ? nil : segment(at: point)
        let newHovered = plugin?.isClickable == true ? plugin?.id : nil
        if newHovered != hoveredSegmentID {
            hoveredSegmentID = newHovered
            changed = true
        }

        // Update tooltip based on hovered segment
        toolTip = toggleHover ? "Toggle Sidebar" : plugin?.tooltipText

        if changed { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        let changed = hoveredSegmentID != nil || isSidebarToggleHovered
        hoveredSegmentID = nil
        toolTip = nil
        isSidebarToggleHovered = false
        if changed { needsDisplay = true }
    }

    deinit {
        clockTimer?.invalidate()
        for observer in [settingsObserver, agentInboxObserver].compactMap({ $0 }) + orchestratorObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - StatusBarView Menu Actions (used by plugins)

extension StatusBarView {
    @objc func gitBranchSelected(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String else { return }
        guard branch != gitBranch else { return }
        onBranchSwitch?(branch)
    }
}
