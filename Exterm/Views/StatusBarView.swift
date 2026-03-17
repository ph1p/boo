import Cocoa

class StatusBarView: NSView {
    var currentDirectory: String = ""
    var paneCount: Int = 0
    var tabCount: Int = 0
    var runningProcess: String = ""

    /// Called when user picks a branch from the popup. Sends `git switch <branch>\n`.
    var onBranchSwitch: ((String) -> Void)?

    private let barHeight: CGFloat = 22
    private var gitBranch: String?
    private var gitRepoRoot: String?
    private var gitBranchRect: NSRect = .zero // Hit area for branch click
    private var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private var clockTimer: Timer?
    private var gitPollTimer: Timer?
    private var settingsObserver: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        gitPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshGitBranch()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func update(directory: String, paneCount: Int, tabCount: Int, runningProcess: String) {
        let dirChanged = directory != currentDirectory
        let changed = dirChanged || paneCount != self.paneCount || tabCount != self.tabCount || runningProcess != self.runningProcess
        self.currentDirectory = directory
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.runningProcess = runningProcess
        if dirChanged { refreshGitBranch() }
        if changed { needsDisplay = true }
    }

    // MARK: - Git

    private func refreshGitBranch() {
        let dir = currentDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (branch, repoRoot) = Self.detectGitInfo(in: dir)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.gitBranch != branch || self.gitRepoRoot != repoRoot {
                    self.gitBranch = branch
                    self.gitRepoRoot = repoRoot
                    self.needsDisplay = true
                }
            }
        }
    }

    /// Returns (branchName, repoRoot) or (nil, nil).
    private static func detectGitInfo(in directory: String) -> (String?, String?) {
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
        var remote: [String] // e.g. "origin/feature-x"
    }

    private static func listBranches(repoRoot: String) -> GitBranches {
        let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
        var local = Set<String>()
        var remote = Set<String>()

        // Read refs/heads/ (local branches)
        readRefs(at: (gitDir as NSString).appendingPathComponent("refs/heads"), into: &local)

        // Read refs/remotes/ (remote branches)
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

        // Also read packed-refs
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let settings = AppSettings.shared

        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(bounds)

        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.3).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 0.5))

        let textY: CGFloat = (barHeight - 12) / 2

        // Reset hit areas
        gitBranchRect = .zero

        // Collect left segments
        var leftSegments: [(icon: String?, text: String, color: NSColor, isGitBranch: Bool)] = []

        if settings.statusBarShowGitBranch, let branch = gitBranch {
            leftSegments.append((icon: "\u{2387}", text: branch, color: theme.accentColor, isGitBranch: true))
        }

        if settings.statusBarShowPath {
            leftSegments.append((icon: nil, text: abbreviatePath(currentDirectory), color: theme.chromeMuted.withAlphaComponent(0.7), isGitBranch: false))
        }

        if settings.statusBarShowShell, !runningProcess.isEmpty {
            leftSegments.append((icon: nil, text: runningProcess, color: theme.chromeMuted.withAlphaComponent(0.5), isGitBranch: false))
        }

        // Collect right segments
        var rightSegments: [(text: String, color: NSColor)] = []

        if settings.statusBarShowPaneInfo {
            var info = "\(paneCount) pane\(paneCount == 1 ? "" : "s")"
            if tabCount > 1 { info += " \u{2022} \(tabCount) tabs" }
            rightSegments.append((text: info, color: theme.chromeMuted.withAlphaComponent(0.5)))
        }

        if settings.statusBarShowTime {
            rightSegments.append((text: timeFormatter.string(from: Date()), color: theme.chromeMuted.withAlphaComponent(0.6)))
        }

        // Draw left
        var x: CGFloat = 10
        for (i, seg) in leftSegments.enumerated() {
            if i > 0 {
                let sepAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: theme.chromeMuted.withAlphaComponent(0.3)
                ]
                ("\u{2022}" as NSString).draw(at: NSPoint(x: x + 4, y: textY + 1), withAttributes: sepAttrs)
                x += 14
            }

            let segStartX = x

            if let icon = seg.icon {
                let iconAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: seg.color
                ]
                let iconStr = icon as NSString
                iconStr.draw(at: NSPoint(x: x, y: textY), withAttributes: iconAttrs)
                x += iconStr.size(withAttributes: iconAttrs).width + 3
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: seg.color
            ]
            let str = seg.text as NSString
            str.draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)
            x += str.size(withAttributes: attrs).width

            // If this is the git branch segment, add a chevron and save the hit rect
            if seg.isGitBranch && gitRepoRoot != nil {
                let chevronAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: seg.color.withAlphaComponent(0.6)
                ]
                let chevron = " \u{25BE}" as NSString // small down triangle
                chevron.draw(at: NSPoint(x: x, y: textY + 1), withAttributes: chevronAttrs)
                x += chevron.size(withAttributes: chevronAttrs).width

                gitBranchRect = NSRect(x: segStartX - 2, y: 0, width: x - segStartX + 4, height: barHeight)
            }
        }

        // Draw right
        var rx = bounds.width - 10
        for (i, seg) in rightSegments.reversed().enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: seg.color
            ]
            let str = seg.text as NSString
            let size = str.size(withAttributes: attrs)
            rx -= size.width
            str.draw(at: NSPoint(x: rx, y: textY), withAttributes: attrs)

            if i < rightSegments.count - 1 {
                let sepAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: theme.chromeMuted.withAlphaComponent(0.3)
                ]
                rx -= 14
                ("\u{2022}" as NSString).draw(at: NSPoint(x: rx + 4, y: textY + 1), withAttributes: sepAttrs)
            }
        }
    }

    // MARK: - Click Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if gitBranchRect.contains(point), let repoRoot = gitRepoRoot {
            showBranchMenu(at: point, repoRoot: repoRoot)
            return
        }
    }

    private func showBranchMenu(at point: NSPoint, repoRoot: String) {
        let branches = Self.listBranches(repoRoot: repoRoot)
        guard !branches.local.isEmpty || !branches.remote.isEmpty else { return }

        let menu = NSMenu()

        // Local branches
        let localHeader = NSMenuItem(title: "Local Branches", action: nil, keyEquivalent: "")
        localHeader.isEnabled = false
        menu.addItem(localHeader)
        menu.addItem(.separator())

        for branch in branches.local {
            let item = NSMenuItem(title: branch, action: #selector(branchSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch
            if branch == gitBranch { item.state = .on }
            menu.addItem(item)
        }

        // Remote branches
        if !branches.remote.isEmpty {
            menu.addItem(.separator())
            let remoteHeader = NSMenuItem(title: "Remote Branches", action: nil, keyEquivalent: "")
            remoteHeader.isEnabled = false
            menu.addItem(remoteHeader)
            menu.addItem(.separator())

            // Group by remote name
            var grouped: [String: [String]] = [:]
            for ref in branches.remote {
                let parts = ref.split(separator: "/", maxSplits: 1)
                let remoteName = String(parts[0])
                let branchName = parts.count > 1 ? String(parts[1]) : ref
                grouped[remoteName, default: []].append(branchName)
            }

            for remoteName in grouped.keys.sorted() {
                for branch in grouped[remoteName]!.sorted() {
                    // Skip if there's already a local branch with the same name
                    if branches.local.contains(branch) { continue }

                    let displayTitle = "\(remoteName)/\(branch)"
                    let item = NSMenuItem(title: displayTitle, action: #selector(branchSelected(_:)), keyEquivalent: "")
                    item.target = self
                    // git switch will auto-create tracking branch from remote
                    item.representedObject = branch
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
            }
        }

        let menuPoint = NSPoint(x: gitBranchRect.minX, y: barHeight)
        menu.popUp(positioning: nil, at: menuPoint, in: self)
    }

    @objc private func branchSelected(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String else { return }
        guard branch != gitBranch else { return }
        onBranchSwitch?(branch)
    }

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    deinit {
        clockTimer?.invalidate()
        gitPollTimer?.invalidate()
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
