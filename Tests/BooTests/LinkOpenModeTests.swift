import XCTest

@testable import Boo

final class LinkOpenModeTests: XCTestCase {

    // MARK: - Enum cases

    func testLinkOpenModeAllCases() {
        XCTAssertEqual(LinkOpenMode.allCases.count, 2)
        XCTAssertTrue(LinkOpenMode.allCases.contains(.browserTab))
        XCTAssertTrue(LinkOpenMode.allCases.contains(.externalBrowser))
    }

    func testLinkOpenModeDisplayNames() {
        XCTAssertEqual(LinkOpenMode.browserTab.displayName, "Browser Tab")
        XCTAssertEqual(LinkOpenMode.externalBrowser.displayName, "External Browser")
    }

    func testLinkOpenModeRawValues() {
        XCTAssertEqual(LinkOpenMode.browserTab.rawValue, "browserTab")
        XCTAssertEqual(LinkOpenMode.externalBrowser.rawValue, "externalBrowser")
    }

    func testLinkOpenModeRoundTrip() {
        XCTAssertEqual(LinkOpenMode(rawValue: "browserTab"), .browserTab)
        XCTAssertEqual(LinkOpenMode(rawValue: "externalBrowser"), .externalBrowser)
        XCTAssertNil(LinkOpenMode(rawValue: "invalid"))
    }

    func testLinkOpenModeCodableRoundTrip() throws {
        for mode in LinkOpenMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(LinkOpenMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - AppSettings persistence

    func testLinkOpenModeDefaultIsBrowserTab() {
        UserDefaults.standard.removeObject(forKey: "linkOpenMode")
        XCTAssertEqual(AppSettings.shared.linkOpenMode, .browserTab)
    }

    func testLinkOpenModeRoundTripInAppSettings() {
        let settings = AppSettings.shared
        let original = settings.linkOpenMode
        defer { settings.linkOpenMode = original }

        settings.linkOpenMode = .externalBrowser
        XCTAssertEqual(settings.linkOpenMode, .externalBrowser)

        settings.linkOpenMode = .browserTab
        XCTAssertEqual(settings.linkOpenMode, .browserTab)
    }

    func testLinkOpenModePersistedToSettingsJSON() {
        let settings = AppSettings.shared
        let original = settings.linkOpenMode
        settings.linkOpenMode = .externalBrowser
        defer { settings.linkOpenMode = original }

        let path = BooPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }
        XCTAssertEqual(json["linkOpenMode"] as? String, "externalBrowser")
    }

    func testLinkOpenModeUnknownRawValueFallsBackToDefault() {
        UserDefaults.standard.set("notAMode", forKey: "linkOpenMode")
        defer { UserDefaults.standard.removeObject(forKey: "linkOpenMode") }
        XCTAssertEqual(AppSettings.shared.linkOpenMode, .browserTab)
    }
}
