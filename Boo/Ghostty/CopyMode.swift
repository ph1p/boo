import Cocoa

/// Keyboard copy mode: a vi-style cursor over the whole scrollback that
/// selects and copies text without the mouse. Positions are screen rows
/// (0 = oldest scrollback line), so the cursor stays on its text while the
/// viewport scrolls or new output arrives.
@MainActor
struct CopyMode {
    nonisolated struct Point: Equatable, Comparable {
        var row: Int
        var column: Int

        static func < (a: Point, b: Point) -> Bool { (a.row, a.column) < (b.row, b.column) }
    }

    enum Selection { case none, character, line }

    enum Motion {
        case left, right, up, down
        case wordForward, wordBackward, wordEnd
        case lineStart, firstNonBlank, lineEnd
        case top, bottom
        case halfPageUp, halfPageDown, pageUp, pageDown
    }

    var cursor: Point
    var anchor: Point?
    var selection: Selection = .none
    /// Rows in the screen (scrollback plus active area) and columns per row.
    var rows: Int
    var columns: Int
    /// Rows in the viewport, for page motions.
    var pageRows: Int
    /// A screen row's cells; a wide character is followed by an empty cell.
    let cells: (Int) -> [String]

    init(cursor: Point, rows: Int, columns: Int, pageRows: Int, cells: @escaping (Int) -> [String]) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.pageRows = max(1, pageRows)
        self.cells = cells
        self.cursor = Point(
            row: min(max(0, cursor.row), self.rows - 1), column: min(max(0, cursor.column), self.columns - 1))
    }

    /// A line of text as terminal cells.
    static func cells(of line: String) -> [String] {
        var result: [String] = []
        for character in line where character != "\n" && character != "\r" {
            result.append(String(character))
            if LinkResolver.isWide(character) { result.append("") }
        }
        return result
    }

    mutating func move(_ motion: Motion, count: Int = 1) {
        let n = max(1, count)
        switch motion {
        case .left: cursor.column = max(0, cursor.column - n)
        case .right: cursor.column = min(columns - 1, cursor.column + n)
        case .up: cursor.row = max(0, cursor.row - n)
        case .down: cursor.row = min(rows - 1, cursor.row + n)
        case .halfPageUp: cursor.row = max(0, cursor.row - n * max(1, pageRows / 2))
        case .halfPageDown: cursor.row = min(rows - 1, cursor.row + n * max(1, pageRows / 2))
        case .pageUp: cursor.row = max(0, cursor.row - n * pageRows)
        case .pageDown: cursor.row = min(rows - 1, cursor.row + n * pageRows)
        case .lineStart: cursor.column = 0
        case .firstNonBlank:
            cursor.column = cells(cursor.row).firstIndex { Self.charClass($0) != 0 } ?? 0
        case .lineEnd:
            let line = cells(cursor.row)
            cursor.column = min(columns - 1, (line.lastIndex { Self.charClass($0) != 0 } ?? 0))
        case .top: cursor = Point(row: 0, column: 0)
        case .bottom: cursor = Point(row: rows - 1, column: 0)
        case .wordForward: for _ in 0..<n { wordForward() }
        case .wordBackward: for _ in 0..<n { wordBackward() }
        case .wordEnd: for _ in 0..<n { wordEnd() }
        }
        if selection == .none { anchor = nil }
    }

    /// Starts, switches or (when already in that kind) ends a selection.
    mutating func toggleSelection(_ kind: Selection) {
        if selection == kind {
            selection = .none
            anchor = nil
        } else {
            if selection == .none { anchor = cursor }
            selection = kind
        }
    }

    /// The selected span, inclusive and ordered; nil without a selection.
    var range: (start: Point, end: Point)? {
        guard selection != .none, let anchor else { return nil }
        var start = min(anchor, cursor)
        var end = max(anchor, cursor)
        if selection == .line {
            start.column = 0
            end.column = columns - 1
        }
        return (start, end)
    }

    // MARK: - Words

    /// 0 blank, 1 word, 2 punctuation. The spacer after a wide character
    /// counts as a word so it does not split one.
    static func charClass(_ cell: String) -> Int {
        guard let character = cell.first else { return cell.isEmpty ? 1 : 0 }
        if character.isWhitespace { return 0 }
        if character.isLetter || character.isNumber || character == "_" { return 1 }
        return 2
    }

    private var lineCache: [Int: [String]] = [:]

    private mutating func line(_ row: Int) -> [String] {
        if let cached = lineCache[row] { return cached }
        let line = cells(row)
        lineCache[row] = line
        return line
    }

    private mutating func charClass(at point: Point) -> Int {
        let line = line(point.row)
        return point.column < line.count ? Self.charClass(line[point.column]) : 0
    }

    private mutating func next(_ point: Point) -> Point? {
        if point.column + 1 < max(1, line(point.row).count) { return Point(row: point.row, column: point.column + 1) }
        return point.row + 1 < rows ? Point(row: point.row + 1, column: 0) : nil
    }

    private mutating func previous(_ point: Point) -> Point? {
        if point.column > 0 {
            return Point(row: point.row, column: min(point.column - 1, max(0, line(point.row).count - 1)))
        }
        guard point.row > 0 else { return nil }
        return Point(row: point.row - 1, column: max(0, line(point.row - 1).count - 1))
    }

    private mutating func wordForward() {
        var point = cursor
        let start = charClass(at: point)
        if start != 0 {
            while let n = next(point), n.row == point.row, charClass(at: n) == start { point = n }
        }
        guard var p = next(point) else { return }
        while charClass(at: p) == 0, let n = next(p) { p = n }
        if charClass(at: p) != 0 { cursor = p }
        lineCache.removeAll()
    }

    private mutating func wordBackward() {
        guard var point = previous(cursor) else { return }
        while charClass(at: point) == 0, let p = previous(point) { point = p }
        let kind = charClass(at: point)
        while let p = previous(point), p.row == point.row, charClass(at: p) == kind { point = p }
        cursor = point
        lineCache.removeAll()
    }

    private mutating func wordEnd() {
        guard var point = next(cursor) else { return }
        while charClass(at: point) == 0, let n = next(point) { point = n }
        let kind = charClass(at: point)
        while let n = next(point), n.row == point.row, charClass(at: n) == kind { point = n }
        if kind != 0 { cursor = point }
        lineCache.removeAll()
    }
}

/// Draws the copy mode cursor and selection over a terminal and turns keys
/// into motions. Keys reach it through `GhosttyView.keyDown`.
final class CopyModeOverlay: NSView {
    private(set) var state: CopyMode
    private let cellSize: CGSize
    /// Screen row at the top of the viewport, and viewport height in rows.
    private let viewport: () -> (top: Int, rows: Int)
    private let onScroll: (_ top: Int) -> Void
    private let onCopy: (CopyMode.Point, CopyMode.Point) -> Void
    private let onExit: () -> Void
    private var count = ""

    init(
        frame: NSRect, state: CopyMode, cellSize: CGSize,
        viewport: @escaping () -> (top: Int, rows: Int),
        onScroll: @escaping (Int) -> Void,
        onCopy: @escaping (CopyMode.Point, CopyMode.Point) -> Void,
        onExit: @escaping () -> Void
    ) {
        self.state = state
        self.cellSize = cellSize
        self.viewport = viewport
        self.onScroll = onScroll
        self.onCopy = onCopy
        self.onExit = onExit
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            "Copy mode. Move with arrow keys or h j k l, v to select, y to copy, Escape to leave.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { onExit() }

    /// Every key goes here while active; unknown keys are swallowed.
    func handle(_ event: NSEvent) {
        let control = event.modifierFlags.contains(.control)
        let chars = event.charactersIgnoringModifiers ?? ""
        let n = Int(count) ?? 1

        var motion: CopyMode.Motion?
        switch event.keyCode {
        case 53:  // Escape: drop the selection first, then leave
            count = ""
            if state.selection != .none { state.toggleSelection(state.selection) } else { onExit() }
            needsDisplay = true
            return
        case 36, 76:  // Return copies, like y
            copySelection()
            return
        case 123: motion = .left
        case 124: motion = .right
        case 125: motion = .down
        case 126: motion = .up
        case 115: motion = .lineStart
        case 119: motion = .lineEnd
        case 116: motion = .pageUp
        case 121: motion = .pageDown
        default: break
        }

        if motion == nil, control {
            switch chars.lowercased() {
            case "u": motion = .halfPageUp
            case "d": motion = .halfPageDown
            case "b": motion = .pageUp
            case "f": motion = .pageDown
            default: break
            }
        } else if motion == nil {
            if let digit = chars.first, digit.isNumber, digit != "0" || !count.isEmpty {
                count.append(digit)
                return
            }
            switch chars {
            case "h": motion = .left
            case "l": motion = .right
            case "j": motion = .down
            case "k": motion = .up
            case "w", "W": motion = .wordForward
            case "b", "B": motion = .wordBackward
            case "e", "E": motion = .wordEnd
            case "0": motion = .lineStart
            case "^": motion = .firstNonBlank
            case "$": motion = .lineEnd
            case "g": motion = .top
            case "G": motion = .bottom
            case "v": state.toggleSelection(.character)
            case "V": state.toggleSelection(.line)
            case "y":
                copySelection()
                return
            case "q": onExit()
            default: break
            }
        }
        count = ""
        if let motion {
            state.move(motion, count: n)
            scrollToCursor()
        }
        needsDisplay = true
    }

    /// Copies the selection, or the cursor's line when nothing is selected.
    private func copySelection() {
        if let range = state.range {
            onCopy(range.start, range.end)
        } else {
            let row = state.cursor.row
            onCopy(CopyMode.Point(row: row, column: 0), CopyMode.Point(row: row, column: state.columns - 1))
        }
    }

    private func scrollToCursor() {
        let view = viewport()
        if state.cursor.row < view.top {
            onScroll(state.cursor.row)
        } else if state.cursor.row >= view.top + view.rows {
            onScroll(state.cursor.row - view.rows + 1)
        }
    }

    /// The screen grew or the viewport moved; rows and page size follow.
    func update(rows: Int, pageRows: Int) {
        state.rows = max(1, rows)
        state.pageRows = max(1, pageRows)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppSettings.shared.theme
        let pad = GhosttyView.gridPadding
        let view = viewport()
        func rect(row: Int, from: Int, to: Int) -> CGRect {
            CGRect(
                x: pad + CGFloat(from) * cellSize.width, y: pad + CGFloat(row - view.top) * cellSize.height,
                width: CGFloat(to - from + 1) * cellSize.width, height: cellSize.height)
        }

        if let range = state.range {
            theme.accentColor.withAlphaComponent(0.3).setFill()
            let first = max(range.start.row, view.top)
            let last = min(range.end.row, view.top + view.rows - 1)
            if first <= last {
                for row in first...last {
                    let from = row == range.start.row ? range.start.column : 0
                    let to = row == range.end.row ? range.end.column : state.columns - 1
                    rect(row: row, from: from, to: to).fill()
                }
            }
        }

        if (view.top..<(view.top + view.rows)).contains(state.cursor.row) {
            let cursor = rect(row: state.cursor.row, from: state.cursor.column, to: state.cursor.column)
            theme.accentColor.withAlphaComponent(0.45).setFill()
            cursor.fill()
            theme.accentColor.setStroke()
            let outline = NSBezierPath(rect: cursor.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        let mode =
            switch state.selection {
            case .none: "COPY"
            case .character: "VISUAL"
            case .line: "VISUAL LINE"
            }
        let text = "\(mode)  \(state.cursor.row + 1)/\(state.rows)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: theme.background.nsColor
        ]
        let size = text.size(withAttributes: attrs)
        let badge = CGRect(
            x: bounds.maxX - size.width - 18, y: 6, width: size.width + 10, height: size.height + 4)
        theme.accentColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 2), withAttributes: attrs)
    }
}
