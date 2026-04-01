import XCTest

@testable import Boo

final class ThemeTests: XCTestCase {

    func testAllThemesExist() {
        XCTAssertEqual(TerminalTheme.themes.count, 32)
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

    func testAllCatppuccinFlavors() {
        let names = TerminalTheme.themes.map(\.name)
        XCTAssertTrue(names.contains("Catppuccin Latte"))
        XCTAssertTrue(names.contains("Catppuccin Frappé"))
        XCTAssertTrue(names.contains("Catppuccin Macchiato"))
        XCTAssertTrue(names.contains("Catppuccin Mocha"))
    }

    func testThemeChromeColors() {
        for theme in TerminalTheme.themes {
            let chromeBg = theme.chromeBg.cgColor.components ?? []
            let chromeText = theme.chromeText.cgColor.components ?? []
            let chromeMuted = theme.chromeMuted.cgColor.components ?? []
            let sidebarBg = theme.sidebarBg.cgColor.components ?? []
            let accent = theme.accentColor.cgColor.components ?? []

            XCTAssertGreaterThan(chromeBg.count, 0, "Theme \(theme.name) needs a valid chromeBg color")
            XCTAssertGreaterThan(chromeText.count, 0, "Theme \(theme.name) needs a valid chromeText color")
            XCTAssertGreaterThan(chromeMuted.count, 0, "Theme \(theme.name) needs a valid chromeMuted color")
            XCTAssertGreaterThan(sidebarBg.count, 0, "Theme \(theme.name) needs a valid sidebarBg color")
            XCTAssertGreaterThan(accent.count, 0, "Theme \(theme.name) needs a valid accentColor")

            XCTAssertNotEqual(
                theme.chromeBg, theme.chromeText, "Theme \(theme.name) chrome text should differ from chrome background"
            )
            XCTAssertNotEqual(
                theme.sidebarBg, theme.accentColor, "Theme \(theme.name) accent should differ from sidebar background")
        }
    }

    func testLightThemesHaveLightBackground() {
        let latte = TerminalTheme.catppuccinLatte
        XCTAssertGreaterThan(latte.background.r, 200)
        XCTAssertGreaterThan(latte.background.g, 200)
        XCTAssertGreaterThan(latte.background.b, 200)

        let solLight = TerminalTheme.solarizedLight
        XCTAssertGreaterThan(solLight.background.r, 200)
    }

    func testDarkThemesHaveDarkBackground() {
        for theme in TerminalTheme.themes {
            let name = theme.name
            if name.contains("Latte") || name.contains("Light") { continue }
            // Dark themes should have bg < 80 on all channels
            XCTAssertLessThan(theme.background.r, 80, "Theme \(name) bg.r should be dark")
            XCTAssertLessThan(theme.background.g, 80, "Theme \(name) bg.g should be dark")
            XCTAssertLessThan(theme.background.b, 80, "Theme \(name) bg.b should be dark")
        }
    }

    func testThemeFGBGAreDifferent() {
        for theme in TerminalTheme.themes {
            XCTAssertNotEqual(theme.foreground, theme.background, "Theme \(theme.name) fg should differ from bg")
        }
    }

    func testSidebarBgIsNotNil() {
        for theme in TerminalTheme.themes {
            let components = theme.sidebarBg.cgColor.components ?? []
            XCTAssertGreaterThan(components.count, 0, "Theme \(theme.name) sidebarBg should have color components")
        }
    }

    func testSelectionColorHasAlpha() {
        for theme in TerminalTheme.themes {
            let alpha = theme.selection.alphaComponent
            XCTAssertLessThan(alpha, 1.0, "Theme \(theme.name) selection should be semi-transparent")
            XCTAssertGreaterThan(alpha, 0.0, "Theme \(theme.name) selection should not be fully transparent")
        }
    }

    func testThemeLookupByName() {
        let settings = AppSettings.shared
        let original = settings.themeName

        for theme in TerminalTheme.themes {
            settings.themeName = theme.name
            XCTAssertEqual(settings.theme.name, theme.name)
        }

        settings.themeName = original
    }

    func testInvalidThemeNameFallsBack() {
        let settings = AppSettings.shared
        let original = settings.themeName

        settings.themeName = "NonExistentTheme"
        XCTAssertEqual(settings.theme.name, "Default Dark")

        settings.themeName = original
    }
}
