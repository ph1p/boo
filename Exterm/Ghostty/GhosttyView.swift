import Cocoa
import CGhostty

/// NSView that hosts a Ghostty terminal surface with Metal rendering.
/// Implements NSTextInputClient for proper keyboard input handling.
class GhosttyView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?

    var onFocused: (() -> Void)?
    var onPwdChanged: ((String) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onProcessExited: (() -> Void)?
    let createdAt = Date()
    var shellPID: pid_t = 0
    private var isFocused = false
    private var markedText = NSMutableAttributedString()
    private var pendingText: String?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    init(workingDirectory: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        createSurface(workingDirectory: workingDirectory)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createSurface(workingDirectory: String) {
        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
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
    }

    // MARK: - Sizing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface = surface, let window = window else { return }
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
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
        isFocused = true
        surface.map { ghostty_surface_set_focus($0, true) }
        onFocused?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        surface.map { ghostty_surface_set_focus($0, false) }
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard (via NSTextInputClient)

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else { return }

        // Build Ghostty key event
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let mods = translateMods(event.modifierFlags)
        let translatedMods = ghostty_surface_key_translation_mods(surface, mods)

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = translatedMods
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.text = nil

        // consumed_mods: control and command never contribute to text translation
        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        key.consumed_mods = translateMods(consumedFlags)

        // unshifted_codepoint: the character with no modifiers applied.
        // Ghostty uses this to compute control characters (e.g. Ctrl+C → 0x03).
        // We must use characters(byApplyingModifiers:) instead of
        // charactersIgnoringModifiers because the latter changes behavior
        // when ctrl is pressed.
        key.unshifted_codepoint = 0
        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            key.unshifted_codepoint = codepoint.value
        }

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
           scalar.value < 0x20 {
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
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = translateMods(event.modifierFlags)
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.text = nil
        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        key.consumed_mods = translateMods(consumedFlags)
        key.unshifted_codepoint = 0
        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            key.unshifted_codepoint = codepoint.value
        }
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
        let action: ghostty_input_action_e = (mods.rawValue & mod != 0)
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.text = nil
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, key)
    }

    // Prevent system beep for unhandled commands
    override func doCommand(by selector: Selector) {}

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let str = string as? String { text = str }
        else if let astr = string as? NSAttributedString { text = astr.string }
        else { return }

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
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { updateMousePos(event) }
    override func mouseMoved(with event: NSEvent) { updateMousePos(event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { super.rightMouseDown(with: event); return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, translateMods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        updateMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, translateMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    private func updateMousePos(_ event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Ghostty expects point coordinates (not pixel); it applies the content scale internally
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(bounds.height - point.y), translateMods(event.modifierFlags))
    }

    // MARK: - Paste

    @objc func paste(_ sender: Any?) {
        guard let surface = surface else { return }
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        str.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(strlen(cstr)))
        }
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
        guard let chars = event.charactersIgnoringModifiers else { return false }
        // Normalize modifier flags to only the ones menus care about
        let eventMods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        for item in menu.items {
            if !item.keyEquivalent.isEmpty {
                let itemMods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if item.keyEquivalent == chars, itemMods == eventMods {
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
        if let surface = surface {
            GhosttyRuntime.shared.unregisterSurface(surface)
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    deinit { destroy() }
}
