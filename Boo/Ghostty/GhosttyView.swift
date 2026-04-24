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
    /// Called when OSC 9999 cmd_start fires. Argument is the command string.
    var onCommandStart: ((String) -> Void)?
    /// Called when OSC 9999 cmd_end fires. Argument is the exit code.
    var onCommandEnd: ((Int32) -> Void)?
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
    private var isFocused = false
    private var markedText = NSMutableAttributedString()
    private var pendingText: String?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }

    init(workingDirectory: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL, .URL])
        createSurface(workingDirectory: workingDirectory)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createSurface(workingDirectory: String) {
        guard let app = GhosttyRuntime.shared.app else { return }

        // Snapshot child PIDs before surface creation (which forks a shell)
        let myPID = getpid()
        let pidsBefore = Set(RemoteExplorer.childPIDs(of: myPID))

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        workingDirectory.withCString { cwd in
            config.working_directory = cwd
            surface = ghostty_surface_new(app, &config)
        }

        if let s = surface {
            GhosttyRuntime.shared.registerSurface(s)
            // Start unfocused — only becomeFirstResponder sets focus
            ghostty_surface_set_focus(s, false)
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
        let fresh = RemoteExplorer.walkToLeafShell(from: claimedDirectChild)
        guard fresh != currentPID, KittyImageProtocol.ttyPath(for: fresh) != nil else { return }
        booLog(.debug, .terminal, "refreshShellPID: \(currentPID) → \(fresh) via directChild=\(claimedDirectChild)")
        shellPID = fresh
        onShellPIDDiscovered?(fresh)
    }

    private func discoverShellPID(myPID: pid_t, pidsBefore: Set<pid_t>, attempt: Int = 0) {
        let pidsAfter = Set(RemoteExplorer.childPIDs(of: myPID))
        // Exclude PIDs that have already been claimed by another GhosttyView this session.
        let newPIDs = pidsAfter.subtracting(pidsBefore)

        // Find the first unclaimed direct child (atomically claim it so concurrent discovery skips it).
        let directChild = newPIDs.sorted().first { ClaimedDirectChildren.claim($0) }

        if let directChild {
            // Walk down the single-child chain (login → shell).
            // On early attempts the shell may not have spawned yet — retry if
            // we're still at an intermediary like `login`.
            let shell = RemoteExplorer.walkToLeafShell(from: directChild)
            if shell != directChild || attempt >= 3 {
                booLog(
                    .debug, .terminal,
                    "shellPID discovered: directChild=\(directChild) shell=\(shell) attempt=\(attempt)")
                claimedDirectChild = directChild
                shellPID = shell
                onShellPIDDiscovered?(shell)
                return
            }
            // Shell not yet visible — release claim and retry so siblings can try
            ClaimedDirectChildren.release(directChild)
        }

        guard attempt < 8 else {
            // Last resort: claim whatever is available
            let pidsNow = Set(RemoteExplorer.childPIDs(of: myPID))
            if let dc = pidsNow.subtracting(pidsBefore).sorted().first(where: { ClaimedDirectChildren.claim($0) }) {
                let shell = RemoteExplorer.walkToLeafShell(from: dc)
                booLog(.debug, .terminal, "shellPID fallback: directChild=\(dc) shell=\(shell)")
                claimedDirectChild = dc
                shellPID = shell
                onShellPIDDiscovered?(shell)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.discoverShellPID(myPID: myPID, pidsBefore: pidsBefore, attempt: attempt + 1)
        }
    }

    // MARK: - Sizing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentScale()
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

    private func updateSurfaceSize() {
        guard let surface = surface else { return }
        let scaledSize = convertToBacking(bounds.size)
        let w = UInt32(scaledSize.width)
        let h = UInt32(scaledSize.height)
        guard w > 0, h > 0 else { return }
        ghostty_surface_set_size(surface, w, h)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        setFocused(true)
        onFocused?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return super.resignFirstResponder()
    }

    /// Sync both the Swift `isFocused` flag and the Ghostty C surface focus in one call.
    /// Use instead of direct `ghostty_surface_set_focus` to keep the two in sync.
    func setFocused(_ focused: Bool) {
        isFocused = focused
        surface.map { ghostty_surface_set_focus($0, focused) }
    }

    // MARK: - Keyboard (via NSTextInputClient)

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else { return }

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
        pendingText = nil
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let params = eventKeyParams(event)
        let key = makeKeyEvent(
            action: GHOSTTY_ACTION_RELEASE, keyCode: UInt32(event.keyCode),
            mods: translateMods(event.modifierFlags),
            consumedMods: params.consumedMods, unshiftedCodepoint: params.unshiftedCodepoint)
        _ = ghostty_surface_key(surface, key)
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
        guard let surface = surface else { return }
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
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { updateMousePos(event) }
    override func mouseMoved(with event: NSEvent) { updateMousePos(event) }

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

        let splitRight = NSMenuItem(
            title: "Split Horizontally", action: #selector(MainWindowController.splitVerticalAction(_:)),
            keyEquivalent: "")
        menu.addItem(splitRight)

        let splitDown = NSMenuItem(
            title: "Split Vertically", action: #selector(MainWindowController.splitHorizontalAction(_:)),
            keyEquivalent: "")
        menu.addItem(splitDown)

        menu.addItem(.separator())

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

    @objc func copy(_ sender: Any?) { sendBindingAction("copy:clipboard") }

    @objc override func selectAll(_ sender: Any?) { sendBindingAction("select_all") }

    private func sendBindingAction(_ action: String) {
        guard let surface = surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
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

    private func sendText(_ text: String) {
        guard let surface = surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    @objc func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        sendText(str)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard isFocused else { return false }
        guard surface != nil else { return false }

        let hasCmd = event.modifierFlags.contains(.command)
        let hasCtrl = event.modifierFlags.contains(.control)

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
        self.surface = nil  // nil first to prevent callbacks reaching a freed surface
        GhosttyRuntime.shared.unregisterSurface(surface)
        ghostty_surface_free(surface)
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        guard types.contains(.fileURL) || types.contains(.URL) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard surface != nil else { return false }
        let pb = sender.draggingPasteboard

        // Local file URLs (Finder drag) — shell-escape the path
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
            !urls.isEmpty, urls.allSatisfy({ $0.isFileURL })
        {
            sendText(urls.map { shellEscape($0.path) }.joined(separator: " "))
            return true
        }

        // Browser URL drops — paste the full URL raw
        if let urlString = pb.string(forType: .URL), !urlString.isEmpty {
            sendText(urlString)
            return true
        }

        return false
    }

    deinit {
        let s = surface
        let dc = claimedDirectChild
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
