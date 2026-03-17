import Cocoa

class StatusBarView: NSView {
    var currentDirectory: String = ""
    var paneCount: Int = 0
    var tabCount: Int = 0
    var shellName: String = ""

    private let barHeight: CGFloat = 22
    private var gitBranch: String?
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

    func update(directory: String, paneCount: Int, tabCount: Int, shellName: String) {
        let dirChanged = directory != currentDirectory
        let changed = dirChanged || paneCount != self.paneCount || tabCount != self.tabCount || shellName != self.shellName
        self.currentDirectory = directory
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.shellName = shellName
        if dirChanged { refreshGitBranch() }
        if changed { needsDisplay = true }
    }

    // MARK: - Git

    private func refreshGitBranch() {
        let dir = currentDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let branch = Self.detectGitBranch(in: dir)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.gitBranch != branch {
                    self.gitBranch = branch
                    self.needsDisplay = true
                }
            }
        }
    }

    private static func detectGitBranch(in directory: String) -> String? {
        // Walk up to find .git directory
        var dir = directory
        while !dir.isEmpty && dir != "/" {
            let gitHead = (dir as NSString).appendingPathComponent(".git/HEAD")
            if let contents = try? String(contentsOfFile: gitHead, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                if trimmed.hasPrefix(prefix) {
                    return String(trimmed.dropFirst(prefix.count))
                }
                // Detached HEAD — return short hash
                if trimmed.count >= 7 {
                    return String(trimmed.prefix(7))
                }
                return nil
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
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

        // Collect left segments
        var leftSegments: [(icon: String?, text: String, color: NSColor)] = []

        if settings.statusBarShowGitBranch, let branch = gitBranch {
            leftSegments.append((icon: "\u{2387}", text: branch, color: theme.accentColor))
        }

        if settings.statusBarShowPath {
            leftSegments.append((icon: nil, text: abbreviatePath(currentDirectory), color: theme.chromeMuted.withAlphaComponent(0.7)))
        }

        if settings.statusBarShowShell, !shellName.isEmpty {
            leftSegments.append((icon: nil, text: shellName, color: theme.chromeMuted.withAlphaComponent(0.5)))
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
                // Separator dot
                let sepAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: theme.chromeMuted.withAlphaComponent(0.3)
                ]
                ("\u{2022}" as NSString).draw(at: NSPoint(x: x + 4, y: textY + 1), withAttributes: sepAttrs)
                x += 14
            }

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
