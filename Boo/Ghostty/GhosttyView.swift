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
    private var isFocused = false
    private var markedText = NSMutableAttributedString()
    private var pendingText: String?

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
    /// Typed text must not reach the shell: input is locked, or tmux control
    /// mode reads its commands from this terminal.
    private var blocksInput: Bool { isInputLocked || tmuxControl != nil }
    nonisolated(unsafe) private(set) var recorder: SessionRecorder?
    /// The mouse-down was a link click Ghostty never saw.
    private var swallowMouseUp = false

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
        var launch = explicitLaunch ?? tabID.flatMap { Self.pendingLaunch.removeValue(forKey: $0) }
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
            ghostty_surface_feed_output(surface, buf.baseAddress, UInt(buf.count))
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

    // MARK: - Keyboard (via NSTextInputClient)

    override func keyDown(with event: NSEvent) {
        if let quickSelectOverlay {
            quickSelectOverlay.handle(event)
            return
        }
        if let copyModeOverlay {
            copyModeOverlay.handle(event)
            return
        }
        guard let surface = surface, !isInputLocked else { return }
        // Control mode reads commands from this terminal: typing would corrupt
        // it. Esc or q detaches, as in tmux's own control-mode clients.
        if let tmuxControl {
            if event.keyCode == 53 || event.charactersIgnoringModifiers == "q" { tmuxControl.detach() }
            return
        }
        if KeyTables.shared.intercept(event, in: self) { return }
        if isHistorySearchKey(event) {
            onHistorySearch?(self)
            return
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translatedMods = ghostty_surface_key_translation_mods(surface, translateMods(event.modifierFlags))
        let params = eventKeyParams(event)
        var key = makeKeyEvent(
            action: action, keyCode: UInt32(event.keyCode), mods: translatedMods,
            consumedMods: params.consumedMods, unshiftedCodepoint: params.unshiftedCodepoint)

        // Check if Ghostty handles this as a binding
        if isBinding(surface, key) {
            _ = ghostty_surface_key(surface, key)
            return
        }

        // Let the input system process it (handles IME, dead keys, etc.)
        let wasComposing = hasMarkedText()
        pendingText = nil
        interpretKeyEvents([event])

        // Get the text to send with the key event.
        // If the text is a control character (< 0x20), strip the control modifier
        // and re-derive the text — Ghostty handles control character encoding
        // internally via its KeyEncoder.
        var textToSend = pendingText
        if let text = textToSend,
            text.count == 1,
            let scalar = text.unicodeScalars.first,
            scalar.value < 0x20
        {
            textToSend = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }

        if let text = textToSend {
            text.withCString { cstr in
                key.text = cstr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }

        // Mirror to broadcast peers: an IME commit as text, a plain key as
        // the same key event; keys still composing stay local.
        if let controller = window?.windowController as? MainWindowController, controller.broadcast != nil {
            if wasComposing, let committed = pendingText {
                controller.broadcastInput(.text(committed), from: self)
            } else if !wasComposing, !hasMarkedText() {
                controller.broadcastInput(
                    .key(
                        action: action.rawValue, keyCode: key.keycode, mods: key.mods.rawValue,
                        consumedMods: key.consumed_mods.rawValue, unshiftedCodepoint: key.unshifted_codepoint,
                        text: textToSend), from: self)
            }
        }
        pendingText = nil
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if KeyTables.shared.swallowsRelease(event) { return }
        let params = eventKeyParams(event)
        let key = makeKeyEvent(
            action: GHOSTTY_ACTION_RELEASE, keyCode: UInt32(event.keyCode),
            mods: translateMods(event.modifierFlags),
            consumedMods: params.consumedMods, unshiftedCodepoint: params.unshiftedCodepoint)
        _ = ghostty_surface_key(surface, key)
        if !hasMarkedText(), let controller = window?.windowController as? MainWindowController,
            controller.broadcast != nil
        {
            controller.broadcastInput(
                .key(
                    action: key.action.rawValue, keyCode: key.keycode, mods: key.mods.rawValue,
                    consumedMods: key.consumed_mods.rawValue, unshiftedCodepoint: key.unshifted_codepoint,
                    text: nil), from: self)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else { return }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = translateMods(event.modifierFlags)
        let action: ghostty_input_action_e =
            (mods.rawValue & mod != 0)
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        let key = makeKeyEvent(action: action, keyCode: UInt32(event.keyCode), mods: mods)
        _ = ghostty_surface_key(surface, key)
    }

    // Prevent system beep for unhandled commands
    override func doCommand(by selector: Selector) {}

    /// Send a synthetic key press to the terminal.
    /// Used for programmatic key simulation (e.g. clear screen via Ctrl+L).
    func sendKey(keyCode: UInt16, mods: ghostty_input_mods_e, text: String? = nil) {
        guard let surface = surface, tmuxControl == nil else { return }
        let codepoint = text?.unicodeScalars.first.map(\.value) ?? 0
        var key = makeKeyEvent(
            action: GHOSTTY_ACTION_PRESS, keyCode: UInt32(keyCode), mods: mods,
            unshiftedCodepoint: codepoint)

        if let text = text {
            text.withCString { cstr in
                key.text = cstr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }

        // Send release
        key.action = GHOSTTY_ACTION_RELEASE
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    /// ⌃R at a prompt of a shell with Boo integration, when the setting allows.
    private func isHistorySearchKey(_ event: NSEvent) -> Bool {
        guard atBooPrompt, onHistorySearch != nil, !hasMarkedText(),
            event.keyCode == 0x0F,  // kVK_ANSI_R
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
        else { return false }
        return AppSettings.shared.historySearchShortcutEnabled
    }

    /// Replaces the prompt's input line with `command` (as a paste, so a
    /// multi-line command isn't run line by line); `run` presses Return.
    func replacePromptLine(with command: String, run: Bool) {
        sendKey(keyCode: 0x0E, mods: GHOSTTY_MODS_CTRL, text: "e")  // ⌃E: end of line
        sendKey(keyCode: 0x20, mods: GHOSTTY_MODS_CTRL, text: "u")  // ⌃U: kill to start
        sendText(command)
        if run { sendKey(keyCode: 0x24, mods: GHOSTTY_MODS_NONE, text: "\r") }
    }

    /// Send text as keyboard input, splitting on \r/\n to synthesize Enter key events.
    func sendRaw(_ text: String) {
        var buf = ""
        for char in text {
            if char == "\r" || char == "\n" {
                if !buf.isEmpty {
                    sendKey(keyCode: 0, mods: GHOSTTY_MODS_NONE, text: buf)
                    buf = ""
                }
                sendKey(keyCode: 0x24, mods: GHOSTTY_MODS_NONE, text: "\r")
            } else {
                buf.append(char)
            }
        }
        if !buf.isEmpty {
            sendKey(keyCode: 0, mods: GHOSTTY_MODS_NONE, text: buf)
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !blocksInput else { return }
        let text: String
        if let str = string as? String {
            text = str
        } else if let astr = string as? NSAttributedString {
            text = astr.string
        } else {
            return
        }

        // If called from interpretKeyEvents during keyDown, store for later
        pendingText = text

        // Clear any marked text
        markedText = NSMutableAttributedString()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        } else if let astr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: astr)
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // ⌘-click while picking broadcast panes adds or removes this pane.
        if event.modifierFlags.contains(.command),
            (window?.windowController as? MainWindowController)?.toggleBroadcastMember(clickedIn: self) == true
        {
            return
        }
        window?.makeFirstResponder(self)
        // ⌘-click opens a link or file:line under the pointer; ⌘⌥ uses the
        // other link target (editor tab vs external editor).
        if event.modifierFlags.contains(.command),
            openLink(
                at: convert(event.locationInWindow, from: nil),
                otherTarget: event.modifierFlags.contains(.option))
        {
            swallowMouseUp = true
            return
        }
        guard let surface = surface else { return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        if swallowMouseUp {
            swallowMouseUp = false
            return
        }
        guard let surface = surface else { return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { updateMousePos(event) }
    override func mouseMoved(with event: NSEvent) {
        updateMousePos(event)
        // Ghostty shows the hand over URLs itself; file paths need ours.
        if event.modifierFlags.contains(.command),
            case .file = link(at: convert(event.locationInWindow, from: nil))?.kind
        {
            NSCursor.pointingHand.set()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard surface != nil else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let block = viewportRow(at: convert(event.locationInWindow, from: nil)).flatMap(promptIndex(atViewportRow:))
        if let block { addCommandBlockItems(to: menu, block: block) }

        let splitRight = NSMenuItem(
            title: "Split Horizontally", action: #selector(MainWindowController.splitVerticalAction(_:)),
            keyEquivalent: "")
        menu.addItem(splitRight)

        let splitDown = NSMenuItem(
            title: "Split Vertically", action: #selector(MainWindowController.splitHorizontalAction(_:)),
            keyEquivalent: "")
        menu.addItem(splitDown)

        menu.addItem(.separator())

        let handoff = AgentHandoffMenuTarget.shared.menuItems(for: self, block: block)
        if !handoff.isEmpty {
            handoff.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let flashItem = NSMenuItem(title: "Flash", action: #selector(flashTerminal(_:)), keyEquivalent: "")
        flashItem.target = self
        menu.addItem(flashItem)

        // New tab options
        menu.addItem(.separator())
        for type in ContentType.creatableTypes {
            let item = NSMenuItem(
                title: "New \(type.displayName) Tab",
                action: #selector(MainWindowController.newTabOfType(_:)),
                keyEquivalent: ""
            )
            item.image = type.icon
            item.representedObject = type
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        endQuickSelect()

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY

        if event.hasPreciseScrollingDeltas {
            // Match Ghostty's 2x multiplier for trackpad — feels more natural
            x *= 2
            y *= 2
        }

        // Pack scroll mods: bit 0 = precision, bits 1-3 = momentum phase
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            mods = 1
        }
        var momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        switch event.momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: break
        }
        mods |= ghostty_input_scroll_mods_t(momentum.rawValue) << 1

        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private func updateMousePos(_ event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Ghostty expects point coordinates (not pixel); it applies the content scale internally
        ghostty_surface_mouse_pos(
            surface, Double(point.x), Double(bounds.height - point.y), translateMods(event.modifierFlags))
    }

    // MARK: - Search

    func startSearch() { sendBindingAction("start_search") }
    func updateSearch(needle: String) { sendBindingAction(needle.isEmpty ? "end_search" : "search:\(needle)") }
    func endSearch() { sendBindingAction("end_search") }
    func navigateSearch(next: Bool) { sendBindingAction(next ? "navigate_search:next" : "navigate_search:previous") }

    // MARK: - Copy / Paste / Flash

    @objc func copy(_ sender: Any?) {
        if let range = copyModeOverlay?.state.range {
            copyScreenText(from: range.start, to: range.end)
            return
        }
        sendBindingAction("copy:clipboard")
    }

    /// Scrolls to the previous (-1) or next (1) shell prompt (OSC 133 A).
    func jumpToPrompt(_ delta: Int) { sendBindingAction("jump_to_prompt:\(delta)") }

    @objc override func selectAll(_ sender: Any?) { sendBindingAction("select_all") }

    private func sendBindingAction(_ action: String) {
        guard let surface = surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Quick select

    private var quickSelectOverlay: QuickSelectOverlay?

    /// Label the matches on screen; the next keys pick one. Beeps when
    /// there is nothing to pick.
    func startQuickSelect() {
        guard quickSelectOverlay == nil, let rows = gridSize?.rows, let cellWidth, let cellHeight else { return }
        endCopyMode()
        let lines = (0..<Int(rows)).map { viewportLine($0) ?? "" }
        let matches = QuickSelect.matches(in: lines)
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let overlay = QuickSelectOverlay(
            frame: bounds, matches: matches,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            onPick: { [weak self] text, insert in
                guard let self else { return }
                self.endQuickSelect()
                if insert {
                    self.sendText(text)
                } else {
                    self.copyToPasteboard(text)
                    self.flashTerminal(nil)
                }
            },
            onCancel: { [weak self] in self?.endQuickSelect() })
        addSubview(overlay)
        quickSelectOverlay = overlay
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    func endQuickSelect() {
        quickSelectOverlay?.removeFromSuperview()
        quickSelectOverlay = nil
    }

    // MARK: - Copy mode

    private var copyModeOverlay: CopyModeOverlay?
    /// Viewport top when copy mode started, restored when it ends.
    private var copyModeReturnRow: Int?

    /// A keyboard cursor over the scrollback; starts on the shell cursor
    /// when the view is at the bottom, else mid-viewport.
    func startCopyMode() {
        guard copyModeOverlay == nil, let surface, let size = gridSize, let cellWidth, let cellHeight else { return }
        endQuickSelect()
        let rows = Int(size.rows)
        let bar = scrollbar ?? GhosttyScrollbar(total: rows, offset: 0, len: rows)

        var cursor = CopyMode.Point(row: bar.offset + rows / 2, column: 0)
        if bar.offset + bar.len >= bar.total {
            var x = 0.0
            var y = 0.0
            var w = 0.0
            var h = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
            let row = Int((CGFloat(y) - cellHeight / 2 - Self.gridPadding) / cellHeight)
            let column = Int((CGFloat(x) - Self.gridPadding + cellWidth / 2) / cellWidth)
            cursor = CopyMode.Point(row: bar.offset + min(max(0, row), rows - 1), column: max(0, column))
        }

        let state = CopyMode(
            cursor: cursor, rows: bar.total, columns: Int(size.columns), pageRows: bar.len,
            cells: { [weak self] row in CopyMode.cells(of: self?.screenLine(row) ?? "") })
        let overlay = CopyModeOverlay(
            frame: bounds, state: state, cellSize: CGSize(width: cellWidth, height: cellHeight),
            viewport: { [weak self] in
                let bar = self?.scrollbar
                return (bar?.offset ?? 0, bar?.len ?? rows)
            },
            onScroll: { [weak self] top in self?.sendBindingAction("scroll_to_row:\(top)") },
            onCopy: { [weak self] start, end in
                guard let self else { return }
                self.copyScreenText(from: start, to: end)
                self.endCopyMode()
                self.flashTerminal(nil)
            },
            onExit: { [weak self] in self?.endCopyMode() })
        addSubview(overlay)
        copyModeOverlay = overlay
        copyModeReturnRow = bar.offset
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    /// Leaves copy mode, scrolling back to where it started.
    func endCopyMode(restoreScroll: Bool = true) {
        guard let overlay = copyModeOverlay else { return }
        overlay.removeFromSuperview()
        copyModeOverlay = nil
        if restoreScroll, let row = copyModeReturnRow { sendBindingAction("scroll_to_row:\(row)") }
        copyModeReturnRow = nil
    }

    /// One screen row (scrollback included) as text.
    private func screenLine(_ row: Int) -> String? {
        guard let columns = gridSize?.columns, columns > 0 else { return nil }
        return readScreenText(
            from: CopyMode.Point(row: row, column: 0), to: CopyMode.Point(row: row, column: Int(columns) - 1))
    }

    private func readScreenText(from start: CopyMode.Point, to end: CopyMode.Point) -> String? {
        readText(GHOSTTY_POINT_SCREEN, from: start, to: end)
    }

    /// Text between two exact grid points in the given coordinate space.
    private func readText(_ tag: ghostty_point_tag_e, from start: CopyMode.Point, to end: CopyMode.Point) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(0, start.column)), y: UInt32(max(0, start.row))),
            bottom_right: ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(0, end.column)), y: UInt32(max(0, end.row))),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    private func copyScreenText(from start: CopyMode.Point, to end: CopyMode.Point) {
        guard let text = readScreenText(from: start, to: end), !text.isEmpty else {
            NSSound.beep()
            return
        }
        copyToPasteboard(text)
    }

    @objc func flashTerminal(_ sender: Any?) {
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        addSubview(overlay)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 0
        }) {
            MainActor.assumeIsolated { overlay.removeFromSuperview() }
        }
    }

    /// Pastes `text` like ⌘V (bracketed when the program asked for it), so a
    /// multi-line message reaches a TUI as one input; `submit` presses Return after.
    func paste(_ text: String, submit: Bool) {
        sendText(text)
        guard submit else { return }
        // Let the program finish handling the paste before Return arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendKey(keyCode: 0x24, mods: GHOSTTY_MODS_NONE, text: "\r")
        }
    }

    private func sendText(_ text: String) {
        guard let surface = surface, !blocksInput else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    /// Types `text` as if the user had (a key table's `send:`).
    func typeText(_ text: String) {
        sendText(text)
    }

    /// The terminal has echo turned off (a password prompt), per the pty's termios.
    var isEchoOff: Bool {
        guard let surface else { return false }
        let name = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(name) }
        guard let ptr = name.ptr, name.len > 0 else { return false }
        let path = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(name.len)), as: UTF8.self)
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var attrs = termios()
        guard tcgetattr(fd, &attrs) == 0 else { return false }
        return attrs.c_lflag & tcflag_t(ECHO) == 0
    }

    /// Read the visible viewport text (used by the Remote Control web mirror).
    /// Must be called on the main thread — surface access is not thread-safe.
    func readViewportText() -> String? {
        readText(GHOSTTY_POINT_VIEWPORT)
    }

    /// The last `lines` lines of scrollback plus screen, trailing blank lines dropped.
    func readRecentText(lines: Int) -> String? {
        guard let text = readText(GHOSTTY_POINT_SCREEN) else { return nil }
        var all = text.components(separatedBy: "\n")
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
        return all.suffix(max(lines, 1)).joined(separator: "\n")
    }

    /// The selected text, if any.
    func readSelectionText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    /// The selection, or else the last command's output; nil when both are empty.
    func selectionOrLastOutput() -> (AgentHandoff.Source, String)? {
        if let selection = readSelectionText(), !selection.isEmpty { return (.selection, selection) }
        if let (source, output) = lastCommandOutput(), !output.isEmpty { return (source, output) }
        return nil
    }

    /// Output of the last command run here: from the shell's OSC 133 marks
    /// when it sends them, else matched in the scrollback.
    func lastCommandOutput() -> (AgentHandoff.Source, String)? {
        guard let last = lastCommand else { return nil }
        let source = AgentHandoff.Source.output(command: last.command, exitCode: last.exitCode)
        if let index = lastCommandIndex() {
            return (source, readCommand(index: index, part: .output) ?? "")
        }
        guard let screen = readRecentText(lines: 5000),
            let output = AgentHandoff.output(of: last.command, in: screen, finished: last.exitCode != nil)
        else { return nil }
        return (source, output)
    }

    /// Prompt index of the last command that was run. A finished command is
    /// followed by a fresh prompt, so it starts looking one prompt up; prompts
    /// left empty (Return on a blank line) are skipped.
    func lastCommandIndex() -> Int? {
        let start = commandHistory.last?.isRunning == true ? 0 : 1
        for index in start..<(start + 10) {
            guard let input = readCommand(index: index, part: .input) else { continue }
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return index }
        }
        return nil
    }

    // MARK: - Command blocks (OSC 133 marks, via ghostty-command-output.patch)

    struct PromptMark: Equatable {
        enum Status { case none, succeeded, failed }
        /// Viewport row of the prompt's first line.
        var row: Int
        /// 0 for the newest prompt on the screen, counting up into history.
        var index: Int
        var status: Status
    }

    enum CommandPart { case input, output }

    /// Matches `window-padding-x/y` in the generated Ghostty config.
    nonisolated static let gridPadding: CGFloat = 3

    /// Prompts that start in the viewport, newest first.
    func promptMarks() -> [PromptMark] {
        guard let surface else { return [] }
        var buffer = [ghostty_prompt_mark_s](repeating: ghostty_prompt_mark_s(), count: 256)
        let count = Int(ghostty_surface_prompt_marks(surface, &buffer, UInt(buffer.count)))
        return buffer.prefix(count).map { mark in
            let status: PromptMark.Status
            switch mark.status {
            case GHOSTTY_COMMAND_STATUS_SUCCEEDED: status = .succeeded
            case GHOSTTY_COMMAND_STATUS_FAILED: status = .failed
            default: status = .none
            }
            return PromptMark(row: Int(mark.row), index: Int(mark.index), status: status)
        }
    }

    /// Index of the prompt whose command block contains a viewport row.
    func promptIndex(atViewportRow row: Int) -> Int? {
        guard let surface, row >= 0 else { return nil }
        let index = ghostty_surface_prompt_index_at(surface, UInt32(row))
        return index < 0 ? nil : Int(index)
    }

    /// The typed command or the output of the command block at a prompt index.
    func readCommand(index: Int, part: CommandPart) -> String? {
        guard let surface, index >= 0 else { return nil }
        var text = ghostty_text_s()
        let tag = part == .input ? GHOSTTY_COMMAND_PART_INPUT : GHOSTTY_COMMAND_PART_OUTPUT
        guard ghostty_surface_read_command(surface, UInt32(index), tag, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    /// Height of one grid row in points.
    var cellHeight: CGFloat? {
        guard let size = gridSize, size.cell_height_px > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        return CGFloat(size.cell_height_px) / scale
    }

    /// Width of one grid column in points.
    var cellWidth: CGFloat? {
        guard let size = gridSize, size.cell_width_px > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        return CGFloat(size.cell_width_px) / scale
    }

    /// Viewport row under a point in this view's coordinates.
    func viewportRow(at point: NSPoint) -> Int? {
        guard let cellHeight, let rows = gridSize?.rows else { return nil }
        let fromTop = bounds.height - point.y - Self.gridPadding
        guard fromTop >= 0 else { return nil }
        let row = Int(fromTop / cellHeight)
        return row < Int(rows) ? row : nil
    }

    /// Viewport column under a point in this view's coordinates.
    func viewportColumn(at point: NSPoint) -> Int? {
        guard let cellWidth, let columns = gridSize?.columns else { return nil }
        let x = point.x - Self.gridPadding
        guard x >= 0 else { return nil }
        let column = Int(x / cellWidth)
        return column < Int(columns) ? column : nil
    }

    /// The text of one viewport row.
    func viewportLine(_ row: Int) -> String? {
        guard let columns = gridSize?.columns, columns > 0 else { return nil }
        return readText(
            GHOSTTY_POINT_VIEWPORT, from: CopyMode.Point(row: row, column: 0),
            to: CopyMode.Point(row: row, column: Int(columns) - 1))
    }

    /// The link or file reference under a point, if any.
    func link(at point: NSPoint) -> TerminalLink? {
        guard let row = viewportRow(at: point), let column = viewportColumn(at: point),
            let line = viewportLine(row)
        else { return nil }
        guard let index = LinkResolver.characterIndex(forColumn: column, in: line) else { return nil }
        return LinkResolver.link(in: line, at: index)
    }

    /// Opens the link under `point`; false when there is none.
    func openLink(at point: NSPoint, otherTarget: Bool) -> Bool {
        guard let link = link(at: point) else { return false }
        let location = tabID.flatMap { AgentInbox.locateInWindows($0) }
        let tab = location.map { $0.pane.tabs[$0.tabIndex] }
        let cwd = tab.map { $0.remoteSession != nil ? ($0.remoteWorkingDirectory ?? "") : $0.workingDirectory }
        let origin = LinkOpener.Origin(
            cwd: cwd?.isEmpty == false ? cwd : nil, remote: tab?.remoteSession,
            controller: location?.controller ?? window?.windowController as? MainWindowController)
        let profile = ProfileStore.shared.profile(named: tab?.state.profile)
        let target = profile?.linkTarget ?? AppSettings.shared.defaultLinkTarget
        LinkOpener.open(link.kind, from: origin, target: otherTarget ? target.other : target)
        return true
    }

    /// The command typed at a prompt, or nil for an empty prompt.
    func blockCommand(at index: Int) -> String? {
        guard let input = readCommand(index: index, part: .input) else { return nil }
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// Exit code of a command block: from the history when it recorded the
    /// command, else 0 or 1 from the prompt's mark; nil while it runs.
    func exitCode(ofBlock index: Int, command: String) -> Int32? {
        if index == 0, commandHistory.last?.isRunning == true { return nil }
        if let record = commandHistory.records.last(where: { $0.command == command && !$0.isRunning }) {
            return record.exitCode
        }
        switch promptMarks().first(where: { $0.index == index })?.status {
        case .failed: return 1
        case .succeeded: return 0
        default: return nil
        }
    }

    private func addCommandBlockItems(to menu: NSMenu, block: Int) {
        guard let command = blockCommand(at: block) else { return }
        var items: [(String, Selector)] = [
            ("Copy Command", #selector(copyBlockCommand(_:))),
            ("Copy Output", #selector(copyBlockOutput(_:)))
        ]
        // Typing into a running program would not re-run anything.
        if commandHistory.last?.isRunning != true {
            items.append(("Re-run “\(AgentHandoffMenuTarget.short(command))”", #selector(rerunBlockCommand(_:))))
        }
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = block
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc private func copyBlockCommand(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? Int, let command = blockCommand(at: block) else { return }
        copyToPasteboard(command)
    }

    @objc private func copyBlockOutput(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? Int else { return }
        copyToPasteboard(readCommand(index: block, part: .output) ?? "")
    }

    @objc private func rerunBlockCommand(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? Int, let command = blockCommand(at: block) else { return }
        paste(command, submit: true)
    }

    /// Copies the last command's output; beeps when there is none.
    @discardableResult
    func copyLastCommandOutput() -> Bool {
        guard let (_, output) = lastCommandOutput(), !output.isEmpty else {
            NSSound.beep()
            return false
        }
        copyToPasteboard(output)
        return true
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func readText(_ tag: ghostty_point_tag_e) -> String? {
        guard let surface = surface else { return nil }
        let topLeft = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(
            top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    private func string(from text: ghostty_text_s) -> String? {
        guard let ptr = text.text else { return nil }
        return String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                count: Int(text.text_len)),
            as: UTF8.self)
    }

    /// Read the visible viewport as VT sequences (styles, colors, palette,
    /// cursor) for replay into the Remote Control browser-side terminal.
    /// Must be called on the main thread — surface access is not thread-safe.
    func readViewportStyled() -> String? {
        readStyled(GHOSTTY_POINT_VIEWPORT)
    }

    /// The whole screen including scrollback, styled; saved on quit for
    /// scrollback restore.
    func readScreenStyled() -> String? {
        readStyled(GHOSTTY_POINT_SCREEN)
    }

    private func readStyled(_ tag: ghostty_point_tag_e) -> String? {
        guard let surface = surface else { return nil }
        let topLeft = ghostty_point_s(
            tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(
            tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(
            top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text_styled(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                count: Int(text.text_len)),
            as: UTF8.self)
    }

    @objc func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        sendText(str)
        (window?.windowController as? MainWindowController)?.broadcastInput(.text(str), from: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard isFocused else { return false }
        guard surface != nil else { return false }

        let hasCmd = event.modifierFlags.contains(.command)
        let hasCtrl = event.modifierFlags.contains(.control)

        // While a key table waits, or for a ⌘ leader, the key is the table's.
        if hasCmd, KeyTables.shared.isActive || KeyTables.shared.machine?.config.leader == KeyChord(event: event) {
            keyDown(with: event)
            return true
        }

        // Ctrl+key (without Cmd) always goes to the terminal — these are
        // terminal control characters (Ctrl+C, Ctrl+R, Ctrl+Z, etc.)
        if hasCtrl, !hasCmd {
            keyDown(with: event)
            return true
        }

        // Cmd+key: app menu shortcuts take priority over Ghostty bindings.
        // Check if any menu item claims this key combo. If yes, return false
        // so the menu system handles it. If no menu claims it, forward to
        // Ghostty's keyDown so user-configured Ghostty bindings still work.
        if hasCmd {
            if Self.menuHandlesEvent(event) {
                return false
            }
            // No menu item for this combo — let Ghostty handle it
            keyDown(with: event)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Check if any menu item in the app's menu bar matches this key event.
    private static func menuHandlesEvent(_ event: NSEvent) -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        return menuContainsEquivalent(mainMenu, event: event)
    }

    private static func menuContainsEquivalent(_ menu: NSMenu, event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let eventMods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        for item in menu.items {
            if !item.keyEquivalent.isEmpty && !item.isHidden {
                let itemMods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if item.keyEquivalent.lowercased() == chars, itemMods == eventMods {
                    return true
                }
            }
            if let submenu = item.submenu {
                if menuContainsEquivalent(submenu, event: event) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    /// Build a base key event struct with common fields. Event-specific fields
    /// (text, composing) must be set by the caller.
    private func makeKeyEvent(
        action: ghostty_input_action_e, keyCode: UInt32, mods: ghostty_input_mods_e,
        consumedMods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, unshiftedCodepoint: UInt32 = 0
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods
        key.keycode = keyCode
        key.composing = false
        key.text = nil
        key.consumed_mods = consumedMods
        key.unshifted_codepoint = unshiftedCodepoint
        return key
    }

    /// Derive consumed_mods and unshifted_codepoint from an NSEvent.
    private func eventKeyParams(_ event: NSEvent) -> (consumedMods: ghostty_input_mods_e, unshiftedCodepoint: UInt32) {
        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        let consumed = translateMods(consumedFlags)
        var codepoint: UInt32 = 0
        if let chars = event.characters(byApplyingModifiers: []),
            let scalar = chars.unicodeScalars.first
        {
            codepoint = scalar.value
        }
        return (consumed, codepoint)
    }

    private func isBinding(_ surface: ghostty_surface_t, _ key: ghostty_input_key_s) -> Bool {
        var flags = ghostty_binding_flags_e(rawValue: 0)
        return ghostty_surface_key_is_binding(surface, key, &flags)
    }

    private func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE
        if flags.contains(.shift) { m = ghostty_input_mods_e(rawValue: m.rawValue | GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { m = ghostty_input_mods_e(rawValue: m.rawValue | GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { m = ghostty_input_mods_e(rawValue: m.rawValue | GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { m = ghostty_input_mods_e(rawValue: m.rawValue | GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { m = ghostty_input_mods_e(rawValue: m.rawValue | GHOSTTY_MODS_CAPS.rawValue) }
        return m
    }

    var gridSize: ghostty_surface_size_s? {
        guard let surface = surface else { return nil }
        return ghostty_surface_size(surface)
    }

    var processExited: Bool {
        guard let surface = surface else { return true }
        return ghostty_surface_process_exited(surface)
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
        endTmuxControl()
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
        bytes.withUnsafeBufferPointer { ghostty_surface_write_pty(surface, $0.baseAddress, UInt($0.count)) }
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
                tmuxControl = TmuxControlClient(gateway: self, host: controller)
            case .exit:
                endTmuxControl()
            case .line:
                break
            }
        }
        if !lines.isEmpty { tmuxControl?.receive(lines: lines) }
    }

    private func endTmuxControl() {
        tmuxControl?.gatewayExited()
        tmuxControl = nil
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
