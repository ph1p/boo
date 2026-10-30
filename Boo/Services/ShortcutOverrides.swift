import Cocoa

/// User rebinding of main menu shortcuts. Overrides are stored as specs
/// ("cmd+shift+d", "" for none) keyed by `MenuAction.id`, and applied to
/// menu items right after the menu is built. Every key path that matches
/// shortcuts (AppKit, `GhosttyView.menuHandlesEvent`, the palette) reads the
/// menu, so applying here is enough.
@MainActor
enum ShortcutOverrides {
    struct Shortcut: Equatable {
        var key: String
        var modifiers: NSEvent.ModifierFlags

        static let none = Shortcut(key: "", modifiers: [])

        var display: String { key.isEmpty ? "" : ActionRegistry.display(key: key, modifiers: modifiers) }
    }

    /// Each overridden item's own shortcut, by id, for "Reset".
    private(set) static var defaults: [String: Shortcut] = [:]
    /// Items already carrying an override, so a second pass over the same
    /// menu does not record the override as the default.
    private static let applied = NSHashTable<NSMenuItem>.weakObjects()

    static func apply(
        _ overrides: [String: String] = AppSettings.shared.shortcutOverrides,
        to menu: NSMenu? = NSApplication.shared.mainMenu
    ) {
        guard !overrides.isEmpty else { return }
        for action in ActionRegistry.actions(in: menu) {
            guard let spec = overrides[action.id], let shortcut = parse(spec) else { continue }
            let item = action.item
            if !applied.contains(item) {
                defaults[action.id] = Shortcut(key: action.keyEquivalent, modifiers: action.modifiers)
                applied.add(item)
            }
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    /// The shortcut the item has without an override.
    static func defaultShortcut(for action: MenuAction) -> Shortcut {
        defaults[action.id] ?? Shortcut(key: action.keyEquivalent, modifiers: action.modifiers)
    }

    // MARK: - Specs

    private static let namedKeys: [String: String] = [
        "space": " ", "return": "\r", "tab": "\t", "delete": "\u{8}", "escape": "\u{1B}",
        "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
        "up": String(UnicodeScalar(NSUpArrowFunctionKey)!),
        "down": String(UnicodeScalar(NSDownArrowFunctionKey)!),
    ]

    /// "cmd+shift+d" → ("d", ⇧⌘). "" → no shortcut. Nil when malformed.
    static func parse(_ spec: String) -> Shortcut? {
        if spec.isEmpty { return Shortcut.none }
        var parts = spec.lowercased().components(separatedBy: "+")
        // "cmd++" binds the plus key.
        if spec.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        if let named = namedKeys[keyName] { return Shortcut(key: named, modifiers: modifiers) }
        if keyName.hasPrefix("f"), let n = Int(keyName.dropFirst()), (1...12).contains(n) {
            return Shortcut(key: String(UnicodeScalar(NSF1FunctionKey + n - 1)!), modifiers: modifiers)
        }
        guard keyName.count == 1 else { return nil }
        return Shortcut(key: keyName, modifiers: modifiers)
    }

    static func spec(for shortcut: Shortcut) -> String {
        guard !shortcut.key.isEmpty else { return "" }
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) { parts.append("ctrl") }
        if shortcut.modifiers.contains(.option) { parts.append("opt") }
        if shortcut.modifiers.contains(.shift) { parts.append("shift") }
        if shortcut.modifiers.contains(.command) { parts.append("cmd") }
        let key = shortcut.key.lowercased()
        if let name = namedKeys.first(where: { $0.value == key })?.key {
            parts.append(name)
        } else if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
            (NSF1FunctionKey...NSF12FunctionKey).contains(Int(scalar.value))
        {
            parts.append("f\(Int(scalar.value) - NSF1FunctionKey + 1)")
        } else {
            parts.append(key)
        }
        return parts.joined(separator: "+")
    }

    /// The shortcut a key press records, or nil when it cannot be a menu
    /// shortcut: plain keys would steal typing, so a modifier other than ⇧
    /// is required, except for F1–F12.
    static func shortcut(for event: NSEvent) -> Shortcut? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let unshifted = event.characters(byApplyingModifiers: []), let scalar = unshifted.unicodeScalars.first
        else { return nil }
        let isFunctionKey = (NSF1FunctionKey...NSF12FunctionKey).contains(Int(scalar.value))
        guard isFunctionKey || !modifiers.subtracting(.shift).isEmpty else { return nil }
        let key: String
        switch event.keyCode {
        case 49: key = " "
        case 36, 76: key = "\r"
        case 48: key = "\t"
        case 51: key = "\u{8}"
        default: key = unshifted.lowercased()
        }
        guard key.unicodeScalars.count == 1 else { return nil }
        return Shortcut(key: key, modifiers: modifiers)
    }

    /// Items other than `id` that currently use `shortcut`.
    static func conflicts(with shortcut: Shortcut, excluding id: String, in actions: [MenuAction]) -> [MenuAction] {
        guard !shortcut.key.isEmpty else { return [] }
        return actions.filter {
            $0.id != id && !$0.isAlternate && $0.keyEquivalent.lowercased() == shortcut.key.lowercased()
                && $0.modifiers == shortcut.modifiers
        }
    }
}
