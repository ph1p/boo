import Foundation
import Cocoa

/// Color representation for terminal cells and theming.
struct TerminalColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var cgColor: CGColor {
        CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    var nsColor: NSColor {
        NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    static let defaultFG = TerminalColor(r: 228, g: 228, b: 232)
    static let defaultBG = TerminalColor(r: 21, g: 21, b: 23)
    static let black = TerminalColor(r: 0, g: 0, b: 0)
    static let white = TerminalColor(r: 255, g: 255, b: 255)

    static let ansiColors: [TerminalColor] = [
        TerminalColor(r: 0, g: 0, b: 0),
        TerminalColor(r: 205, g: 49, b: 49),
        TerminalColor(r: 13, g: 188, b: 121),
        TerminalColor(r: 229, g: 229, b: 16),
        TerminalColor(r: 36, g: 114, b: 200),
        TerminalColor(r: 188, g: 63, b: 188),
        TerminalColor(r: 17, g: 168, b: 205),
        TerminalColor(r: 204, g: 204, b: 204),
        TerminalColor(r: 102, g: 102, b: 102),
        TerminalColor(r: 241, g: 76, b: 76),
        TerminalColor(r: 35, g: 209, b: 139),
        TerminalColor(r: 245, g: 245, b: 67),
        TerminalColor(r: 59, g: 142, b: 234),
        TerminalColor(r: 214, g: 112, b: 214),
        TerminalColor(r: 41, g: 184, b: 219),
        TerminalColor(r: 242, g: 242, b: 242),
    ]
}
