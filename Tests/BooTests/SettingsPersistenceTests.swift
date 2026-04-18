import XCTest

@testable import Boo

final class SettingsPersistenceTests: XCTestCase {

    func testSettingsFileCreatedOnChange() {
        let settings = AppSettings.shared
        let original = settings.fontSize

        // Trigger a save
        settings.fontSize = 18
        defer { settings.fontSize = original }

        // Check the file exists
        let path = BooPaths.settingsFile
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "settings.json should exist after a settings change")
    }

    func testSettingsFileIsValidJSON() {
        let settings = AppSettings.shared
        let original = settings.fontSize
        settings.fontSize = 16
        defer { settings.fontSize = original }

        let path = BooPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            XCTFail("Could not read settings.json")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "settings.json should contain valid JSON")
        XCTAssertEqual(json?["fontSize"] as? Double, 16.0)
    }

    @MainActor func testGhosttyConfigFileCreated() {
        // GhosttyRuntime writes config on init
        _ = GhosttyRuntime.shared

        let path = BooPaths.ghosttyConfigFile
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "ghostty.conf should exist after runtime init")
    }

    @MainActor func testGhosttyConfigContainsFont() {
        _ = GhosttyRuntime.shared

        let path = BooPaths.ghosttyConfigFile
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

        let path = BooPaths.ghosttyConfigFile
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

        let path = BooPaths.settingsFile
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

    func testStartupSettingsPersistToFile() {
        let settings = AppSettings.shared
        let originalMainPage = settings.defaultMainPage
        let originalTabType = settings.defaultTabType
        let originalBrowserHomePage = settings.browserHomePage
        settings.defaultMainPage = "https://example.com/start"
        settings.defaultTabType = .browser
        settings.browserHomePage = "https://example.com/home"
        defer {
            settings.defaultMainPage = originalMainPage
            settings.defaultTabType = originalTabType
            settings.browserHomePage = originalBrowserHomePage
        }

        let path = BooPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }

        XCTAssertEqual(json["defaultMainPage"] as? String, "https://example.com/start")
        XCTAssertEqual(json["defaultTabType"] as? String, "browser")
        XCTAssertEqual(json["browserHomePage"] as? String, "https://example.com/home")
    }

    func testGlobalSidebarStatePersistsExpandedSectionsSelectionAndScrollOffsets() {
        let settings = AppSettings.shared
        let originalGlobal = settings.sidebarGlobalState
        settings.sidebarGlobalState = true
        defer { settings.sidebarGlobalState = originalGlobal }

        settings.saveSidebarState(
            heights: ["files": 180],
            order: ["git-panel": ["files", "status"]],
            globalExpandedSectionIDs: ["files", "status"],
            globalUserCollapsedSectionIDs: ["history"],
            globalSelectedPluginTabID: "git-panel",
            globalScrollOffsets: ["__global__:files": CGPoint(x: 0, y: 42)]
        )

        XCTAssertEqual(settings.sidebarSectionHeights["files"] ?? -1, 180, accuracy: 0.1)
        XCTAssertEqual(settings.sidebarSectionOrder["git-panel"] ?? [], ["files", "status"])
        XCTAssertEqual(settings.sidebarGlobalExpandedSectionIDs, Set(["files", "status"]))
        XCTAssertEqual(settings.sidebarGlobalUserCollapsedSectionIDs, Set(["history"]))
        XCTAssertEqual(settings.sidebarGlobalSelectedPluginTabID, "git-panel")
        XCTAssertEqual(settings.sidebarGlobalScrollOffsets["__global__:files"]?.y ?? -1, 42, accuracy: 0.1)
    }

    func testSidebarPerWorkspaceStatePersistsInSettingsJSON() {
        let settings = AppSettings.shared
        let original = settings.sidebarPerWorkspaceState
        settings.sidebarPerWorkspaceState = true
        defer { settings.sidebarPerWorkspaceState = original }

        let path = BooPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }

        XCTAssertEqual(
            json["sidebarPerWorkspaceState"] as? Bool,
            true,
            "sidebarPerWorkspaceState should be persisted in settings.json"
        )
    }

    func testUpdaterAndSSHSettingsPersistToFile() {
        let settings = AppSettings.shared
        let originalAutoCheck = settings.autoCheckUpdates
        let originalSkipVersion = settings.skipVersion
        let originalSSHApproval = settings.sshControlMasterApproved

        settings.autoCheckUpdates = false
        settings.skipVersion = "9.9.9"
        settings.sshControlMasterApproved = false
        defer {
            settings.autoCheckUpdates = originalAutoCheck
            settings.skipVersion = originalSkipVersion
            settings.sshControlMasterApproved = originalSSHApproval
        }

        let path = BooPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }

        XCTAssertEqual(json["autoCheckUpdates"] as? Bool, false)
        XCTAssertEqual(json["skipVersion"] as? String, "9.9.9")
        XCTAssertEqual(json["sshControlMasterApproved"] as? Bool, false)
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

        let path = BooPaths.bookmarksFile
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
