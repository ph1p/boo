import XCTest
import Cocoa
@testable import Exterm

final class KeyMappingTests: XCTestCase {

    // Helper to create a mock NSEvent
    private func keyEvent(keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    func testReturnKey() {
        guard let event = keyEvent(keyCode: 36, characters: "\r") else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data([0x0D]))
    }

    func testEscapeKey() {
        guard let event = keyEvent(keyCode: 53, characters: "\u{1B}") else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data([0x1B]))
    }

    func testBackspace() {
        guard let event = keyEvent(keyCode: 51, characters: "\u{7F}") else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data([0x7F]))
    }

    func testTabKey() {
        guard let event = keyEvent(keyCode: 48, characters: "\t") else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data([0x09]))
    }

    func testArrowUp() {
        guard let event = keyEvent(keyCode: 126) else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data("\u{1B}[A".utf8))
    }

    func testArrowDown() {
        guard let event = keyEvent(keyCode: 125) else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data("\u{1B}[B".utf8))
    }

    func testArrowRight() {
        guard let event = keyEvent(keyCode: 124) else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data("\u{1B}[C".utf8))
    }

    func testArrowLeft() {
        guard let event = keyEvent(keyCode: 123) else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data("\u{1B}[D".utf8))
    }

    func testRegularCharacter() {
        guard let event = keyEvent(keyCode: 0, characters: "a") else { return }
        let data = KeyMapping.encode(event: event)
        XCTAssertEqual(data, Data("a".utf8))
    }
}
