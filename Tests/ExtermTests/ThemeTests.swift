import XCTest
@testable import Exterm

final class ThemeTests: XCTestCase {

    func testAllThemesExist() {
        XCTAssertEqual(TerminalTheme.themes.count, 14)
    }

    func testAllThemesHave16AnsiColors() {
        for theme in TerminalTheme.themes {
            XCTAssertEqual(theme.ansiColors.count, 16, "Theme \(theme.name) should have 16 ANSI colors")
        }
    }

    func testAllThemesHaveUniqueNames() {
        let names = TerminalTheme.themes.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Theme names should be unique")
    }

    func testDefaultDarkExists() {
        XCTAssertEqual(TerminalTheme.defaultDark.name, "Default Dark")
    }

    func testAllCatppuccinFlavors() {
        let names = TerminalTheme.themes.map(\.name)
        XCTAssertTrue(names.contains("Catppuccin Latte"))
        XCTAssertTrue(names.contains("Catppuccin Frappé"))
        XCTAssertTrue(names.contains("Catppuccin Macchiato"))
        XCTAssertTrue(names.contains("Catppuccin Mocha"))
    }

    func testThemeChromeColors() {
        for theme in TerminalTheme.themes {
            XCTAssertNotNil(theme.chromeBg, "Theme \(theme.name) needs chromeBg")
            XCTAssertNotNil(theme.chromeText, "Theme \(theme.name) needs chromeText")
            XCTAssertNotNil(theme.chromeMuted, "Theme \(theme.name) needs chromeMuted")
            XCTAssertNotNil(theme.sidebarBg, "Theme \(theme.name) needs sidebarBg")
            XCTAssertNotNil(theme.accentColor, "Theme \(theme.name) needs accentColor")
        }
    }

    func testLightThemesHaveLightBackground() {
        let latte = TerminalTheme.catppuccinLatte
        // Latte is a light theme — background should be light (high RGB values)
        XCTAssertGreaterThan(latte.background.r, 200)
        XCTAssertGreaterThan(latte.background.g, 200)
        XCTAssertGreaterThan(latte.background.b, 200)
    }
}
