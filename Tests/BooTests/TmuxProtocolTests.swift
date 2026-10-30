import XCTest

@testable import Boo

final class TmuxProtocolTests: XCTestCase {
    private typealias P = TmuxProtocol

    private func line(_ s: String) -> P.Line { P.parse(Array(s.utf8)) }

    func testParsesNotifications() {
        XCTAssertEqual(line("%begin 1730000000 12 0"), .begin(number: "12", fromClient: false))
        XCTAssertEqual(line("%begin 1730000000 13 1"), .begin(number: "13", fromClient: true))
        XCTAssertEqual(line("%end 1730000000 13 1"), .end(number: "13"))
        XCTAssertEqual(line("%error 1730000000 13 1"), .error(number: "13"))
        XCTAssertEqual(line("%window-add @3"), .windowAdd(window: "@3"))
        XCTAssertEqual(line("%unlinked-window-close @3"), .windowClose(window: "@3"))
        XCTAssertEqual(line("%window-renamed @3 my shell"), .windowRenamed(window: "@3", name: "my shell"))
        XCTAssertEqual(line("%session-changed $0 0"), .sessionChanged(id: "$0", name: "0"))
        XCTAssertEqual(
            line("%layout-change @0 8205,80x24,0,0,0 8205,80x24,0,0,0 *"),
            .layoutChange(window: "@0", layout: "8205,80x24,0,0,0"))
        XCTAssertEqual(line("%exit"), .exit)
        XCTAssertEqual(line("%sessions-changed"), .other)
        XCTAssertEqual(line("@0 1 layout name"), .other)
    }

    func testOutputIsUnescaped() {
        XCTAssertEqual(
            line(#"%output %1 a\033[1mb\015\012\134"#), .output(pane: "%1", data: Array("a\u{1b}[1mb\r\n\\".utf8)))
        XCTAssertEqual(line("%output %2 grüß"), .output(pane: "%2", data: Array("grüß".utf8)))
        XCTAssertEqual(line(#"%extended-output %4 120 : x\033"#), .output(pane: "%4", data: [0x78, 0x1B]))
        // A backslash not followed by three octal digits stays as is.
        XCTAssertEqual(P.unescape(Array(#"a\9b\01"#.utf8)), Array(#"a\9b\01"#.utf8))
    }

    func testParsesLayouts() {
        let layout = P.parseLayout("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(
            layout,
            .split(
                sideBySide: true, size: .init(columns: 80, rows: 24),
                children: [
                    .pane(id: "%0", size: .init(columns: 40, rows: 24)),
                    .pane(id: "%1", size: .init(columns: 39, rows: 24))
                ]))
        let nested = P.parseLayout("ab12,80x24,0,0[80x12,0,0,0,80x11,0,13{40x11,0,13,1,39x11,41,13,2}]")
        XCTAssertEqual(nested?.paneIDs, ["%0", "%1", "%2"])
        XCTAssertEqual(nested?.paneSizes["%2"], .init(columns: 39, rows: 11))
        XCTAssertEqual(P.parseLayout("b25d,80x24,0,0,7"), .pane(id: "%7", size: .init(columns: 80, rows: 24)))
        XCTAssertNil(P.parseLayout("b25d,80x24,0,0{40x24,0,0,0"))
        XCTAssertNil(P.parseLayout("garbage"))
    }

    func testSplitTreeNestsAndKeepsRatios() throws {
        let layout = try XCTUnwrap(P.parseLayout("0000,80x24,0,0{26x24,0,0,0,26x24,27,0,1,26x24,54,0,2}"))
        let ids = ["%0": UUID(), "%1": UUID(), "%2": UUID()]
        let tree = P.splitTree(layout) { ids[$0]! }
        guard
            case .split(let direction, .leaf(let a), .split(_, .leaf(let b), .leaf(let c), let inner), let outer) = tree
        else { return XCTFail("unexpected tree \(tree)") }
        XCTAssertEqual(direction, .horizontal)
        XCTAssertEqual([a, b, c], [ids["%0"]!, ids["%1"]!, ids["%2"]!])
        // Ratios split the cells, not the one-cell dividers between them.
        XCTAssertEqual(outer, 26.0 / 79.0, accuracy: 0.001)
        XCTAssertEqual(inner, 0.5, accuracy: 0.001)
    }

    func testClientSizeCountsDividers() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = SplitTree.split(
            direction: .horizontal, first: .leaf(id: a),
            second: .split(direction: .vertical, first: .leaf(id: b), second: .leaf(id: c), ratio: 0.5), ratio: 0.5)
        let sizes: [UUID: P.CellSize] = [
            a: .init(columns: 40, rows: 24), b: .init(columns: 39, rows: 12), c: .init(columns: 39, rows: 11)
        ]
        XCTAssertEqual(P.clientSize(tree, sizes: sizes), .init(columns: 80, rows: 24))
        XCTAssertNil(P.clientSize(tree, sizes: [a: .init(columns: 40, rows: 24)]))
    }

    func testWindowInfo() {
        XCTAssertEqual(
            P.windowInfo("@2 1 8205,80x24,0,0,0 vim notes.md"),
            .init(id: "@2", active: true, layout: "8205,80x24,0,0,0", name: "vim notes.md"))
        XCTAssertEqual(P.windowInfo("@2 0 8205,80x24,0,0,0")?.name, "")
        XCTAssertNil(P.windowInfo("%begin 1 2 1"))
    }

    func testSendKeysHexAndChunks() {
        XCTAssertEqual(P.sendKeys(pane: "%1", bytes: Array("a;\n".utf8)), ["send-keys -t %1 -H 61 3b 0a"])
        let commands = P.sendKeys(pane: "%1", bytes: [UInt8](repeating: 0x41, count: P.sendKeysChunk + 1))
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[1], "send-keys -t %1 -H 41")
        XCTAssertEqual(P.sendKeys(pane: "%1", bytes: []), [])
    }

    func testRedraw() {
        let out = P.redraw(lines: [Array("one".utf8), Array("two".utf8)], cursor: "3 1")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "\u{1b}[H\u{1b}[2Jone\r\ntwo\u{1b}[0m\u{1b}[2;4H")
        XCTAssertEqual(String(decoding: P.redraw(lines: [], cursor: nil), as: UTF8.self), "\u{1b}[H\u{1b}[2J\u{1b}[0m")
    }

    func testBridgeFraming() {
        let input = P.encode(.input([1, 2, 3]))
        let resize = P.encode(.resize(.init(columns: 300, rows: 50)))
        let both = input + resize
        XCTAssertEqual(P.decode(both), .frame(.input([1, 2, 3]), consumed: input.count))
        XCTAssertEqual(
            P.decode(both[input.count...]), .frame(.resize(.init(columns: 300, rows: 50)), consumed: resize.count))
        XCTAssertEqual(P.decode(input.dropLast()), .incomplete)
        XCTAssertEqual(P.decode([UInt8(ascii: "i"), 0, 0]), .incomplete)
        XCTAssertEqual(P.decode([UInt8(ascii: "x"), 0, 0, 0, 0]), .malformed)
        XCTAssertEqual(P.decode([UInt8(ascii: "r"), 0, 0, 0, 1, 9]), .malformed)
        XCTAssertEqual(P.decode([UInt8(ascii: "i"), 0, 0x10, 0, 1]), .malformed)
    }
}
