import Foundation
import Cocoa

/// Color representation for terminal cells
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

    // Standard 16 ANSI colors
    static let ansiColors: [TerminalColor] = [
        TerminalColor(r: 0, g: 0, b: 0),         // 0 black
        TerminalColor(r: 205, g: 49, b: 49),      // 1 red
        TerminalColor(r: 13, g: 188, b: 121),     // 2 green
        TerminalColor(r: 229, g: 229, b: 16),     // 3 yellow
        TerminalColor(r: 36, g: 114, b: 200),     // 4 blue
        TerminalColor(r: 188, g: 63, b: 188),     // 5 magenta
        TerminalColor(r: 17, g: 168, b: 205),     // 6 cyan
        TerminalColor(r: 204, g: 204, b: 204),    // 7 white
        TerminalColor(r: 102, g: 102, b: 102),    // 8 bright black
        TerminalColor(r: 241, g: 76, b: 76),      // 9 bright red
        TerminalColor(r: 35, g: 209, b: 139),     // 10 bright green
        TerminalColor(r: 245, g: 245, b: 67),     // 11 bright yellow
        TerminalColor(r: 59, g: 142, b: 234),     // 12 bright blue
        TerminalColor(r: 214, g: 112, b: 214),    // 13 bright magenta
        TerminalColor(r: 41, g: 184, b: 219),     // 14 bright cyan
        TerminalColor(r: 242, g: 242, b: 242),    // 15 bright white
    ]
}

/// Style attributes for a terminal cell
struct CellStyle: Equatable {
    var fg: TerminalColor
    var bg: TerminalColor
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var inverse: Bool

    static let `default` = CellStyle(
        fg: .defaultFG,
        bg: .defaultBG,
        bold: false,
        italic: false,
        underline: false,
        inverse: false
    )
}

/// A single terminal cell
struct TerminalCell: Equatable {
    var character: Character
    var style: CellStyle

    static let blank = TerminalCell(character: " ", style: .default)
}

/// Cursor shape
enum CursorShape {
    case block
    case beam
    case underline
}

/// Thread-safe snapshot of terminal state for rendering.
struct TerminalSnapshot {
    let cols: Int
    let rows: Int
    let screen: [[TerminalCell]]
    let cursorX: Int
    let cursorY: Int

    func cell(at col: Int, row: Int) -> TerminalCell {
        guard row >= 0, row < screen.count, col >= 0, col < screen[row].count else { return .blank }
        return screen[row][col]
    }
}

/// Protocol abstracting terminal emulation
protocol TerminalBackend: AnyObject {
    var cols: Int { get }
    var rows: Int { get }
    var cursorX: Int { get }
    var cursorY: Int { get }
    var cursorShape: CursorShape { get }
    var title: String { get }

    func resize(cols: Int, rows: Int)
    func feed(_ data: Data)
    func cell(at col: Int, row: Int) -> TerminalCell
}
