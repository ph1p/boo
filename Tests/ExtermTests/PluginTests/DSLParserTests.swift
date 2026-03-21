import XCTest

@testable import Exterm

final class DSLParserTests: XCTestCase {

    func testParseLabel() throws {
        let json = """
            { "type": "label", "text": "Hello World", "style": "bold", "tint": "accent" }
            """
        let elements = try DSLParser.parse(json)
        XCTAssertEqual(elements.count, 1)
        if case .label(let text, let style, let tint) = elements[0] {
            XCTAssertEqual(text, "Hello World")
            XCTAssertEqual(style, .bold)
            XCTAssertEqual(tint, .accent)
        } else {
            XCTFail("Expected label element")
        }
    }

    func testParseLabelMinimal() throws {
        let json = """
            { "type": "label", "text": "Plain text" }
            """
        let elements = try DSLParser.parse(json)
        if case .label(let text, let style, let tint) = elements[0] {
            XCTAssertEqual(text, "Plain text")
            XCTAssertNil(style)
            XCTAssertNil(tint)
        } else {
            XCTFail("Expected label element")
        }
    }

    func testParseList() throws {
        let json = """
            {
                "type": "list",
                "items": [
                    { "label": "file.swift", "icon": "doc", "tint": "success", "action": { "type": "open", "path": "/file.swift" } },
                    { "label": "README.md", "detail": "2.3 KB" }
                ]
            }
            """
        let elements = try DSLParser.parse(json)
        if case .list(let items) = elements[0] {
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].label, "file.swift")
            XCTAssertEqual(items[0].icon, "doc")
            XCTAssertEqual(items[0].tint, .success)
            XCTAssertEqual(items[0].action?.type, "open")
            XCTAssertEqual(items[0].action?.path, "/file.swift")
            XCTAssertEqual(items[1].label, "README.md")
            XCTAssertEqual(items[1].detail, "2.3 KB")
            XCTAssertNil(items[1].action)
        } else {
            XCTFail("Expected list element")
        }
    }

    func testParseButton() throws {
        let json = """
            { "type": "button", "label": "Refresh", "action": { "type": "exec", "command": "git status" }, "style": "primary" }
            """
        let elements = try DSLParser.parse(json)
        if case .button(let label, let action, let style) = elements[0] {
            XCTAssertEqual(label, "Refresh")
            XCTAssertEqual(action.type, "exec")
            XCTAssertEqual(action.command, "git status")
            XCTAssertEqual(style, .primary)
        } else {
            XCTFail("Expected button element")
        }
    }

    func testParseBadge() throws {
        let json = """
            { "type": "badge", "text": "3", "tint": "warning", "accessibilityLabel": "3 changed files" }
            """
        let elements = try DSLParser.parse(json)
        if case .badge(let text, let tint, let a11y) = elements[0] {
            XCTAssertEqual(text, "3")
            XCTAssertEqual(tint, .warning)
            XCTAssertEqual(a11y, "3 changed files")
        } else {
            XCTFail("Expected badge element")
        }
    }

    func testParseBadgeWithCount() throws {
        let json = """
            { "type": "badge", "count": 42 }
            """
        let elements = try DSLParser.parse(json)
        if case .badge(let text, _, _) = elements[0] {
            XCTAssertEqual(text, "42")
        } else {
            XCTFail("Expected badge element")
        }
    }

    func testParseDivider() throws {
        let json = """
            { "type": "divider" }
            """
        let elements = try DSLParser.parse(json)
        XCTAssertEqual(elements[0], .divider)
    }

    func testParseSpacer() throws {
        let json = """
            { "type": "spacer" }
            """
        let elements = try DSLParser.parse(json)
        XCTAssertEqual(elements[0], .spacer)
    }

    func testParseNestedVStack() throws {
        let json = """
            {
                "type": "vstack",
                "children": [
                    { "type": "label", "text": "Header", "style": "bold" },
                    { "type": "divider" },
                    { "type": "label", "text": "Body" }
                ]
            }
            """
        let elements = try DSLParser.parse(json)
        if case .vstack(let children) = elements[0] {
            XCTAssertEqual(children.count, 3)
            if case .label(let text, _, _) = children[0] {
                XCTAssertEqual(text, "Header")
            } else {
                XCTFail("Expected label")
            }
            XCTAssertEqual(children[1], .divider)
        } else {
            XCTFail("Expected vstack element")
        }
    }

    func testParseArray() throws {
        let json = """
            [
                { "type": "label", "text": "First" },
                { "type": "label", "text": "Second" }
            ]
            """
        let elements = try DSLParser.parse(json)
        XCTAssertEqual(elements.count, 2)
    }

    func testParseMissingType() {
        let json = """
            { "text": "no type" }
            """
        XCTAssertThrowsError(try DSLParser.parse(json)) { error in
            XCTAssertTrue("\(error)".contains("type"))
        }
    }

    func testParseUnknownType() {
        let json = """
            { "type": "unknown_widget" }
            """
        XCTAssertThrowsError(try DSLParser.parse(json)) { error in
            XCTAssertTrue("\(error)".contains("unknown_widget"))
        }
    }

    func testParseMissingLabelText() {
        let json = """
            { "type": "label" }
            """
        XCTAssertThrowsError(try DSLParser.parse(json)) { error in
            XCTAssertTrue("\(error)".contains("text"))
        }
    }

    func testParseMissingListItems() {
        let json = """
            { "type": "list" }
            """
        XCTAssertThrowsError(try DSLParser.parse(json)) { error in
            XCTAssertTrue("\(error)".contains("items"))
        }
    }

    func testParseInvalidJSON() {
        XCTAssertThrowsError(try DSLParser.parse("not json"))
    }
}
