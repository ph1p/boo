import Carbon.HIToolbox
import Cocoa

/// A key plus modifiers for a global hotkey, parsed from text like "opt+space"
/// or "cmd+shift+t".
struct HotKeySpec: Equatable {
    /// Virtual key code (`kVK_*`).
    let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, ...).
    let modifiers: UInt32
    /// The key's name for display ("Space", "T", "F1").
    let keyName: String

    private static let modifierNames: [String: Int] = [
        "cmd": cmdKey, "command": cmdKey, "⌘": cmdKey,
        "opt": optionKey, "option": optionKey, "alt": optionKey, "⌥": optionKey,
        "ctrl": controlKey, "control": controlKey, "⌃": controlKey,
        "shift": shiftKey, "⇧": shiftKey
    ]

    private static let namedKeys: [String: (Int, String)] = [
        "space": (kVK_Space, "Space"), "tab": (kVK_Tab, "Tab"), "return": (kVK_Return, "Return"),
        "enter": (kVK_Return, "Return"), "escape": (kVK_Escape, "Esc"), "esc": (kVK_Escape, "Esc"),
        "`": (kVK_ANSI_Grave, "`"), "grave": (kVK_ANSI_Grave, "`"), "-": (kVK_ANSI_Minus, "-"),
        "=": (kVK_ANSI_Equal, "="), "[": (kVK_ANSI_LeftBracket, "["), "]": (kVK_ANSI_RightBracket, "]"),
        ";": (kVK_ANSI_Semicolon, ";"), "'": (kVK_ANSI_Quote, "'"), ",": (kVK_ANSI_Comma, ","),
        ".": (kVK_ANSI_Period, "."), "/": (kVK_ANSI_Slash, "/"), "\\": (kVK_ANSI_Backslash, "\\")
    ]

    private static let letters: [Int] = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
        kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z
    ]

    private static let digits: [Int] = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    private static let functionKeys: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
    ]

    /// Parses "mod+mod+key". A key needs at least one modifier, except F1–F12.
    static func parse(_ text: String) -> HotKeySpec? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var modifiers = 0
        for part in parts.dropLast() {
            guard let mod = modifierNames[part] else { return nil }
            modifiers |= mod
        }
        guard let (code, name) = key(last) else { return nil }
        let isFunctionKey = functionKeys.contains(code)
        guard modifiers != 0 || isFunctionKey else { return nil }
        return HotKeySpec(keyCode: UInt32(code), modifiers: UInt32(modifiers), keyName: name)
    }

    private static func key(_ name: String) -> (Int, String)? {
        if let named = namedKeys[name] { return named }
        if name.count == 1, let char = name.first {
            if let i = Array("abcdefghijklmnopqrstuvwxyz").firstIndex(of: char) {
                return (letters[i], name.uppercased())
            }
            if let digit = Int(name) { return (digits[digit], name) }
        }
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n) {
            return (functionKeys[n - 1], "F\(n)")
        }
        return nil
    }

    /// "⌥Space", "⌃⇧T" — modifiers in the standard macOS order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// The same combination as an `NSMenuItem` key equivalent, so menus and
    /// the shortcut list show it.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        let key: String
        switch keyName {
        case "Space": key = " "
        case "Tab": key = "\t"
        case "Return": key = "\r"
        case "Esc": key = "\u{1b}"
        default:
            if keyName.count > 1, keyName.hasPrefix("F"), let n = Int(keyName.dropFirst()),
                let scalar = UnicodeScalar(NSF1FunctionKey + n - 1)
            {
                key = String(Character(scalar))
            } else {
                key = keyName.lowercased()
            }
        }
        return (key, mask)
    }
}

/// A system-wide hotkey via Carbon `RegisterEventHotKey`, which needs no
/// Accessibility permission. Unregisters on deinit.
@MainActor
final class GlobalHotKey {
    let spec: HotKeySpec
    nonisolated(unsafe) private var ref: EventHotKeyRef?
    private let id: UInt32

    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var handler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x424F_4F48  // "BOOH"

    /// Nil when the system refuses the combination (another app owns it).
    init?(spec: HotKeySpec, action: @escaping () -> Void) {
        self.spec = spec
        id = Self.nextID
        Self.nextID += 1
        Self.installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            booLog(.warning, .app, "Global hotkey \(spec.display) not registered (status \(status))")
            return nil
        }
        self.ref = ref
        Self.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions.removeValue(forKey: id)
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKey = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                guard status == noErr, hotKey.signature == GlobalHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // The application event target dispatches on the main thread.
                MainActor.assumeIsolated { GlobalHotKey.actions[hotKey.id]?() }
                return noErr
            }, 1, &type, nil, &handler)
    }
}
