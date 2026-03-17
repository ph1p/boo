import Foundation

/// Built-in VT100/xterm terminal emulator.
/// Implements the TerminalBackend protocol with ANSI/VT100 escape sequence parsing.
final class VT100Terminal: TerminalBackend {
    private let lock = NSLock()

    /// ANSI color palette — can be overridden by theme
    var ansiPalette: [TerminalColor] = TerminalColor.ansiColors

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var cursorX: Int = 0
    private(set) var cursorY: Int = 0
    private(set) var cursorShape: CursorShape = .block
    private(set) var title: String = "Exterm"
    private(set) var currentDirectory: String?
    var onDirectoryChanged: ((String) -> Void)?

    private var screen: [[TerminalCell]]
    private var altScreen: [[TerminalCell]]?
    private var currentStyle: CellStyle = .default
    private var savedCursorX: Int = 0
    private var savedCursorY: Int = 0
    private var savedStyle: CellStyle = .default

    // Scroll region
    private var scrollTop: Int = 0
    private var scrollBottom: Int

    // Parser state
    private enum ParserState {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
        case charset
    }

    private var state: ParserState = .ground
    private var csiParams: [Int] = []
    private var currentParam: String = ""
    private var csiPrivate: Bool = false
    private var oscString: String = ""

    // Origin mode: cursor positions relative to scroll region
    private var originMode: Bool = false
    // Auto-wrap mode
    private var autoWrap: Bool = true
    // Pending wrap (cursor at right margin, next printable wraps)
    private var pendingWrap: Bool = false
    // Bracket paste mode
    private var bracketPasteMode: Bool = false
    // Application cursor keys
    private var applicationCursorKeys: Bool = false

    // Tab stops
    private var tabStops: [Int] = []

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        self.screen = Self.makeScreen(cols: cols, rows: rows)
        initTabStops()
    }

    private static func makeScreen(cols: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell.blank, count: cols), count: rows)
    }

    private func initTabStops() {
        tabStops = Array(stride(from: 0, to: cols, by: 8))
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        lock.lock()
        defer { lock.unlock() }
        _resize(cols: newCols, rows: newRows)
    }

    private func _resize(cols: Int, rows: Int) {
        let oldCols = self.cols
        let oldRows = self.rows
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        self.scrollTop = 0

        var newScreen = Self.makeScreen(cols: cols, rows: rows)
        for row in 0..<min(oldRows, rows) {
            for col in 0..<min(oldCols, cols) {
                newScreen[row][col] = screen[row][col]
            }
        }
        screen = newScreen
        cursorX = min(cursorX, cols - 1)
        cursorY = min(cursorY, rows - 1)
        initTabStops()
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            let byte = bytes[i]
            // If we're in ground state and this is a UTF-8 lead byte, decode the full character
            if state == .ground && byte >= 0x80 {
                let (char, consumed) = decodeUTF8(bytes, from: i)
                if let char = char {
                    printChar(char)
                    i += consumed
                    continue
                }
                // Invalid UTF-8, skip byte
                i += 1
                continue
            }
            processByte(byte)
            i += 1
        }
    }

    private func decodeUTF8(_ bytes: [UInt8], from start: Int) -> (Character?, Int) {
        let byte = bytes[start]
        let seqLen: Int
        if byte & 0xE0 == 0xC0 { seqLen = 2 }
        else if byte & 0xF0 == 0xE0 { seqLen = 3 }
        else if byte & 0xF8 == 0xF0 { seqLen = 4 }
        else { return (nil, 1) } // Invalid lead byte or continuation byte

        guard start + seqLen <= bytes.count else { return (nil, 1) }
        // Verify continuation bytes
        for j in 1..<seqLen {
            guard bytes[start + j] & 0xC0 == 0x80 else { return (nil, 1) }
        }

        let data = Data(bytes[start..<(start + seqLen)])
        if let str = String(data: data, encoding: .utf8), let char = str.first {
            return (char, seqLen)
        }
        return (nil, 1)
    }

    func cell(at col: Int, row: Int) -> TerminalCell {
        lock.lock()
        defer { lock.unlock() }
        guard row >= 0, row < rows, col >= 0, col < cols else {
            return .blank
        }
        return screen[row][col]
    }

    /// Snapshot all state needed for rendering under one lock acquisition.
    func snapshot() -> TerminalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TerminalSnapshot(
            cols: cols,
            rows: rows,
            screen: screen,
            cursorX: cursorX,
            cursorY: cursorY
        )
    }

    // MARK: - Byte Processing

    private func processByte(_ byte: UInt8) {
        switch state {
        case .ground:
            processGround(byte)
        case .escape:
            processEscape(byte)
        case .csi:
            processCSI(byte)
        case .osc:
            processOSC(byte)
        case .oscEscape:
            processOSCEscape(byte)
        case .charset:
            // Consume one byte for charset designation, ignore for now
            state = .ground
        }
    }

    private func processGround(_ byte: UInt8) {
        switch byte {
        case 0x00: // NUL - ignore
            break
        case 0x07: // BEL
            break
        case 0x08: // BS
            pendingWrap = false
            if cursorX > 0 { cursorX -= 1 }
        case 0x09: // HT (tab)
            pendingWrap = false
            let nextTab = tabStops.first(where: { $0 > cursorX }) ?? (cols - 1)
            cursorX = min(nextTab, cols - 1)
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            pendingWrap = false
            lineFeed()
        case 0x0D: // CR
            pendingWrap = false
            cursorX = 0
        case 0x1B: // ESC
            state = .escape
        case 0x20...0x7E:
            printChar(Character(UnicodeScalar(byte)))
        default:
            break
        }
    }

    private func processEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // [  -> CSI
            state = .csi
            csiParams = []
            currentParam = ""
            csiPrivate = false
        case 0x5D: // ] -> OSC
            state = .osc
            oscString = ""
        case 0x28, 0x29, 0x2A, 0x2B: // (, ), *, + charset
            state = .charset
        case 0x37: // 7 - DECSC save cursor
            savedCursorX = cursorX
            savedCursorY = cursorY
            savedStyle = currentStyle
            state = .ground
        case 0x38: // 8 - DECRC restore cursor
            cursorX = savedCursorX
            cursorY = savedCursorY
            currentStyle = savedStyle
            state = .ground
        case 0x44: // D - IND (index / line feed)
            lineFeed()
            state = .ground
        case 0x45: // E - NEL (next line)
            cursorX = 0
            lineFeed()
            state = .ground
        case 0x4D: // M - RI (reverse index)
            reverseIndex()
            state = .ground
        case 0x63: // c - RIS (full reset)
            fullReset()
            state = .ground
        default:
            state = .ground
        }
    }

    private func processCSI(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // 0-9
            currentParam.append(Character(UnicodeScalar(byte)))
        case 0x3A, 0x3B: // : or ;
            csiParams.append(Int(currentParam) ?? 0)
            currentParam = ""
        case 0x3F: // ?
            csiPrivate = true
        case 0x40...0x7E: // final byte
            csiParams.append(Int(currentParam) ?? 0)
            currentParam = ""
            executeCSI(byte)
            state = .ground
        default:
            // Intermediate bytes - ignore for now
            break
        }
    }

    private func processOSC(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL terminates OSC
            executeOSC()
            state = .ground
        case 0x1B: // ESC - might be ST
            state = .oscEscape
        default:
            oscString.append(Character(UnicodeScalar(byte)))
        }
    }

    private func processOSCEscape(_ byte: UInt8) {
        if byte == 0x5C { // backslash -> ST
            executeOSC()
        }
        state = .ground
    }

    // MARK: - Character Output

    private func printChar(_ char: Character) {
        if pendingWrap && autoWrap {
            cursorX = 0
            lineFeed()
            pendingWrap = false
        }

        if cursorX < cols && cursorY < rows {
            screen[cursorY][cursorX] = TerminalCell(character: char, style: currentStyle)
        }

        if cursorX >= cols - 1 {
            pendingWrap = true
        } else {
            cursorX += 1
        }
    }

    // MARK: - CSI Execution

    private func executeCSI(_ final: UInt8) {
        let p = csiParams
        let n = p.first ?? 0

        switch final {
        case 0x41: // A - CUU (cursor up)
            cursorY = max(scrollTop, cursorY - max(1, n))
            pendingWrap = false

        case 0x42: // B - CUD (cursor down)
            cursorY = min(scrollBottom, cursorY + max(1, n))
            pendingWrap = false

        case 0x43: // C - CUF (cursor forward)
            cursorX = min(cols - 1, cursorX + max(1, n))
            pendingWrap = false

        case 0x44: // D - CUB (cursor backward)
            cursorX = max(0, cursorX - max(1, n))
            pendingWrap = false

        case 0x45: // E - CNL (cursor next line)
            cursorX = 0
            cursorY = min(scrollBottom, cursorY + max(1, n))
            pendingWrap = false

        case 0x46: // F - CPL (cursor prev line)
            cursorX = 0
            cursorY = max(scrollTop, cursorY - max(1, n))
            pendingWrap = false

        case 0x47: // G - CHA (cursor horizontal absolute)
            cursorX = min(cols - 1, max(0, (n > 0 ? n : 1) - 1))
            pendingWrap = false

        case 0x48: // H - CUP (cursor position)
            let row = (p.count > 0 && p[0] > 0) ? p[0] : 1
            let col = (p.count > 1 && p[1] > 0) ? p[1] : 1
            cursorY = min(rows - 1, max(0, row - 1))
            cursorX = min(cols - 1, max(0, col - 1))
            pendingWrap = false

        case 0x4A: // J - ED (erase in display)
            eraseInDisplay(n)

        case 0x4B: // K - EL (erase in line)
            eraseInLine(n)

        case 0x4C: // L - IL (insert lines)
            insertLines(max(1, n))

        case 0x4D: // M - DL (delete lines)
            deleteLines(max(1, n))

        case 0x50: // P - DCH (delete characters)
            deleteChars(max(1, n))

        case 0x53: // S - SU (scroll up)
            scrollUp(max(1, n))

        case 0x54: // T - SD (scroll down)
            scrollDown(max(1, n))

        case 0x58: // X - ECH (erase characters)
            eraseChars(max(1, n))

        case 0x40: // @ - ICH (insert characters)
            insertChars(max(1, n))

        case 0x60: // ` - HPA (horizontal position absolute)
            cursorX = min(cols - 1, max(0, (n > 0 ? n : 1) - 1))
            pendingWrap = false

        case 0x64: // d - VPA (vertical position absolute)
            cursorY = min(rows - 1, max(0, (n > 0 ? n : 1) - 1))
            pendingWrap = false

        case 0x66: // f - HVP (same as CUP)
            let row = (p.count > 0 && p[0] > 0) ? p[0] : 1
            let col = (p.count > 1 && p[1] > 0) ? p[1] : 1
            cursorY = min(rows - 1, max(0, row - 1))
            cursorX = min(cols - 1, max(0, col - 1))
            pendingWrap = false

        case 0x68: // h - SM (set mode)
            if csiPrivate {
                setPrivateMode(p, enabled: true)
            }

        case 0x6C: // l - RM (reset mode)
            if csiPrivate {
                setPrivateMode(p, enabled: false)
            }

        case 0x6D: // m - SGR (select graphic rendition)
            processSGR(p)

        case 0x6E: // n - DSR (device status report)
            // Would need write callback to respond
            break

        case 0x72: // r - DECSTBM (set scrolling region)
            let top = (p.count > 0 && p[0] > 0) ? p[0] - 1 : 0
            let bottom = (p.count > 1 && p[1] > 0) ? p[1] - 1 : rows - 1
            scrollTop = max(0, min(top, rows - 1))
            scrollBottom = max(scrollTop, min(bottom, rows - 1))
            cursorX = 0
            cursorY = originMode ? scrollTop : 0
            pendingWrap = false

        case 0x73: // s - SCP (save cursor position)
            savedCursorX = cursorX
            savedCursorY = cursorY

        case 0x75: // u - RCP (restore cursor position)
            cursorX = savedCursorX
            cursorY = savedCursorY
            pendingWrap = false

        default:
            break
        }
    }

    // MARK: - SGR (Colors/Attributes)

    private func processSGR(_ params: [Int]) {
        if params.isEmpty || (params.count == 1 && params[0] == 0) {
            currentStyle = .default
            return
        }

        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentStyle = .default
            case 1:
                currentStyle.bold = true
            case 3:
                currentStyle.italic = true
            case 4:
                currentStyle.underline = true
            case 7:
                currentStyle.inverse = true
            case 22:
                currentStyle.bold = false
            case 23:
                currentStyle.italic = false
            case 24:
                currentStyle.underline = false
            case 27:
                currentStyle.inverse = false
            case 30...37:
                currentStyle.fg = ansiPalette[p - 30]
            case 38:
                if let (color, advance) = parseExtendedColor(params, from: i + 1) {
                    currentStyle.fg = color
                    i += advance
                }
            case 39:
                currentStyle.fg = .defaultFG
            case 40...47:
                currentStyle.bg = ansiPalette[p - 40]
            case 48:
                if let (color, advance) = parseExtendedColor(params, from: i + 1) {
                    currentStyle.bg = color
                    i += advance
                }
            case 49:
                currentStyle.bg = .defaultBG
            case 90...97:
                currentStyle.fg = ansiPalette[p - 90 + 8]
            case 100...107:
                currentStyle.bg = ansiPalette[p - 100 + 8]
            default:
                break
            }
            i += 1
        }
    }

    private func parseExtendedColor(_ params: [Int], from index: Int) -> (TerminalColor, Int)? {
        guard index < params.count else { return nil }
        switch params[index] {
        case 5: // 256 color
            guard index + 1 < params.count else { return nil }
            let colorIndex = params[index + 1]
            return (color256(colorIndex), 2)
        case 2: // RGB
            guard index + 3 < params.count else { return nil }
            let r = UInt8(clamping: params[index + 1])
            let g = UInt8(clamping: params[index + 2])
            let b = UInt8(clamping: params[index + 3])
            return (TerminalColor(r: r, g: g, b: b), 4)
        default:
            return nil
        }
    }

    private func color256(_ index: Int) -> TerminalColor {
        if index < 16 {
            return ansiPalette[index]
        } else if index < 232 {
            let i = index - 16
            let r = UInt8((i / 36) * 51)
            let g = UInt8(((i % 36) / 6) * 51)
            let b = UInt8((i % 6) * 51)
            return TerminalColor(r: r, g: g, b: b)
        } else {
            let gray = UInt8(8 + (index - 232) * 10)
            return TerminalColor(r: gray, g: gray, b: gray)
        }
    }

    // MARK: - Private Mode

    private func setPrivateMode(_ params: [Int], enabled: Bool) {
        for p in params {
            switch p {
            case 1: // DECCKM - cursor keys
                applicationCursorKeys = enabled
            case 6: // DECOM - origin mode
                originMode = enabled
                cursorX = 0
                cursorY = originMode ? scrollTop : 0
            case 7: // DECAWM - auto-wrap
                autoWrap = enabled
            case 25: // DECTCEM - cursor visible
                // Would need to expose this
                break
            case 1049: // Alternate screen buffer
                if enabled {
                    savedCursorX = cursorX
                    savedCursorY = cursorY
                    altScreen = screen
                    screen = Self.makeScreen(cols: cols, rows: rows)
                    cursorX = 0
                    cursorY = 0
                } else if let saved = altScreen {
                    screen = saved
                    altScreen = nil
                    cursorX = savedCursorX
                    cursorY = savedCursorY
                }
            case 2004: // Bracketed paste
                bracketPasteMode = enabled
            default:
                break
            }
        }
    }

    // MARK: - Screen Operations

    private func lineFeed() {
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<count {
            screen.remove(at: scrollTop)
            screen.insert(Array(repeating: .blank, count: cols), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: .blank, count: cols), at: scrollTop)
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0: // Erase below
            eraseInLine(0)
            for row in (cursorY + 1)..<rows {
                clearRow(row)
            }
        case 1: // Erase above
            eraseInLine(1)
            for row in 0..<cursorY {
                clearRow(row)
            }
        case 2, 3: // Erase all
            for row in 0..<rows {
                clearRow(row)
            }
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        guard cursorY < rows else { return }
        switch mode {
        case 0: // Erase right
            for col in cursorX..<cols {
                screen[cursorY][col] = .blank
            }
        case 1: // Erase left
            for col in 0...min(cursorX, cols - 1) {
                screen[cursorY][col] = .blank
            }
        case 2: // Erase entire line
            clearRow(cursorY)
        default:
            break
        }
    }

    private func clearRow(_ row: Int) {
        guard row >= 0, row < rows else { return }
        screen[row] = Array(repeating: .blank, count: cols)
    }

    private func insertLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorY + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: .blank, count: cols), at: cursorY)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorY + 1) {
            screen.remove(at: cursorY)
            screen.insert(Array(repeating: .blank, count: cols), at: scrollBottom)
        }
    }

    private func deleteChars(_ count: Int) {
        guard cursorY < rows else { return }
        let n = min(count, cols - cursorX)
        screen[cursorY].removeSubrange(cursorX..<(cursorX + n))
        screen[cursorY].append(contentsOf: Array(repeating: TerminalCell.blank, count: n))
    }

    private func insertChars(_ count: Int) {
        guard cursorY < rows else { return }
        let n = min(count, cols - cursorX)
        let blanks = Array(repeating: TerminalCell.blank, count: n)
        screen[cursorY].insert(contentsOf: blanks, at: cursorX)
        screen[cursorY] = Array(screen[cursorY].prefix(cols))
    }

    private func eraseChars(_ count: Int) {
        guard cursorY < rows else { return }
        for col in cursorX..<min(cursorX + count, cols) {
            screen[cursorY][col] = .blank
        }
    }

    // MARK: - OSC

    private func executeOSC() {
        let parts = oscString.split(separator: ";", maxSplits: 1)
        guard let command = parts.first, let cmd = Int(command) else { return }
        let arg = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case 0, 2: // Set window/icon title
            title = arg
        case 7: // OSC 7 - Current working directory (file://host/path)
            if let url = URL(string: arg), url.scheme == "file" {
                let path = url.path
                if !path.isEmpty {
                    currentDirectory = path
                    onDirectoryChanged?(path)
                }
            }
        default:
            break
        }
    }

    // MARK: - Reset

    private func fullReset() {
        cursorX = 0
        cursorY = 0
        currentStyle = .default
        scrollTop = 0
        scrollBottom = rows - 1
        originMode = false
        autoWrap = true
        pendingWrap = false
        applicationCursorKeys = false
        altScreen = nil
        screen = Self.makeScreen(cols: cols, rows: rows)
        initTabStops()
    }
}
