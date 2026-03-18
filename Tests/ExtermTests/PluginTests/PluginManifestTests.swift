import XCTest
@testable import Exterm

final class PluginManifestTests: XCTestCase {

    func testValidManifestParsing() throws {
        let json = """
        {
            "id": "git-panel",
            "name": "Git Panel",
            "version": "1.0.0",
            "icon": "arrow.triangle.branch",
            "description": "Shows git status in sidebar",
            "when": "git.active",
            "capabilities": { "sidebarPanel": true, "statusBarSegment": true },
            "statusBar": { "position": "left", "priority": 10, "template": "{git.branch}" },
            "settings": [
                { "key": "showDiffs", "type": "bool", "label": "Show diffs", "default": true },
                { "key": "maxFiles", "type": "int", "label": "Max files", "default": 50 }
            ]
        }
        """
        let manifest = try PluginManifest.parse(from: json)

        XCTAssertEqual(manifest.id, "git-panel")
        XCTAssertEqual(manifest.name, "Git Panel")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.icon, "arrow.triangle.branch")
        XCTAssertEqual(manifest.description, "Shows git status in sidebar")
        XCTAssertEqual(manifest.when, "git.active")
        XCTAssertEqual(manifest.capabilities?.sidebarPanel, true)
        XCTAssertEqual(manifest.capabilities?.statusBarSegment, true)
        XCTAssertEqual(manifest.statusBar?.position, "left")
        XCTAssertEqual(manifest.statusBar?.priority, 10)
        XCTAssertEqual(manifest.settings?.count, 2)
        XCTAssertEqual(manifest.settings?[0].key, "showDiffs")
        XCTAssertEqual(manifest.settings?[0].type, .bool)
        XCTAssertEqual(manifest.settings?[1].defaultValue, AnyCodableValue(50))
    }

    func testMinimalManifest() throws {
        let json = """
        { "id": "minimal", "name": "Minimal", "version": "1.0.0", "icon": "star" }
        """
        let manifest = try PluginManifest.parse(from: json)
        XCTAssertEqual(manifest.id, "minimal")
        XCTAssertNil(manifest.when)
        XCTAssertNil(manifest.capabilities)
        XCTAssertNil(manifest.settings)
    }

    func testMissingRequiredFieldID() {
        let json = """
        { "id": "", "name": "Bad", "version": "1.0.0", "icon": "star" }
        """
        XCTAssertThrowsError(try PluginManifest.parse(from: json)) { error in
            XCTAssertTrue("\(error)".contains("id"), "Error should mention 'id': \(error)")
        }
    }

    func testMissingRequiredFieldName() {
        let json = """
        { "id": "test", "name": "", "version": "1.0.0", "icon": "star" }
        """
        XCTAssertThrowsError(try PluginManifest.parse(from: json)) { error in
            XCTAssertTrue("\(error)".contains("name"), "Error should mention 'name': \(error)")
        }
    }

    func testMalformedJSON() {
        let json = "{ not valid json }"
        XCTAssertThrowsError(try PluginManifest.parse(from: json))
    }

    func testUnknownFieldsIgnored() throws {
        let json = """
        { "id": "test", "name": "Test", "version": "1.0.0", "icon": "star", "futureField": "ignored" }
        """
        // Should parse successfully, ignoring unknown fields
        let manifest = try PluginManifest.parse(from: json)
        XCTAssertEqual(manifest.id, "test")
    }

    func testSettingTypes() throws {
        let json = """
        {
            "id": "test", "name": "Test", "version": "1.0.0", "icon": "star",
            "settings": [
                { "key": "a", "type": "bool", "label": "A", "default": true },
                { "key": "b", "type": "string", "label": "B", "default": "hello" },
                { "key": "c", "type": "int", "label": "C", "default": 42 },
                { "key": "d", "type": "double", "label": "D", "default": 3.14 }
            ]
        }
        """
        let manifest = try PluginManifest.parse(from: json)
        XCTAssertEqual(manifest.settings?.count, 4)
        XCTAssertEqual(manifest.settings?[0].type, .bool)
        XCTAssertEqual(manifest.settings?[1].type, .string)
        XCTAssertEqual(manifest.settings?[2].type, .int)
        XCTAssertEqual(manifest.settings?[3].type, .double)
    }
}
