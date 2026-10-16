import XCTest

@testable import Boo

/// `AppSettings.theme` caches the resolved custom theme; it must still see
/// every change to the stored custom themes (keyed on the stored bytes).
final class CustomThemeCacheTests: XCTestCase {

    private let key = "customThemes"

    func testCustomThemeEditIsNotServedStale() throws {
        let settings = AppSettings.shared
        let defaults = UserDefaults.standard
        let originalData = defaults.data(forKey: key)
        let originalName = settings.themeName
        defer {
            if let originalData { defaults.set(originalData, forKey: key) } else { defaults.removeObject(forKey: key) }
            defaults.set(originalName, forKey: "themeName")
        }

        var custom = CustomThemeData.from(.defaultDark)
        custom.name = "Cache Test Theme"
        custom.accentHex = "#112233"
        defaults.set(try JSONEncoder().encode([custom]), forKey: key)
        defaults.set(custom.name, forKey: "themeName")

        XCTAssertEqual(settings.theme.name, "Cache Test Theme")
        let first = settings.theme.accentColor.usingColorSpace(.sRGB)
        XCTAssertEqual(first?.redComponent ?? -1, 0x11 / 255.0, accuracy: 0.01)

        // Write behind the setter's back — the cache must notice the new bytes.
        custom.accentHex = "#AA2233"
        defaults.set(try JSONEncoder().encode([custom]), forKey: key)
        let second = settings.theme.accentColor.usingColorSpace(.sRGB)
        XCTAssertEqual(second?.redComponent ?? -1, 0xAA / 255.0, accuracy: 0.01)

        // Selecting a different (missing) custom name falls back, not the cached one.
        defaults.set("Missing Theme", forKey: "themeName")
        XCTAssertEqual(settings.theme.name, TerminalTheme.defaultDark.name)
    }
}
