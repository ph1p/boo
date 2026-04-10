import Cocoa
import Foundation

/// Color representation for terminal cells and theming.
struct TerminalColor: Equatable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var cgColor: CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var nsColor: NSColor {
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static let defaultFG = TerminalColor(r: 228, g: 228, b: 232)
    static let defaultBG = TerminalColor(r: 21, g: 21, b: 23)
    static let black = TerminalColor(r: 0, g: 0, b: 0)
    static let white = TerminalColor(r: 255, g: 255, b: 255)
}

extension TerminalColor {
    var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    /// Relative luminance (0–1) used for contrast decisions.
    var luminance: Double {
        0.299 * Double(r) / 255 + 0.587 * Double(g) / 255 + 0.114 * Double(b) / 255
    }
}
