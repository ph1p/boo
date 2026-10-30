import CoreGraphics
import Foundation

/// The pure parts of tmux control mode (`tmux -CC`): notification lines, the
/// window layout grammar, octal unescaping and the bridge framing. No I/O.
enum TmuxProtocol {

    struct CellSize: Equatable, Sendable {
        var columns: Int
        var rows: Int
    }

    // MARK: - Lines

    enum Line: Equatable {
        /// Opens a command reply. `fromClient` is false for the reply to the
        /// command that started tmux, which no queued command is waiting for.
        case begin(number: String, fromClient: Bool)
        case end(number: String)
        case error(number: String)
        case output(pane: String, data: [UInt8])
        case layoutChange(window: String, layout: String)
        case windowAdd(window: String)
        case windowClose(window: String)
        case windowRenamed(window: String, name: String)
        case sessionChanged(id: String, name: String)
        case exit
        case other
    }

    private static let outputPrefix = Array("%output ".utf8)
    private static let extendedOutputPrefix = Array("%extended-output ".utf8)
    private static let extendedMarker = Array(" : ".utf8)
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func parse(_ line: [UInt8]) -> Line {
        guard line.first == UInt8(ascii: "%") else { return .other }
        if line.starts(with: outputPrefix) {
            return output(line.dropFirst(outputPrefix.count), extended: false)
        }
        if line.starts(with: extendedOutputPrefix) {
            return output(line.dropFirst(extendedOutputPrefix.count), extended: true)
        }
        let words = String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        let arg = { (i: Int) in i < words.count ? String(words[i]) : "" }
        let rest = { (i: Int) in i < words.count ? words[i...].joined(separator: " ") : "" }
        switch words[0] {
        case "%begin": return .begin(number: arg(2), fromClient: (Int(arg(3)) ?? 0) & 1 == 1)
        case "%end": return .end(number: arg(2))
        case "%error": return .error(number: arg(2))
        case "%layout-change": return .layoutChange(window: arg(1), layout: arg(2))
        case "%window-add": return .windowAdd(window: arg(1))
        case "%window-close", "%unlinked-window-close": return .windowClose(window: arg(1))
        case "%window-renamed": return .windowRenamed(window: arg(1), name: rest(2))
        case "%session-changed": return .sessionChanged(id: arg(1), name: rest(2))
        case "%exit": return .exit
        default: return .other
        }
    }

    /// `%N data` or, extended, `%N age ... : data`.
    private static func output(_ rest: ArraySlice<UInt8>, extended: Bool) -> Line {
        guard let space = rest.firstIndex(of: UInt8(ascii: " ")) else { return .other }
        let pane = String(decoding: rest[rest.startIndex..<space], as: UTF8.self)
        var data = rest[(space + 1)...]
        if extended {
            guard let at = data.indices.first(where: { data[$0...].starts(with: extendedMarker) }) else {
                return .other
            }
            data = data[(at + extendedMarker.count)...]
        }
        return .output(pane: pane, data: unescape(data))
    }

    /// tmux writes bytes below space and backslash as `\ooo`.
    static func unescape<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        bytes.withContiguousStorageIfAvailable(unescape) ?? Array(bytes).withUnsafeBufferPointer(unescape)
    }

    private static func unescape(_ src: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        var i = 0
        while i < src.count {
            if src[i] == UInt8(ascii: "\\"), i + 3 < src.count {
                let digits = src[(i + 1)...(i + 3)]
                if digits.allSatisfy({ (0x30...0x37).contains($0) }) {
                    out.append(digits.reduce(0) { $0 &* 8 &+ ($1 - 0x30) })
                    i += 4
                    continue
                }
            }
            out.append(src[i])
            i += 1
        }
        return out
    }

    // MARK: - Layout

    /// A window layout such as `b25d,80x24,0,0{40x24,0,0,0,39x24,41,0,1}`:
    /// `{}` lays children side by side, `[]` top to bottom.
    indirect enum Layout: Equatable {
        case pane(id: String, size: CellSize)
        case split(sideBySide: Bool, size: CellSize, children: [Layout])

        var size: CellSize {
            switch self {
            case .pane(_, let size), .split(_, let size, _): return size
            }
        }

        /// tmux pane IDs (`%N`), in layout order.
        var paneIDs: [String] {
            switch self {
            case .pane(let id, _): return [id]
            case .split(_, _, let children): return children.flatMap(\.paneIDs)
            }
        }

        var paneSizes: [String: CellSize] {
            switch self {
            case .pane(let id, let size): return [id: size]
            case .split(_, _, let children):
                return children.reduce(into: [:]) { $0.merge($1.paneSizes) { a, _ in a } }
            }
        }
    }

    static func parseLayout(_ text: String) -> Layout? {
        var bytes = Array(text.utf8)
        // Drop the leading checksum ("b25d,").
        if let comma = bytes.firstIndex(of: UInt8(ascii: ",")), !bytes[..<comma].contains(UInt8(ascii: "x")) {
            bytes.removeSubrange(...comma)
        }
        var i = 0
        guard let layout = parseCell(bytes, &i), i == bytes.count else { return nil }
        return layout
    }

    private static func parseCell(_ b: [UInt8], _ i: inout Int) -> Layout? {
        guard let w = number(b, &i), expect(b, &i, "x"), let h = number(b, &i),
            expect(b, &i, ","), number(b, &i) != nil, expect(b, &i, ","), number(b, &i) != nil
        else { return nil }
        let size = CellSize(columns: w, rows: h)
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: ","):
            i += 1
            guard let id = number(b, &i) else { return nil }
            return .pane(id: "%\(id)", size: size)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let sideBySide = b[i] == UInt8(ascii: "{")
            let close = UInt8(ascii: sideBySide ? "}" : "]")
            i += 1
            var children: [Layout] = []
            repeat {
                guard let child = parseCell(b, &i) else { return nil }
                children.append(child)
            } while expect(b, &i, ",")
            guard expect(b, &i, Character(UnicodeScalar(close))), !children.isEmpty else { return nil }
            return .split(sideBySide: sideBySide, size: size, children: children)
        default:
            return nil
        }
    }

    private static func number(_ b: [UInt8], _ i: inout Int) -> Int? {
        let start = i
        while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
        return i > start ? Int(String(decoding: b[start..<i], as: UTF8.self)) : nil
    }

    private static func expect(_ b: [UInt8], _ i: inout Int, _ c: Character) -> Bool {
        guard i < b.count, b[i] == c.asciiValue else { return false }
        i += 1
        return true
    }

    /// The layout as Boo's binary split tree; an n-way split nests to the right.
    static func splitTree(_ layout: Layout, leafID: (String) -> UUID) -> SplitTree {
        switch layout {
        case .pane(let id, _):
            return .leaf(id: leafID(id))
        case .split(let sideBySide, _, let children):
            return nest(children[...], sideBySide: sideBySide, leafID: leafID)
        }
    }

    private static func nest(_ children: ArraySlice<Layout>, sideBySide: Bool, leafID: (String) -> UUID) -> SplitTree {
        guard let first = children.first else { return .leaf(id: UUID()) }
        let rest = children.dropFirst()
        if rest.isEmpty { return splitTree(first, leafID: leafID) }
        let extent = { (l: Layout) in sideBySide ? l.size.columns : l.size.rows }
        let restExtent = rest.map(extent).reduce(0, +) + rest.count - 1
        let ratio = CGFloat(extent(first)) / CGFloat(max(1, extent(first) + restExtent))
        return .split(
            direction: sideBySide ? .horizontal : .vertical,
            first: splitTree(first, leafID: leafID),
            second: nest(rest, sideBySide: sideBySide, leafID: leafID),
            ratio: ratio)
    }

    /// The tmux client size that gives each leaf its size, counting a one-cell
    /// divider between siblings. Nil until every leaf's size is known.
    static func clientSize(_ tree: SplitTree, sizes: [UUID: CellSize]) -> CellSize? {
        switch tree {
        case .leaf(let id):
            return sizes[id]
        case .split(let direction, let first, let second, _):
            guard let a = clientSize(first, sizes: sizes), let b = clientSize(second, sizes: sizes) else { return nil }
            return direction == .horizontal
                ? CellSize(columns: a.columns + 1 + b.columns, rows: max(a.rows, b.rows))
                : CellSize(columns: max(a.columns, b.columns), rows: a.rows + 1 + b.rows)
        }
    }

    // MARK: - Commands

    static let windowFormat = "#{window_id} #{window_active} #{window_layout} #{window_name}"

    struct WindowInfo: Equatable {
        let id: String
        let active: Bool
        let layout: String
        let name: String
    }

    /// A line printed with `windowFormat`.
    static func windowInfo(_ line: String) -> WindowInfo? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].hasPrefix("@") else { return nil }
        return WindowInfo(
            id: String(parts[0]), active: parts[1] == "1", layout: String(parts[2]),
            name: parts.count > 3 ? String(parts[3]) : "")
    }

    /// Bytes per `send-keys` command, to keep command lines short.
    static let sendKeysChunk = 256

    static func sendKeys(pane: String, bytes: [UInt8]) -> [String] {
        stride(from: 0, to: bytes.count, by: sendKeysChunk).map { start in
            let chunk = bytes[start..<min(start + sendKeysChunk, bytes.count)]
            var hex: [UInt8] = []
            hex.reserveCapacity(chunk.count * 3)
            for byte in chunk {
                if !hex.isEmpty { hex.append(UInt8(ascii: " ")) }
                hex.append(hexDigits[Int(byte >> 4)])
                hex.append(hexDigits[Int(byte & 0xF)])
            }
            return "send-keys -t \(pane) -H " + String(decoding: hex, as: UTF8.self)
        }
    }

    /// Screen contents from `capture-pane -p -e -J`, then the cursor from
    /// `#{cursor_x} #{cursor_y}`, as bytes that redraw the pane.
    static func redraw(lines: [[UInt8]], cursor: String?) -> [UInt8] {
        var out = Array("\u{1b}[H\u{1b}[2J".utf8)
        for (n, line) in lines.enumerated() {
            if n > 0 { out += [0x0D, 0x0A] }
            out += line
        }
        out += Array("\u{1b}[0m".utf8)
        if let parts = cursor?.split(separator: " "), parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) {
            out += Array("\u{1b}[\(y + 1);\(x + 1)H".utf8)
        }
        return out
    }

    // MARK: - Bridge framing

    /// A frame from a bridge process: `[kind u8][length u32 BE][payload]`.
    enum BridgeFrame: Equatable {
        case input([UInt8])
        case resize(CellSize)
    }

    enum Decoded: Equatable {
        case incomplete
        case malformed
        case frame(BridgeFrame, consumed: Int)
    }

    static let maxFrame = 64 * 1024

    static func encode(_ frame: BridgeFrame) -> [UInt8] {
        let kind: UInt8
        let payload: [UInt8]
        switch frame {
        case .input(let bytes):
            kind = UInt8(ascii: "i")
            payload = bytes
        case .resize(let size):
            kind = UInt8(ascii: "r")
            let c = UInt16(clamping: size.columns)
            let r = UInt16(clamping: size.rows)
            payload = [UInt8(c >> 8), UInt8(c & 0xFF), UInt8(r >> 8), UInt8(r & 0xFF)]
        }
        let n = UInt32(payload.count)
        var frame: [UInt8] = []
        frame.reserveCapacity(5 + payload.count)
        frame += [kind, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        frame += payload
        return frame
    }

    static func decode<C: Collection>(_ buffer: C) -> Decoded where C.Element == UInt8, C.Index == Int {
        guard buffer.count >= 5 else { return .incomplete }
        let s = buffer.startIndex
        let length = buffer[(s + 1)..<(s + 5)].reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxFrame else { return .malformed }
        guard buffer.count >= 5 + length else { return .incomplete }
        let payload = Array(buffer[(s + 5)..<(s + 5 + length)])
        switch buffer[s] {
        case UInt8(ascii: "i"):
            return .frame(.input(payload), consumed: 5 + length)
        case UInt8(ascii: "r") where length == 4:
            let size = CellSize(
                columns: Int(payload[0]) << 8 | Int(payload[1]), rows: Int(payload[2]) << 8 | Int(payload[3]))
            return .frame(.resize(size), consumed: 5 + length)
        default:
            return .malformed
        }
    }
}
