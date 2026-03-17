import Cocoa

enum KeyMapping {
    /// Encode an NSEvent key event into bytes to send to the PTY
    static func encode(event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        // Handle special keys first
        if let special = encodeSpecialKey(keyCode: keyCode, modifiers: modifiers) {
            return special
        }

        // Handle Ctrl+key combinations
        if modifiers.contains(.control) {
            if let chars = event.charactersIgnoringModifiers?.lowercased(), let char = chars.first {
                let code = char.asciiValue
                if let code = code, code >= 0x61, code <= 0x7A {
                    // Ctrl+a through Ctrl+z -> 0x01 through 0x1A
                    return Data([code - 0x60])
                }
                switch char {
                case "[": return Data([0x1B])
                case "\\": return Data([0x1C])
                case "]": return Data([0x1D])
                case "^", "6": return Data([0x1E])
                case "_", "-": return Data([0x1F])
                case "@", " ": return Data([0x00])
                default: break
                }
            }
        }

        // Alt sends ESC prefix
        if modifiers.contains(.option) {
            if let chars = event.charactersIgnoringModifiers, let data = chars.data(using: .utf8) {
                var result = Data([0x1B])
                result.append(data)
                return result
            }
        }

        // Regular characters
        if let chars = event.characters, !chars.isEmpty {
            return chars.data(using: .utf8)
        }

        return nil
    }

    private static func encodeSpecialKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Data? {
        let shift = modifiers.contains(.shift)
        let ctrl = modifiers.contains(.control)
        let alt = modifiers.contains(.option)

        // Modifier parameter for CSI sequences: 1 + (shift*1 + alt*2 + ctrl*4)
        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        let hasModifier = mod > 1

        switch keyCode {
        case 126: // Up
            return hasModifier ? csi("1;\(mod)A") : csi("A")
        case 125: // Down
            return hasModifier ? csi("1;\(mod)B") : csi("B")
        case 124: // Right
            return hasModifier ? csi("1;\(mod)C") : csi("C")
        case 123: // Left
            return hasModifier ? csi("1;\(mod)D") : csi("D")
        case 115: // Home
            return hasModifier ? csi("1;\(mod)H") : csi("H")
        case 119: // End
            return hasModifier ? csi("1;\(mod)F") : csi("F")
        case 116: // Page Up
            return hasModifier ? csi("5;\(mod)~") : csi("5~")
        case 121: // Page Down
            return hasModifier ? csi("6;\(mod)~") : csi("6~")
        case 117: // Delete (forward)
            return hasModifier ? csi("3;\(mod)~") : csi("3~")
        case 51: // Backspace
            return Data([0x7F])
        case 36: // Return
            return Data([0x0D])
        case 48: // Tab
            if shift {
                return csi("Z")
            }
            return Data([0x09])
        case 53: // Escape
            return Data([0x1B])
        case 122: return functionKey(1, mod: mod)  // F1
        case 120: return functionKey(2, mod: mod)  // F2
        case 99:  return functionKey(3, mod: mod)  // F3
        case 118: return functionKey(4, mod: mod)  // F4
        case 96:  return functionKey(5, mod: mod)  // F5
        case 97:  return functionKey(6, mod: mod)  // F6
        case 98:  return functionKey(7, mod: mod)  // F7
        case 100: return functionKey(8, mod: mod)  // F8
        case 101: return functionKey(9, mod: mod)  // F9
        case 109: return functionKey(10, mod: mod) // F10
        case 103: return functionKey(11, mod: mod) // F11
        case 111: return functionKey(12, mod: mod) // F12
        default:
            return nil
        }
    }

    private static func csi(_ seq: String) -> Data {
        Data("\u{1B}[\(seq)".utf8)
    }

    private static func functionKey(_ n: Int, mod: Int) -> Data {
        let codes = [0, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24]
        guard n >= 1, n <= 12 else { return Data() }
        let code = codes[n]
        if mod > 1 {
            return csi("\(code);\(mod)~")
        }
        return csi("\(code)~")
    }
}
