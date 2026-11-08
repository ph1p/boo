import CGhostty
import Cocoa

/// Process-level registry of direct-child PIDs already claimed by a GhosttyView.
/// Prevents two concurrently-created views from walking down to the same shell.
/// All access is on the main thread (GhosttyView is main-thread only).
@MainActor enum ClaimedDirectChildren {
    private static var claimed: Set<pid_t> = []

    /// Atomically claim `pid`. Returns true if the claim succeeded (pid was unclaimed).
    static func claim(_ pid: pid_t) -> Bool {
        guard !claimed.contains(pid) else { return false }
        claimed.insert(pid)
        return true
    }

    static func release(_ pid: pid_t) { claimed.remove(pid) }
}

/// NSView that hosts a Ghostty terminal surface with Metal rendering.
/// Implements NSTextInputClient for proper keyboard input handling.
@MainActor class GhosttyView: NSView, @preconcurrency NSTextInputClient {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    var onFocused: (() -> Void)?
    var onPwdChanged: ((String) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onDirectoryListing: ((String, String) -> Void)?
    var onProcessExited: (() -> Void)?
    var onShellPIDDiscovered: ((pid_t) -> Void)?
    var onScrollbarChanged: ((GhosttyScrollbar) -> Void)?
    /// The tab UUID this view was created for. Set once in init and never changes.
    private(set) var tabID: UUID?
    /// Called when OSC 9999 cmd_start fires. Argument is the command string.
    var onCommandStart: ((String) -> Void)?
    /// Called when OSC 9999 cmd_end fires. Argument is the exit code.
    var onCommandEnd: ((Int32) -> Void)?
    /// Commands the shell ran here. Updated by the runtime before
    /// `onCommandStart` / `onCommandEnd`.
    var commandHistory = CommandHistory()
    /// Called after a command starts or ends, when prompt marks change status.
    var onPromptMarksChanged: (() -> Void)?
    /// The shell sourced Boo's integration and sits at a prompt (no command
    /// running); set from its cmd_start / cmd_end markers.
    var atBooPrompt = false
    /// ⌃R at a Boo prompt; the view's owner opens history search.
    var onHistorySearch: ((GhosttyView) -> Void)?
    /// The last command the shell ran here and its exit code (nil while it runs).
    var lastCommand: (command: String, exitCode: Int32?)? {
        commandHistory.last.map { ($0.command, $0.exitCode) }
    }
    /// OSC 9;4 progress report; the percent is -1 when none was sent.
    var onProgressReport: ((TerminalProgress.Report, Int) -> Void)?
    /// Called when Ghostty fires a terminal bell (BEL / GHOSTTY_ACTION_RING_BELL).
    var onBell: (() -> Void)?
    /// Called when Ghostty requests a desktop notification (OSC 777 / 99).
    /// Arguments are the notification title and body strings.
    var onDesktopNotification: ((String, String) -> Void)?
    /// Called when Ghostty requests the search UI to open (needle may be empty).
    var onSearchRequested: ((String) -> Void)?
    /// Called when Ghostty reports the total number of search matches.
    var onSearchTotal: ((Int) -> Void)?
    /// Called when Ghostty reports the currently selected match index.
    var onSearchSelected: ((Int) -> Void)?
    /// Called when Ghostty requests the search UI to close.
    var onSearchEnded: (() -> Void)?
    let createdAt = Date()
    var shellPID: pid_t = 0

    /// Current scrollbar state from the terminal core.
    struct GhosttyScrollbar {
        let total: Int
        let offset: Int
        let len: Int
    }
    /// Latest scrollbar state, so copy mode can map screen rows to the viewport.
    var scrollbar: GhosttyScrollbar? {
        didSet {
            guard let copyModeOverlay, let scrollbar else { return }
            copyModeOverlay.update(rows: scrollbar.total, pageRows: scrollbar.len)
        }
    }
    var isFocused = false
    var markedText = NSMutableAttributedString()
    var pendingText: String?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func isAccessibilityElement() -> Bool { true }
    /// The visible screen, so VoiceOver can read the terminal. Read only on
    /// demand: assistive apps query it, nothing pushes it.
    override func accessibilityValue() -> Any? { readViewportText() ?? "" }

    /// How a tab's terminal starts, keyed by tab ID. Consumed once, when its
    /// surface is created.
    static var pendingLaunch: [UUID: LaunchSpec] = [:]

    /// Fans the surface's raw pty output out to the recorder and trigger matcher.
    let outputTap = OutputTapHub()
    /// Catches `tmux -CC` control mode; the client below drives it while it lasts.
    let tmuxTap = TmuxGatewayTap()
    private(set) var tmuxControl: TmuxControlClient?
    private var tmuxOverlay: TmuxGatewayOverlay?
    /// Typed text must not reach the shell: input is locked, or tmux control
    /// mode reads its commands from this terminal.
    var blocksInput: Bool { isInputLocked || tmuxControl != nil }
    nonisolated(unsafe) private(set) var recorder: SessionRecorder?
    /// The mouse-down was a link click Ghostty never saw.
    var swallowMouseUp = false
    var quickSelectOverlay: QuickSelectOverlay?
    var copyModeOverlay: CopyModeOverlay?
    /// Viewport top when copy mode started, restored when it ends.
    var copyModeReturnRow: Int?

    /// Drops keyboard and paste input (the cast player's display-only terminal).
    var isInputLocked = false

    /// `launch` overrides `pendingLaunch` (for surfaces that aren't tabs).
    init(workingDirectory: String, paneID: UUID? = nil, tabID: UUID? = nil, launch: LaunchSpec? = nil) {
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true
        // Seed with the theme background, not black: the Metal surface takes a
        // couple of frames to paint after a split/tab creation, and a black
        // placeholder flashes visibly on light themes.
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
        registerForDraggedTypes([.fileURL, .URL, .string])
        createSurface(workingDirectory: workingDirectory, paneID: paneID, tabID: tabID, launch: launch)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createSurface(
        workingDirectory: String, paneID: UUID? = nil, tabID: UUID? = nil, launch explicitLaunch: LaunchSpec? = nil
    ) {
        guard let app = GhosttyRuntime.shared.app else { return }

        // Snapshot child PIDs before surface creation (which forks a shell)
        let myPID = getpid()
        let pidsBefore = Set(ProcessTree.childPIDs(of: myPID))

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        // Inject per-surface env vars so shell integration and agent hooks can identify
        // which Boo pane/tab they belong to without a socket round-trip.
        // Use [CChar] arrays to guarantee pointer stability across the surface_new call.
        var envPairs: [(key: [CChar], value: [CChar])] = []
        func addEnv(_ key: String, _ value: String) {
            envPairs.append((key: Array(key.utf8CString), value: Array(value.utf8CString)))
        }
        var launch =
            explicitLaunch ?? tabID.flatMap { Self.pendingLaunch.removeValue(forKey: $0) }
            ?? tabID.flatMap { CrashRecovery.takeResume(for: $0) }
        // A tab starts with its profile's shell, env and cwd (rules can only
        // see the starting directory at this point).
        if explicitLaunch == nil, tabID != nil,
            let profile = RuleEngine.shared.launchProfile(cwd: launch?.cwd ?? workingDirectory)
        {
            launch = profile.launchSpec(merging: launch)
        }
        // Boo's own variables always win over a launch spec's.
        for (key, value) in (launch?.env ?? [:]).sorted(by: { $0.key < $1.key }) where !key.hasPrefix("BOO_") {
            addEnv(key, value)
        }
        addEnv("BOO_TERM", "1")
        if let paneID { addEnv("BOO_PANE_ID", paneID.uuidString) }
        if let tabID {
            addEnv("BOO_TAB_ID", tabID.uuidString)
            addEnv("BOO_TOKEN", CapabilityTokens.shared.token(for: tabID))
        }

        var envVars = envPairs.map { pair in
            ghostty_env_var_s(
                key: pair.key.withUnsafeBufferPointer { $0.baseAddress! },
                value: pair.value.withUnsafeBufferPointer { $0.baseAddress! })
        }

        // Typed as Ghostty's `initial_input`: no race with shell startup.
        let initialInput = launch?.command.map { $0 + "\n" }
        let program = launch?.program.map { Array($0.utf8CString) }
        withExtendedLifetime((envPairs, program)) {
            (launch?.cwd ?? workingDirectory).withCString { cwd in
                envVars.withUnsafeMutableBufferPointer { buf in
                    config.working_directory = cwd
                    config.env_vars = buf.baseAddress
                    config.env_var_count = buf.count
                    config.command = program?.withUnsafeBufferPointer { $0.baseAddress }
                    if let initialInput {
                        initialInput.withCString { input in
                            config.initial_input = input
                            surface = ghostty_surface_new(app, &config)
                        }
                    } else {
                        surface = ghostty_surface_new(app, &config)
                    }
                }
            }
        }

        if let s = surface {
            GhosttyRuntime.shared.registerSurface(s)
            // Start unfocused — only becomeFirstResponder sets focus
            ghostty_surface_set_focus(s, false)
            if tabID != nil { RuleEngine.shared.register(self) }
            if AppSettings.shared.tmuxIntegration {
                tmuxTap.onEvents = { [weak self] in self?.handleTmux($0) }
                tmuxTap.install(surface: s)
            }
            // Before the shell's first output, so the old screen sits above the new prompt.
            if let tabID, let saved = ScrollbackStore.take(for: tabID) { feedOutput(saved) }
        }

        // Schedule shell PID discovery on next run loop tick, after callbacks are wired
        DispatchQueue.main.async { [weak self] in
            self?.discoverShellPID(myPID: myPID, pidsBefore: pidsBefore)
        }
    }

    /// Find the new shell PID by comparing child PIDs before/after surface creation.
    /// Ghostty forks: Boo → login → shell. We find the new direct child (login),
    /// then walk down to the actual shell process.
    /// Retries up to 5x at 100ms intervals if the child isn't visible yet.
    nonisolated(unsafe) private var claimedDirectChild: pid_t = 0

    /// Re-walks from the claimed login process to find the current shell PID.
    /// Called when sendImage fails with ESRCH — zsh re-exec'd to a new PID.
    /// Fires onShellPIDDiscovered if a new shell is found.
    func refreshShellPIDIfNeeded(currentPID: pid_t) {
        guard claimedDirectChild != 0, shellPID == currentPID else { return }
        let fresh = ProcessTree.walkToLeafShell(from: claimedDirectChild)
        guard fresh != currentPID, KittyImageProtocol.ttyPath(for: fresh) != nil else { return }
        booLog(.debug, .terminal, "refreshShellPID: \(currentPID) → \(fresh) via directChild=\(claimedDirectChild)")
        shellPID = fresh
        onShellPIDDiscovered?(fresh)
    }

    private func discoverShellPID(myPID: pid_t, pidsBefore: Set<pid_t>, attempt: Int = 0) {
        // Enumerate child PIDs on a background queue to avoid blocking the main thread
        // with proc_listchildpids / walkToLeafShell syscalls.
        // ClaimedDirectChildren.claim must stay on main (@MainActor), so only the
        // syscall work is moved off; the claim and all property mutations come back to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let pidsAfter = Set(ProcessTree.childPIDs(of: myPID))
            let newPIDs = pidsAfter.subtracting(pidsBefore)
            let candidates = newPIDs.sorted()

            // Return to main to claim and finalize (ClaimedDirectChildren is @MainActor).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Find the first unclaimed direct child.
                let directChild = candidates.first { ClaimedDirectChildren.claim($0) }

                if let directChild {
                    // Walk down the single-child chain (login → shell) — do on background.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let shell = ProcessTree.walkToLeafShell(from: directChild)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if shell != directChild || attempt >= 3 {
                                booLog(
                                    .debug, .terminal,
                                    "shellPID discovered: directChild=\(directChild) shell=\(shell) attempt=\(attempt)")
                                self.claimedDirectChild = directChild
                                self.shellPID = shell
                                self.onShellPIDDiscovered?(shell)
                                return
                            }
                            // Shell not yet visible — release claim and retry.
                            ClaimedDirectChildren.release(directChild)
                            self.scheduleDiscoveryRetry(myPID: myPID, pidsBefore: pidsBefore, attempt: attempt)
                        }
                    }
                    return
                }

                // No unclaimed child found — schedule retry or give up.
                self.scheduleDiscoveryRetry(myPID: myPID, pidsBefore: pidsBefore, attempt: attempt)
            }
        }
    }

    /// Schedule a retry or, on the final attempt, fall back to claiming whatever is available.
    private func scheduleDiscoveryRetry(myPID: pid_t, pidsBefore: Set<pid_t>, attempt: Int) {
        guard attempt < 8 else {
            // Last resort: scan again on background then claim on main.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let pidsNow = Set(ProcessTree.childPIDs(of: myPID))
                let candidates = pidsNow.subtracting(pidsBefore).sorted()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let dc = candidates.first(where: { ClaimedDirectChildren.claim($0) }) {
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self else { return }
                            let shell = ProcessTree.walkToLeafShell(from: dc)
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                booLog(.debug, .terminal, "shellPID fallback: directChild=\(dc) shell=\(shell)")
                                self.claimedDirectChild = dc
                                self.shellPID = shell
                                self.onShellPIDDiscovered?(shell)
                            }
                        }
                    }
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.discoverShellPID(myPID: myPID, pidsBefore: pidsBefore, attempt: attempt + 1)
        }
    }

    // MARK: - Sizing

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let old = window {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: old)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
            center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: old)
        }
        if let newWindow {
            center.addObserver(
                self, selector: #selector(windowKeyStateChanged),
                name: NSWindow.didBecomeKeyNotification, object: newWindow)
            center.addObserver(
                self, selector: #selector(windowKeyStateChanged),
                name: NSWindow.didResignKeyNotification, object: newWindow)
            center.addObserver(
                self, selector: #selector(windowScreenChanged),
                name: NSWindow.didChangeScreenNotification, object: newWindow)
        }
    }

    @objc private func windowScreenChanged(_ notification: Notification) {
        applyDisplayID()
    }

    /// Tell the renderer which display it is on (vsync source). Matters once
    /// surfaces move between windows on different screens.
    private func applyDisplayID() {
        guard let surface = surface,
            let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentScale()
        applyDisplayID()
        applySurfaceFocus()
    }

    // A parked tab's wrapper stays attached but hidden; stop rendering it meanwhile.
    override func viewDidHide() {
        super.viewDidHide()
        if let surface { ghostty_surface_set_occlusion(surface, false) }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, true)
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentScale()
    }

    private func applyContentScale() {
        guard let surface = surface, let window = window else { return }
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        updateSurfaceSize()
    }

    /// Last pixel size sent to the surface. Used to detect resize bounces
    /// (W → 0 → W) where the final `ghostty_surface_set_size` is a same-size
    /// no-op in Ghostty core (embedded.zig updateSize early-returns) and the
    /// surface would stay stale/blank without an explicit refresh.
    private var lastSurfaceSize: (w: UInt32, h: UInt32) = (0, 0)

    private func updateSurfaceSize() {
        guard let surface = surface else { return }
        let scaledSize = convertToBacking(bounds.size)
        let w = UInt32(scaledSize.width)
        let h = UInt32(scaledSize.height)
        guard w > 0, h > 0 else { return }
        if w == lastSurfaceSize.w, h == lastSurfaceSize.h {
            ghostty_surface_refresh(surface)
            return
        }
        lastSurfaceSize = (w, h)
        ghostty_surface_set_size(surface, w, h)
    }

    // MARK: - Session recording

    var isRecording: Bool { recorder != nil }

    /// Taps the pty output into an asciicast file at `url`.
    func startRecording(to url: URL, title: String?, idleTimeLimit: TimeInterval? = nil) throws {
        guard let surface, recorder == nil else { return }
        let grid = ghostty_surface_size(surface)
        let rec = try SessionRecorder(
            url: url, columns: Int(grid.columns), rows: Int(grid.rows), title: title, idleTimeLimit: idleTimeLimit)
        recorder = rec
        // The snapshot seeds the cast with the screen as it is now: apps that
        // redraw only changed cells (TUIs, spinners) would otherwise replay
        // as fragments on a blank grid.
        outputTap.add(rec, snapshot: true, surface: surface)
    }

    /// Removes the tap and closes the file; returns its URL.
    @discardableResult
    func stopRecording(completion: (@Sendable () -> Void)? = nil) -> URL? {
        guard let rec = recorder else { return nil }
        outputTap.remove(rec, surface: surface)
        recorder = nil
        rec.finish(completion: completion)
        return rec.url
    }

    /// Replays recorded bytes as if the pty had written them.
    func feedOutput(_ bytes: [UInt8]) {
        guard let surface, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            ghostty_surface_feed_output(surface, base, UInt(buf.count))
        }
    }

    /// Live resize (window edge / split divider drag) can drop the final frame:
    /// the renderer's drawable size updates asynchronously and the last redraw
    /// may race the final layout pass. Force one repaint when the drag ends.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refresh()
    }

    /// Force the Metal surface to repaint. Needed after the view is re-attached to
    /// the hierarchy (e.g. tab switch restoring a cached view) where the size may not
    /// change, so `ghostty_surface_set_size` alone does not dirty the surface.
    func refresh() {
        surface.map { ghostty_surface_refresh($0) }
    }

    /// Re-sync the surface pixel size from the current bounds and force a repaint.
    /// Use instead of calling `ghostty_surface_set_size` directly so the internal
    /// last-size tracking stays consistent.
    func syncSizeAndRefresh() {
        updateSurfaceSize()
        refresh()
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        setFocused(true)
        onFocused?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        endQuickSelect()
        endCopyMode(restoreScroll: false)
        setFocused(false)
        return super.resignFirstResponder()
    }

    /// Sync both the Swift `isFocused` flag and the Ghostty C surface focus in one call.
    /// Use instead of direct `ghostty_surface_set_focus` to keep the two in sync.
    func setFocused(_ focused: Bool) {
        isFocused = focused
        applySurfaceFocus()
    }

    /// The surface counts as focused only while its window is key, so a
    /// background window shows an unfocused cursor and apps get focus-out.
    private func applySurfaceFocus() {
        surface.map { ghostty_surface_set_focus($0, isFocused && window?.isKeyWindow == true) }
    }

    @objc private func windowKeyStateChanged() {
        applySurfaceFocus()
    }

    var gridSize: ghostty_surface_size_s? {
        guard let surface = surface else { return nil }
        return ghostty_surface_size(surface)
    }

    func destroy() {
        if claimedDirectChild != 0 {
            ClaimedDirectChildren.release(claimedDirectChild)
            claimedDirectChild = 0
        }
        guard let surface = surface else { return }
        stopRecording()
        if let tabID { RuleEngine.shared.unregister(tabID: tabID) }
        outputTap.detach(surface: surface)
        tmuxTap.detach(surface: surface)
        endTmuxControl(restore: false)
        self.surface = nil  // nil first to prevent callbacks reaching a freed surface
        GhosttyRuntime.shared.unregisterSurface(surface)
        ghostty_surface_free(surface)
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        guard types.contains(.fileURL) || types.contains(.URL) || types.contains(.string) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard surface != nil else { return false }
        let pb = sender.draggingPasteboard

        // Local file URLs (Finder drag) — shell-escape the path
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
            !urls.isEmpty, urls.allSatisfy({ $0.isFileURL })
        {
            // Recordings open in a player tab; hold ⌥ to paste the path instead.
            if !NSEvent.modifierFlags.contains(.option),
                urls.allSatisfy({ ContentType.forFile($0.path) == .castPlayer }),
                let controller = window?.windowController as? MainWindowController
            {
                for url in urls { controller.handleOpenTab(.file(path: url.path)) }
                return true
            }
            sendText(urls.map { shellEscape($0.path) }.joined(separator: " "))
            return true
        }

        // Browser URL drops — paste the full URL raw
        if let urlString = pb.string(forType: .URL), !urlString.isEmpty {
            sendText(urlString)
            return true
        }

        // Text dragged from another app: paste it like ⌘V would.
        if let text = pb.string(forType: .string), !text.isEmpty {
            sendText(text)
            return true
        }

        return false
    }

    deinit {
        let s = surface
        let dc = claimedDirectChild
        outputTap.detach(surface: s)
        tmuxTap.detach(surface: s)
        recorder?.finish()
        surface = nil
        claimedDirectChild = 0
        Task { @MainActor in
            if dc != 0 { ClaimedDirectChildren.release(dc) }
            if let s {
                GhosttyRuntime.shared.unregisterSurface(s)
                ghostty_surface_free(s)
            }
        }
    }
}

// MARK: - tmux control mode

extension GhosttyView: TmuxGateway {
    func writeTmuxCommand(_ line: String) {
        guard let surface else { return }
        let bytes = Array(line.utf8) + [0x0A]
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            ghostty_surface_write_pty(surface, base, UInt(buf.count))
        }
    }

    var tmuxGridSize: TmuxProtocol.CellSize? {
        guard let surface else { return nil }
        let grid = ghostty_surface_size(surface)
        return TmuxProtocol.CellSize(columns: Int(grid.columns), rows: Int(grid.rows))
    }

    fileprivate func handleTmux(_ events: [TmuxGatewayTap.Event]) {
        var lines: [[UInt8]] = []
        for event in events {
            if case .line(let line) = event {
                lines.append(line)
                continue
            }
            if !lines.isEmpty {
                tmuxControl?.receive(lines: lines)
                lines.removeAll()
            }
            switch event {
            case .enter:
                let controller =
                    window?.windowController as? MainWindowController
                    ?? NSApp.keyWindow?.windowController as? MainWindowController
                guard let controller else {
                    booLog(.warning, .app, "[tmux] control mode started without a window to show it")
                    continue
                }
                let tmux = TmuxControlClient(gateway: self, host: controller)
                tmuxControl = tmux
                // The terminal leaves its pane while tmux runs; the overlay
                // covers it when it could not.
                if !controller.tmuxGatewayEntered(self, client: tmux) { showTmuxOverlay(for: tmux) }
            case .exit:
                endTmuxControl(restore: true)
            case .line:
                break
            }
        }
        if !lines.isEmpty { tmuxControl?.receive(lines: lines) }
    }

    /// `restore` puts a parked gateway back into a pane; false when it is being destroyed.
    private func endTmuxControl(restore: Bool) {
        guard let tmux = tmuxControl else { return }
        tmuxControl = nil
        tmux.gatewayExited()
        tmuxOverlay?.removeFromSuperview()
        tmuxOverlay = nil
        let controller = tmux.hostedBy as? MainWindowController
        if restore {
            controller?.tmuxGatewayExited(self, client: tmux)
        } else {
            tmux.parked = nil
            controller?.refreshToolbar()
        }
    }

    private func showTmuxOverlay(for tmux: TmuxControlClient) {
        guard tmuxOverlay == nil else { return }
        let overlay = TmuxGatewayOverlay()
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onDetach = { [weak tmux] in tmux?.detach() }
        overlay.onNewWindow = { [weak tmux] in tmux?.newWindow() }
        overlay.onShowWindow = { [weak tmux] workspace in tmux?.show(workspace: workspace) }
        tmux.onChange = { [weak overlay, weak tmux] in
            guard let tmux else { return }
            overlay?.update(session: tmux.session, windows: tmux.windowList)
        }
        addSubview(overlay)
        tmuxOverlay = overlay
    }
}

// MARK: - Broadcast Input

extension GhosttyView: BroadcastReceiver {
    /// Replays input typed into a peer pane as if typed here.
    func receiveBroadcast(_ input: BroadcastInput) {
        guard tmuxControl == nil else { return }
        switch input {
        case .text(let text):
            sendText(text)
        case .key(let action, let keyCode, let mods, let consumedMods, let unshiftedCodepoint, let text):
            guard let surface else { return }
            var key = makeKeyEvent(
                action: ghostty_input_action_e(rawValue: action), keyCode: keyCode,
                mods: ghostty_input_mods_e(rawValue: mods), consumedMods: ghostty_input_mods_e(rawValue: consumedMods),
                unshiftedCodepoint: unshiftedCodepoint)
            guard let text else {
                _ = ghostty_surface_key(surface, key)
                return
            }
            text.withCString { cstr in
                key.text = cstr
                _ = ghostty_surface_key(surface, key)
            }
        }
    }
}
