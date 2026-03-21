import XCTest

@testable import Exterm

final class SettingsPersistenceTests: XCTestCase {

    func testSettingsFileCreatedOnChange() {
        let settings = AppSettings.shared
        let original = settings.fontSize

        // Trigger a save
        settings.fontSize = 18
        defer { settings.fontSize = original }

        // Check the file exists
        let path = ExtermPaths.settingsFile
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "settings.json should exist after a settings change")
    }

    func testSettingsFileIsValidJSON() {
        let settings = AppSettings.shared
        let original = settings.fontSize
        settings.fontSize = 16
        defer { settings.fontSize = original }

        let path = ExtermPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            XCTFail("Could not read settings.json")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "settings.json should contain valid JSON")
        XCTAssertEqual(json?["fontSize"] as? Double, 16.0)
    }

    func testGhosttyConfigFileCreated() {
        // GhosttyRuntime writes config on init
        _ = GhosttyRuntime.shared

        let path = ExtermPaths.ghosttyConfigFile
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "ghostty.conf should exist after runtime init")
    }

    func testGhosttyConfigContainsFont() {
        _ = GhosttyRuntime.shared

        let path = ExtermPaths.ghosttyConfigFile
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("Could not read ghostty.conf")
            return
        }

        XCTAssertTrue(content.contains("font-family"), "Config should contain font-family")
        XCTAssertTrue(content.contains("font-size"), "Config should contain font-size")
        XCTAssertTrue(content.contains("background"), "Config should contain background")
        XCTAssertTrue(content.contains("foreground"), "Config should contain foreground")
        XCTAssertTrue(content.contains("palette"), "Config should contain palette")
        XCTAssertTrue(content.contains("cursor-style"), "Config should contain cursor-style")
        XCTAssertTrue(content.contains("term = xterm-256color"), "Config should set TERM")
    }

    func testGhosttyConfigUpdatesOnThemeChange() {
        let settings = AppSettings.shared
        let original = settings.themeName

        settings.themeName = "Dracula"
        // Allow notification to propagate
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let path = ExtermPaths.ghosttyConfigFile
        let content = try? String(contentsOfFile: path, encoding: .utf8)

        // Dracula background is #282a36
        XCTAssertTrue(
            content?.contains("#282a36") ?? false,
            "Config should contain Dracula background color")

        settings.themeName = original
    }

    // MARK: - Sidebar Width Persistence

    func testSidebarWidthDefaultValue() {
        UserDefaults.standard.removeObject(forKey: "sidebarWidth")
        let settings = AppSettings.shared
        XCTAssertEqual(settings.sidebarWidth, 250, "Default sidebar width should be 250")
    }

    func testSidebarWidthRoundTrip() {
        let settings = AppSettings.shared
        let original = settings.sidebarWidth

        settings.sidebarWidth = 300
        XCTAssertEqual(settings.sidebarWidth, 300)

        settings.sidebarWidth = 180
        XCTAssertEqual(settings.sidebarWidth, 180)

        settings.sidebarWidth = 250
    }

    func testSidebarWidthInSettingsJSON() {
        let settings = AppSettings.shared
        let original = settings.sidebarWidth
        settings.sidebarWidth = 350
        defer { settings.sidebarWidth = original }

        let path = ExtermPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }
        XCTAssertEqual(
            json["sidebarWidth"] as? Double, 350.0,
            "sidebarWidth should be persisted in settings.json")
    }

    func testBookmarksPersistToFile() {
        let service = BookmarkService.shared
        let countBefore = service.bookmarks.count

        service.add(name: "TestBM", path: "/tmp/test-bookmark-\(UUID().uuidString)")
        defer {
            if let bm = service.bookmarks.last, bm.name == "TestBM" {
                service.remove(id: bm.id)
            }
        }

        let path = ExtermPaths.bookmarksFile
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "bookmarks.json should exist after adding a bookmark")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let bookmarks = try? JSONDecoder().decode([BookmarkService.Bookmark].self, from: data)
        else {
            XCTFail("Could not decode bookmarks.json")
            return
        }

        XCTAssertEqual(bookmarks.count, countBefore + 1)
        XCTAssertEqual(bookmarks.last?.name, "TestBM")
    }
}
