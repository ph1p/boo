import XCTest

@testable import Boo

final class ThemeTests: XCTestCase {

    func testAllThemesExist() {
        XCTAssertEqual(TerminalTheme.themes.count, 12)
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

    /// Built-ins come in dark/light pairs so auto switching always has a partner.
    func testThemesComeInDarkLightPairs() {
        let dark = TerminalTheme.themes.filter(\.isDark).count
        XCTAssertEqual(dark, TerminalTheme.themes.count - dark)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double { OKLab.contrast(a, b) }

    /// Every built-in at every contrast level gets a generated interface that
    /// follows 60-30-10: the terminal background (60), a distinct chrome
    /// surface (30) and a readable accent (10), with legible text on chrome.
    func testGeneratedChromeIsReadable() {
        for base in TerminalTheme.themes {
            for level in ChromeContrast.allCases {
                let theme = base.withContrast(level)
                let id = "\(theme.name) [\(level.label)]"
                let chrome = theme.surfaceChrome
                XCTAssertNotEqual(chrome.hexString, theme.background.hexString, "\(id): chrome must differ from bg")
                XCTAssertNotEqual(theme.surfaceBackdrop.hexString, chrome.hexString, "\(id): backdrop must differ")
                XCTAssertNotEqual(theme.surfaceRaised.hexString, chrome.hexString, "\(id): raised must differ")
                XCTAssertGreaterThanOrEqual(contrast(theme.textPrimary, chrome), 6.95, "\(id): text needs 7:1")
                XCTAssertGreaterThanOrEqual(
                    contrast(theme.textMuted, chrome), level.mutedContrast - 0.05, "\(id): muted text too faint")
                XCTAssertGreaterThanOrEqual(contrast(theme.accent, chrome), 2.95, "\(id): accent needs 3:1 on chrome")
                XCTAssertGreaterThanOrEqual(
                    contrast(theme.accent, theme.background.nsColor), 2.95, "\(id): accent needs 3:1 on bg")
            }
        }
    }

    /// A stronger level moves the chrome further from the terminal background.
    func testContrastLevelsAreOrdered() {
        for base in TerminalTheme.themes {
            let bg = base.background.nsColor
            let gaps = ChromeContrast.allCases.map { contrast(base.withContrast($0).surfaceChrome, bg) }
            XCTAssertLessThan(gaps[0], gaps[1], "\(base.name): subtle should be closer than balanced")
            XCTAssertLessThan(gaps[1], gaps[2], "\(base.name): balanced should be closer than strong")
        }
    }

    /// Without an accent the generator picks a saturated palette color.
    func testAutoAccentComesFromPalette() {
        let base = TerminalTheme.booDark
        let auto = TerminalTheme(
            name: "Auto", foreground: base.foreground, background: base.background, cursor: base.cursor,
            selection: base.selection, ansiColors: base.ansiColors)
        XCTAssertNil(auto.accentOverride)
        XCTAssertGreaterThanOrEqual(contrast(auto.accent, auto.surfaceChrome), 2.95)
        XCTAssertNotEqual(auto.accent.hexString, auto.textPrimary.hexString)
    }

    func testCustomThemeDataKeepsAccentOverride() {
        let withAccent = CustomThemeData.from(TerminalTheme.booDark)
        XCTAssertEqual(withAccent.accentHex, TerminalTheme.booDark.accentOverride?.hexString)
        XCTAssertEqual(withAccent.toTheme().accent.hexString, TerminalTheme.booDark.accent.hexString)

        var auto = withAccent
        auto.accentHex = nil
        XCTAssertNil(auto.toTheme().accentOverride)
        XCTAssertTrue(auto.toTheme().isCustom)
    }

    func testChromeContrastSettingAppliesToTheme() {
        let settings = AppSettings.shared
        let original = settings.chromeContrast
        defer { settings.chromeContrast = original }

        for level in ChromeContrast.allCases {
            settings.chromeContrast = level
            XCTAssertEqual(settings.theme.contrast, level)
            XCTAssertEqual(settings.theme(named: "Boo Light")?.contrast, level)
        }
    }

    func testGhosttyCatalogListsAndParsesThemes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boo-ghostty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = """
            palette = 1=#e06c75
            palette = 4=#61afef
            background = #1e2127
            foreground = #abb2bf
            cursor-color = #61afef
            """
        try file.write(to: dir.appendingPathComponent("Zeta Test"), atomically: true, encoding: .utf8)
        try file.write(to: dir.appendingPathComponent("Boo Dark"), atomically: true, encoding: .utf8)
        try "not a theme".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let catalog = GhosttyThemeCatalog(directory: dir.path)
        XCTAssertEqual(catalog.names, ["Zeta Test"], "curated names and dotfiles are hidden")

        let theme = try XCTUnwrap(catalog.theme(named: "Zeta Test"))
        XCTAssertFalse(theme.isCustom)
        XCTAssertEqual(theme.background.hexString.uppercased(), "#1E2127")
        XCTAssertNil(catalog.theme(named: "Missing"))
        XCTAssertNil(catalog.theme(named: "../etc/passwd"))
    }

    /// The app bundle ships the themes packed by scripts/pack-ghostty-themes.sh;
    /// the catalog reads that file like the folder it came from.
    func testGhosttyCatalogReadsThePackedThemes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boo-ghostty-\(UUID().uuidString)")
        let themes = dir.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #1e2127\nforeground = #abb2bf\n"
            .write(to: themes.appendingPathComponent("Zeta Test"), atomically: true, encoding: .utf8)
        try "background = #fafafa\nforeground = #383a42"  // no trailing newline
            .write(to: themes.appendingPathComponent("Alpha (Light)"), atomically: true, encoding: .utf8)
        try "not a theme".write(to: themes.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-ghostty-themes.sh")
        let pack = dir.appendingPathComponent("themes.pack")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, themes.path, pack.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let catalog = GhosttyThemeCatalog(source: .pack(pack.path))
        XCTAssertEqual(catalog.names, ["Alpha (Light)", "Zeta Test"])
        XCTAssertEqual(catalog.theme(named: "Zeta Test")?.background.hexString.uppercased(), "#1E2127")
        XCTAssertEqual(catalog.theme(named: "Alpha (Light)")?.foreground.hexString.uppercased(), "#383A42")
        XCTAssertNil(catalog.theme(named: "Missing"))
    }

    func testLightThemesHaveLightBackground() {
        let latte = TerminalTheme.catppuccinLatte
        XCTAssertGreaterThan(latte.background.r, 200)
        XCTAssertGreaterThan(latte.background.g, 200)
        XCTAssertGreaterThan(latte.background.b, 200)

        let dawn = TerminalTheme.rosePineDawn
        XCTAssertGreaterThan(dawn.background.r, 200)
    }

    func testDarkThemesHaveDarkBackground() {
        for theme in TerminalTheme.themes {
            let name = theme.name
            if !theme.isDark { continue }
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
        XCTAssertEqual(settings.theme.name, "Boo Dark")

        settings.themeName = original
    }
}
