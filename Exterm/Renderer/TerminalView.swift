import Cocoa

class TerminalView: NSView {
    var terminal: VT100Terminal?
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    private(set) var cellFont: NSFont
    private(set) var cellWidth: CGFloat
    private(set) var cellHeight: CGFloat
    private var cellAscent: CGFloat

    private var cursorBlinkOn = true
    private var isFocused = false
    var onFocused: (() -> Void)?
    private var cursorBlinkTimer: Timer?
    private var resizeDebounceTimer: Timer?
    private var lastGridSize: (cols: Int, rows: Int) = (0, 0)
    private var settingsObserver: Any?

    // Font cache for bold/italic variants
    private var fontCache: [UInt32: NSFont] = [:]  // keyed by SymbolicTraits.rawValue

    // Text selection
    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }

    private static func measureFont(_ font: NSFont) -> (width: CGFloat, height: CGFloat, ascent: CGFloat) {
        let size = NSAttributedString(string: "M", attributes: [.font: font]).size()
        return (ceil(size.width), ceil(font.ascender - font.descender + font.leading), ceil(font.ascender))
    }

    override init(frame: NSRect) {
        let font = AppSettings.shared.resolvedFont()
        self.cellFont = font
        let m = Self.measureFont(font)
        self.cellWidth = m.width
        self.cellHeight = m.height
        self.cellAscent = m.ascent

        super.init(frame: frame)

        wantsLayer = true
        applyThemeBackground()

        setupCursorBlink()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyFontSettings()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var showCursor: Bool {
        isFocused && cursorBlinkOn
    }

    /// Unfocused panes show a dim outline cursor (always visible, no blink).
    private var showUnfocusedCursor: Bool {
        !isFocused
    }

    private func setupCursorBlink() {
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, self.isFocused, self.window?.isVisible == true else { return }
            self.cursorBlinkOn.toggle()
            self.needsDisplay = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        cursorBlinkOn = true
        needsDisplay = true
        onFocused?()

        let accent = AppSettings.shared.theme.accentColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = accent.copy(alpha: 0.4)
        layer?.shadowColor = accent
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 0.3

        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        needsDisplay = true

        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.shadowOpacity = 0

        return super.resignFirstResponder()
    }

    // MARK: - Grid Sizing

    private let padding = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

    var gridCols: Int {
        max(1, Int((bounds.width - padding.left - padding.right) / cellWidth))
    }

    var gridRows: Int {
        max(1, Int((bounds.height - padding.top - padding.bottom) / cellHeight))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.commitResize()
        }
    }

    private func scheduleResize() {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            self?.commitResize()
        }
    }

    private func commitResize() {
        let cols = gridCols
        let rows = gridRows
        if cols > 1, rows > 1, (cols != lastGridSize.cols || rows != lastGridSize.rows) {
            lastGridSize = (cols, rows)
            onResize?(cols, rows)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let terminal = terminal else { return }

        let theme = AppSettings.shared.theme
        let snap = terminal.snapshot()
        // Use actual screen dimensions to prevent out-of-bounds
        let rows = min(snap.rows, snap.screen.count)
        let cols = snap.cols

        // Background from theme
        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(bounds)

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = snap.cell(at: col, row: row)
                let style = cell.style

                let x = padding.left + CGFloat(col) * cellWidth
                let y = padding.top + CGFloat(row) * cellHeight

                // Resolve default colors through theme
                var fg = (style.fg == .defaultFG) ? theme.foreground : style.fg
                var bg = (style.bg == .defaultBG) ? theme.background : style.bg
                if style.inverse { swap(&fg, &bg) }

                let isCursorPos = col == snap.cursorX && row == snap.cursorY
                let activeCursor = isCursorPos && showCursor
                let dimCursor = isCursorPos && showUnfocusedCursor
                let isSelected = isCellSelected(col: col, row: row, cols: cols)
                let cursorStyle = AppSettings.shared.cursorStyle
                let cellRect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)

                // Cell background
                if isSelected {
                    ctx.setFillColor(theme.selection.cgColor)
                    ctx.fill(cellRect)
                } else if bg != theme.background {
                    ctx.setFillColor(bg.cgColor)
                    ctx.fill(cellRect)
                }

                // Active cursor (focused pane, blinking)
                if activeCursor && !isSelected {
                    drawCursor(ctx: ctx, style: cursorStyle, rect: cellRect, color: fg.cgColor, filled: true)
                }

                // Unfocused cursor (dim outline, always visible)
                if dimCursor && !isSelected && !activeCursor {
                    let dimColor = theme.chromeMuted.withAlphaComponent(0.4).cgColor
                    drawCursor(ctx: ctx, style: .blockOutline, rect: cellRect, color: dimColor, filled: false)
                }

                // Character
                let char = cell.character
                if char != " " {
                    let textColor: TerminalColor
                    if activeCursor && !isSelected && cursorStyle == .block {
                        textColor = bg // Inverted on filled block cursor
                    } else {
                        textColor = fg
                    }
                    drawCharacter(ctx: ctx, char: char, x: x, y: y, color: textColor, style: style)
                }

                // Underline
                if style.underline {
                    ctx.setStrokeColor(fg.cgColor)
                    ctx.setLineWidth(1)
                    let uy = y + cellHeight - 1
                    ctx.move(to: CGPoint(x: x, y: uy))
                    ctx.addLine(to: CGPoint(x: x + cellWidth, y: uy))
                    ctx.strokePath()
                }
            }
        }
    }

    private func drawCursor(ctx: CGContext, style: CursorStyle, rect: CGRect, color: CGColor, filled: Bool) {
        switch style {
        case .block:
            if filled {
                ctx.setFillColor(color)
                ctx.fill(rect)
            } else {
                // Outline block
                ctx.setStrokeColor(color)
                ctx.setLineWidth(1)
                ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        case .beam:
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        case .underline:
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case .blockOutline:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawCharacter(ctx: CGContext, char: Character, x: CGFloat, y: CGFloat,
                                color: TerminalColor, style: CellStyle) {
        let str = String(char)

        var font = cellFont
        if style.bold || style.italic {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if style.bold { traits.insert(.bold) }
            if style.italic { traits.insert(.italic) }
            let key = traits.rawValue
            if let cached = fontCache[key] {
                font = cached
            } else {
                let descriptor = cellFont.fontDescriptor.withSymbolicTraits(traits)
                let resolved = NSFont(descriptor: descriptor, size: cellFont.pointSize) ?? cellFont
                fontCache[key] = resolved
                font = resolved
            }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.nsColor
        ]

        let attrStr = NSAttributedString(string: str, attributes: attrs)
        // NSAttributedString.draw(at:) works correctly in flipped views
        attrStr.draw(at: NSPoint(x: x, y: y))
    }

    // MARK: - Color Helpers (use TerminalColor.cgColor / .nsColor extensions)

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        cursorBlinkOn = true
        // Only clear selection on printable input, not on arrow keys / modifiers
        if selectionStart != nil && !event.modifierFlags.contains(.command) {
            if let chars = event.characters, !chars.isEmpty {
                let first = chars.unicodeScalars.first!.value
                // Don't clear on escape sequences (arrows etc produce chars starting with \e)
                if first >= 0x20 && first != 0x7F {
                    clearSelection()
                }
            }
        }
        if let data = KeyMapping.encode(event: event) {
            onInput?(data)
        }
    }

    override func flagsChanged(with event: NSEvent) {}

    // MARK: - Paste

    @objc func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        if let data = string.data(using: .utf8) {
            onInput?(data)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                if let text = selectedText(), !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    selectionStart = nil
                    selectionEnd = nil
                    needsDisplay = true
                    return true
                }
            case "v":
                paste(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Mouse / Selection

    private enum SelectionMode {
        case character
        case word
        case line
    }
    private var selectionMode: SelectionMode = .character
    private var wordSelectionAnchor: (start: (col: Int, row: Int), end: (col: Int, row: Int))?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pos = cellPosition(for: event)

        switch event.clickCount {
        case 2:
            // Double-click: select word
            selectWord(at: pos)
            selectionMode = .word
            wordSelectionAnchor = (selectionStart!, selectionEnd!)
            isDragging = true
        case 3:
            // Triple-click: select line
            selectLine(at: pos.row)
            selectionMode = .line
            isDragging = true
        default:
            // Single click: start character selection
            selectionStart = pos
            selectionEnd = pos
            selectionMode = .character
            wordSelectionAnchor = nil
            isDragging = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let pos = cellPosition(for: event)

        switch selectionMode {
        case .character:
            selectionEnd = pos
        case .word:
            // Extend selection by whole words
            guard let anchor = wordSelectionAnchor else { return }
            let dragWord = wordBounds(at: pos)
            let anchorLinear = anchor.start.row * 10000 + anchor.start.col
            let dragLinear = pos.row * 10000 + pos.col
            if dragLinear < anchorLinear {
                selectionStart = dragWord.start
                selectionEnd = anchor.end
            } else {
                selectionStart = anchor.start
                selectionEnd = dragWord.end
            }
        case .line:
            // Extend selection by whole lines
            guard let start = selectionStart else { return }
            if pos.row < start.row {
                selectionStart = (col: 0, row: pos.row)
                let cols = terminal?.snapshot().cols ?? 80
                selectionEnd = (col: cols - 1, row: start.row)
            } else {
                selectionStart = (col: 0, row: min(start.row, pos.row))
                let cols = terminal?.snapshot().cols ?? 80
                selectionEnd = (col: cols - 1, row: pos.row)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        // Single click with no drag: clear selection
        if selectionMode == .character,
           let s = selectionStart, let e = selectionEnd,
           s.col == e.col && s.row == e.row {
            clearSelection()
        }
    }

    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        wordSelectionAnchor = nil
        needsDisplay = true
    }

    func selectAll() {
        guard let terminal = terminal else { return }
        let snap = terminal.snapshot()
        selectionStart = (col: 0, row: 0)
        selectionEnd = (col: snap.cols - 1, row: snap.rows - 1)
        needsDisplay = true
    }

    private func cellPosition(for event: NSEvent) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let col = max(0, Int((point.x - padding.left) / cellWidth))
        let row = max(0, Int((point.y - padding.top) / cellHeight))
        return (col, row)
    }

    private func selectWord(at pos: (col: Int, row: Int)) {
        let bounds = wordBounds(at: pos)
        selectionStart = bounds.start
        selectionEnd = bounds.end
        needsDisplay = true
    }

    private func wordBounds(at pos: (col: Int, row: Int)) -> (start: (col: Int, row: Int), end: (col: Int, row: Int)) {
        guard let terminal = terminal else { return (pos, pos) }
        let snap = terminal.snapshot()
        let row = min(pos.row, snap.rows - 1)
        let col = min(pos.col, snap.cols - 1)

        let char = snap.cell(at: col, row: row).character
        let isWordChar = { (c: Character) -> Bool in
            c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == "/"
        }

        // If clicked on whitespace/symbol, select just that cell
        guard isWordChar(char) else { return (pos, pos) }

        // Scan left
        var startCol = col
        while startCol > 0 && isWordChar(snap.cell(at: startCol - 1, row: row).character) {
            startCol -= 1
        }

        // Scan right
        var endCol = col
        while endCol < snap.cols - 1 && isWordChar(snap.cell(at: endCol + 1, row: row).character) {
            endCol += 1
        }

        return (start: (col: startCol, row: row), end: (col: endCol, row: row))
    }

    private func selectLine(at row: Int) {
        guard let terminal = terminal else { return }
        let snap = terminal.snapshot()
        let r = min(row, snap.rows - 1)
        selectionStart = (col: 0, row: r)
        selectionEnd = (col: snap.cols - 1, row: r)
        needsDisplay = true
    }

    /// Returns the selected text or nil.
    func selectedText() -> String? {
        guard let terminal = terminal,
              let start = selectionStart,
              let end = selectionEnd else { return nil }

        let snap = terminal.snapshot()
        let (s, e) = normalizedSelection(start: start, end: end, cols: snap.cols)

        var result = ""
        for row in s.row...e.row {
            let colStart = (row == s.row) ? s.col : 0
            let colEnd = (row == e.row) ? e.col : snap.cols - 1
            for col in colStart...min(colEnd, snap.cols - 1) {
                result.append(snap.cell(at: col, row: row).character)
            }
            if row < e.row {
                result.append("\n")
            }
        }
        // Trim trailing spaces per line
        return result.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    private func normalizedSelection(start: (col: Int, row: Int), end: (col: Int, row: Int), cols: Int) -> (start: (col: Int, row: Int), end: (col: Int, row: Int)) {
        let sLinear = start.row * cols + start.col
        let eLinear = end.row * cols + end.col
        if sLinear <= eLinear {
            return (start, end)
        }
        return (end, start)
    }

    private func isCellSelected(col: Int, row: Int, cols: Int) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        let (s, e) = normalizedSelection(start: start, end: end, cols: cols)
        let pos = row * cols + col
        let sPos = s.row * cols + s.col
        let ePos = e.row * cols + e.col
        return pos >= sPos && pos <= ePos
    }

    private func applyFontSettings() {
        let font = AppSettings.shared.resolvedFont()
        self.cellFont = font
        let m = Self.measureFont(font)
        self.cellWidth = m.width
        self.cellHeight = m.height
        self.cellAscent = m.ascent
        fontCache.removeAll()
        lastGridSize = (0, 0)
        applyThemeBackground()
        commitResize()
        needsDisplay = true
    }

    private func applyThemeBackground() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.background.cgColor
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
