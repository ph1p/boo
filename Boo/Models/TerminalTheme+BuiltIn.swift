import Cocoa

// MARK: - Built-in themes

/// A curated set: six families, each with a dark and a light variant, so
/// automatic dark/light switching always has a matching partner.
extension TerminalTheme {
    static let themes: [TerminalTheme] = [
        .booDark,
        .booLight,
        .catppuccinMocha,
        .catppuccinLatte,
        .tokyoNight,
        .tokyoNightDay,
        .rosePine,
        .rosePineDawn,
        .gruvboxDark,
        .gruvboxLight,
        .githubDark,
        .githubLight
    ]

    /// Monochrome palette of the app icon and the landing page with a ghost-violet
    /// accent, dark variant.
    static let booDark = TerminalTheme(
        name: "Boo Dark",
        foreground: TerminalColor(r: 245, g: 245, b: 245),
        background: TerminalColor(r: 12, g: 12, b: 12),
        cursor: TerminalColor(r: 180, g: 160, b: 255),
        selection: NSColor(red: 180 / 255, green: 160 / 255, blue: 255 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 38, g: 38, b: 38),  // 0 black
            TerminalColor(r: 255, g: 138, b: 122),  // 1 red
            TerminalColor(r: 127, g: 209, b: 168),  // 2 green
            TerminalColor(r: 246, g: 179, b: 82),  // 3 yellow
            TerminalColor(r: 143, g: 184, b: 255),  // 4 blue
            TerminalColor(r: 200, g: 166, b: 245),  // 5 magenta
            TerminalColor(r: 134, g: 213, b: 224),  // 6 cyan
            TerminalColor(r: 212, g: 212, b: 212),  // 7 white
            TerminalColor(r: 115, g: 115, b: 115),  // 8 bright black
            TerminalColor(r: 255, g: 166, b: 152),  // 9 bright red
            TerminalColor(r: 143, g: 224, b: 181),  // 10 bright green
            TerminalColor(r: 255, g: 213, b: 154),  // 11 bright yellow
            TerminalColor(r: 171, g: 202, b: 255),  // 12 bright blue
            TerminalColor(r: 217, g: 192, b: 250),  // 13 bright magenta
            TerminalColor(r: 165, g: 227, b: 236),  // 14 bright cyan
            TerminalColor(r: 255, g: 255, b: 255)  // 15 bright white
        ],
        accent: NSColor(red: 180 / 255, green: 160 / 255, blue: 255 / 255, alpha: 1)
    )

    /// Monochrome palette of the app icon and the landing page with a ghost-violet
    /// accent, light variant.
    static let booLight = TerminalTheme(
        name: "Boo Light",
        foreground: TerminalColor(r: 10, g: 10, b: 10),
        background: TerminalColor(r: 247, g: 247, b: 247),
        cursor: TerminalColor(r: 109, g: 74, b: 224),
        selection: NSColor(red: 109 / 255, green: 74 / 255, blue: 224 / 255, alpha: 0.22),
        ansiColors: [
            TerminalColor(r: 38, g: 38, b: 38),  // 0 black
            TerminalColor(r: 184, g: 56, b: 44),  // 1 red
            TerminalColor(r: 28, g: 118, b: 86),  // 2 green
            TerminalColor(r: 168, g: 100, b: 10),  // 3 yellow
            TerminalColor(r: 43, g: 95, b: 184),  // 4 blue
            TerminalColor(r: 123, g: 63, b: 176),  // 5 magenta
            TerminalColor(r: 15, g: 118, b: 132),  // 6 cyan
            TerminalColor(r: 115, g: 115, b: 115),  // 7 white
            TerminalColor(r: 82, g: 82, b: 82),  // 8 bright black
            TerminalColor(r: 210, g: 74, b: 60),  // 9 bright red
            TerminalColor(r: 35, g: 144, b: 106),  // 10 bright green
            TerminalColor(r: 194, g: 122, b: 20),  // 11 bright yellow
            TerminalColor(r: 59, g: 117, b: 214),  // 12 bright blue
            TerminalColor(r: 147, g: 83, b: 204),  // 13 bright magenta
            TerminalColor(r: 22, g: 143, b: 159),  // 14 bright cyan
            TerminalColor(r: 10, g: 10, b: 10)  // 15 bright white
        ],
        accent: NSColor(red: 109 / 255, green: 74 / 255, blue: 224 / 255, alpha: 1)
    )

    static let catppuccinMocha = TerminalTheme(
        name: "Catppuccin Mocha",
        foreground: TerminalColor(r: 205, g: 214, b: 244),
        background: TerminalColor(r: 30, g: 30, b: 46),
        cursor: TerminalColor(r: 137, g: 180, b: 250),
        selection: NSColor(red: 137 / 255, green: 180 / 255, blue: 250 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 69, g: 71, b: 90),
            TerminalColor(r: 255, g: 156, b: 186),
            TerminalColor(r: 183, g: 248, b: 177),
            TerminalColor(r: 255, g: 246, b: 191),
            TerminalColor(r: 153, g: 199, b: 255),
            TerminalColor(r: 223, g: 184, b: 255),
            TerminalColor(r: 164, g: 247, b: 233),
            TerminalColor(r: 186, g: 194, b: 222),
            TerminalColor(r: 88, g: 91, b: 112),
            TerminalColor(r: 243, g: 139, b: 168),
            TerminalColor(r: 166, g: 227, b: 161),
            TerminalColor(r: 249, g: 226, b: 175),
            TerminalColor(r: 137, g: 180, b: 250),
            TerminalColor(r: 203, g: 166, b: 247),
            TerminalColor(r: 148, g: 226, b: 213),
            TerminalColor(r: 205, g: 214, b: 244)
        ],
        accent: NSColor(red: 137 / 255, green: 180 / 255, blue: 250 / 255, alpha: 1)
    )

    static let catppuccinLatte = TerminalTheme(
        name: "Catppuccin Latte",
        foreground: TerminalColor(r: 76, g: 79, b: 105),
        background: TerminalColor(r: 239, g: 241, b: 245),
        cursor: TerminalColor(r: 30, g: 102, b: 245),
        selection: NSColor(red: 30 / 255, green: 102 / 255, blue: 245 / 255, alpha: 0.22),
        ansiColors: [
            TerminalColor(r: 92, g: 95, b: 119),
            TerminalColor(r: 192, g: 0, b: 36),
            TerminalColor(r: 35, g: 142, b: 0),
            TerminalColor(r: 206, g: 122, b: 0),
            TerminalColor(r: 0, g: 79, b: 230),
            TerminalColor(r: 121, g: 12, b: 224),
            TerminalColor(r: 0, g: 128, b: 136),
            TerminalColor(r: 172, g: 176, b: 190),
            TerminalColor(r: 108, g: 111, b: 133),
            TerminalColor(r: 210, g: 15, b: 57),
            TerminalColor(r: 64, g: 160, b: 43),
            TerminalColor(r: 223, g: 142, b: 29),
            TerminalColor(r: 30, g: 102, b: 245),
            TerminalColor(r: 136, g: 57, b: 239),
            TerminalColor(r: 23, g: 146, b: 153),
            TerminalColor(r: 76, g: 79, b: 105)
        ],
        accent: NSColor(red: 30 / 255, green: 102 / 255, blue: 245 / 255, alpha: 1)
    )

    static let tokyoNight = TerminalTheme(
        name: "Tokyo Night",
        foreground: TerminalColor(r: 192, g: 202, b: 245),
        background: TerminalColor(r: 26, g: 27, b: 38),
        cursor: TerminalColor(r: 122, g: 162, b: 247),
        selection: NSColor(red: 122 / 255, green: 162 / 255, blue: 247 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 21, g: 22, b: 30),
            TerminalColor(r: 255, g: 134, b: 159),
            TerminalColor(r: 175, g: 227, b: 120),
            TerminalColor(r: 246, g: 194, b: 118),
            TerminalColor(r: 138, g: 181, b: 255),
            TerminalColor(r: 207, g: 172, b: 255),
            TerminalColor(r: 140, g: 227, b: 255),
            TerminalColor(r: 192, g: 202, b: 245),
            TerminalColor(r: 65, g: 72, b: 104),
            TerminalColor(r: 247, g: 118, b: 142),
            TerminalColor(r: 158, g: 206, b: 106),
            TerminalColor(r: 224, g: 175, b: 104),
            TerminalColor(r: 122, g: 162, b: 247),
            TerminalColor(r: 187, g: 154, b: 247),
            TerminalColor(r: 125, g: 207, b: 255),
            TerminalColor(r: 192, g: 202, b: 245)
        ],
        accent: NSColor(red: 122 / 255, green: 162 / 255, blue: 247 / 255, alpha: 1)
    )

    static let tokyoNightDay = TerminalTheme(
        name: "Tokyo Night Day",
        foreground: TerminalColor(r: 55, g: 96, b: 191),
        background: TerminalColor(r: 225, g: 226, b: 231),
        cursor: TerminalColor(r: 38, g: 117, b: 225),
        selection: NSColor(red: 38 / 255, green: 117 / 255, blue: 225 / 255, alpha: 0.22),
        ansiColors: [
            TerminalColor(r: 180, g: 181, b: 185),  // 0 black
            TerminalColor(r: 245, g: 42, b: 101),  // 1 red
            TerminalColor(r: 88, g: 117, b: 57),  // 2 green
            TerminalColor(r: 140, g: 108, b: 62),  // 3 yellow
            TerminalColor(r: 46, g: 125, b: 233),  // 4 blue
            TerminalColor(r: 152, g: 84, b: 241),  // 5 magenta
            TerminalColor(r: 0, g: 113, b: 151),  // 6 cyan
            TerminalColor(r: 97, g: 114, b: 176),  // 7 white
            TerminalColor(r: 161, g: 166, b: 197),  // 8 bright black
            TerminalColor(r: 227, g: 0, b: 82),  // 9 bright red
            TerminalColor(r: 71, g: 100, b: 36),  // 10 bright green
            TerminalColor(r: 123, g: 90, b: 41),  // 11 bright yellow
            TerminalColor(r: 12, g: 105, b: 217),  // 12 bright blue
            TerminalColor(r: 136, g: 58, b: 225),  // 13 bright magenta
            TerminalColor(r: 0, g: 96, b: 135),  // 14 bright cyan
            TerminalColor(r: 55, g: 96, b: 191)  // 15 bright white
        ],
        accent: NSColor(red: 38 / 255, green: 117 / 255, blue: 225 / 255, alpha: 1)
    )

    static let rosePine = TerminalTheme(
        name: "Rosé Pine",
        foreground: TerminalColor(r: 224, g: 222, b: 244),
        background: TerminalColor(r: 25, g: 23, b: 36),
        cursor: TerminalColor(r: 196, g: 167, b: 231),
        selection: NSColor(red: 196 / 255, green: 167 / 255, blue: 231 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 38, g: 35, b: 53),
            TerminalColor(r: 255, g: 127, b: 164),
            TerminalColor(r: 64, g: 134, b: 163),
            TerminalColor(r: 255, g: 212, b: 133),
            TerminalColor(r: 173, g: 227, b: 237),
            TerminalColor(r: 216, g: 185, b: 254),
            TerminalColor(r: 255, g: 171, b: 168),
            TerminalColor(r: 224, g: 222, b: 244),
            TerminalColor(r: 110, g: 106, b: 134),
            TerminalColor(r: 235, g: 111, b: 146),
            TerminalColor(r: 49, g: 116, b: 143),
            TerminalColor(r: 246, g: 193, b: 119),
            TerminalColor(r: 156, g: 207, b: 216),
            TerminalColor(r: 196, g: 167, b: 231),
            TerminalColor(r: 234, g: 154, b: 151),
            TerminalColor(r: 224, g: 222, b: 244)
        ],
        accent: NSColor(red: 196 / 255, green: 167 / 255, blue: 231 / 255, alpha: 1)
    )

    static let rosePineDawn = TerminalTheme(
        name: "Rosé Pine Dawn",
        foreground: TerminalColor(r: 87, g: 82, b: 121),
        background: TerminalColor(r: 250, g: 244, b: 237),
        cursor: TerminalColor(r: 144, g: 122, b: 169),
        selection: NSColor(red: 144 / 255, green: 122 / 255, blue: 169 / 255, alpha: 0.22),
        ansiColors: [
            TerminalColor(r: 242, g: 233, b: 225),  // 0 black
            TerminalColor(r: 180, g: 99, b: 122),  // 1 red
            TerminalColor(r: 40, g: 105, b: 131),  // 2 green
            TerminalColor(r: 234, g: 157, b: 52),  // 3 yellow
            TerminalColor(r: 86, g: 148, b: 159),  // 4 blue
            TerminalColor(r: 144, g: 122, b: 169),  // 5 magenta
            TerminalColor(r: 215, g: 130, b: 126),  // 6 cyan
            TerminalColor(r: 87, g: 82, b: 121),  // 7 white
            TerminalColor(r: 152, g: 147, b: 165),  // 8 bright black
            TerminalColor(r: 163, g: 80, b: 104),  // 9 bright red
            TerminalColor(r: 9, g: 88, b: 115),  // 10 bright green
            TerminalColor(r: 216, g: 137, b: 0),  // 11 bright yellow
            TerminalColor(r: 64, g: 130, b: 142),  // 12 bright blue
            TerminalColor(r: 127, g: 104, b: 152),  // 13 bright magenta
            TerminalColor(r: 197, g: 110, b: 107),  // 14 bright cyan
            TerminalColor(r: 87, g: 82, b: 121)  // 15 bright white
        ],
        accent: NSColor(red: 144 / 255, green: 122 / 255, blue: 169 / 255, alpha: 1)
    )

    static let gruvboxDark = TerminalTheme(
        name: "Gruvbox Dark",
        foreground: TerminalColor(r: 235, g: 219, b: 178),
        background: TerminalColor(r: 40, g: 40, b: 40),
        cursor: TerminalColor(r: 215, g: 153, b: 33),
        selection: NSColor(red: 215 / 255, green: 153 / 255, blue: 33 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 40, g: 40, b: 40),
            TerminalColor(r: 204, g: 36, b: 29),
            TerminalColor(r: 152, g: 151, b: 26),
            TerminalColor(r: 215, g: 153, b: 33),
            TerminalColor(r: 69, g: 133, b: 136),
            TerminalColor(r: 177, g: 98, b: 134),
            TerminalColor(r: 104, g: 157, b: 106),
            TerminalColor(r: 168, g: 153, b: 132),
            TerminalColor(r: 146, g: 131, b: 116),
            TerminalColor(r: 251, g: 73, b: 52),
            TerminalColor(r: 184, g: 187, b: 38),
            TerminalColor(r: 250, g: 189, b: 47),
            TerminalColor(r: 131, g: 165, b: 152),
            TerminalColor(r: 211, g: 134, b: 155),
            TerminalColor(r: 142, g: 192, b: 124),
            TerminalColor(r: 235, g: 219, b: 178)
        ],
        accent: NSColor(red: 215 / 255, green: 153 / 255, blue: 33 / 255, alpha: 1)
    )

    static let gruvboxLight = TerminalTheme(
        name: "Gruvbox Light",
        foreground: TerminalColor(r: 60, g: 56, b: 54),
        background: TerminalColor(r: 251, g: 241, b: 199),
        cursor: TerminalColor(r: 178, g: 118, b: 0),
        selection: NSColor(red: 178 / 255, green: 118 / 255, blue: 0 / 255, alpha: 0.22),
        ansiColors: [
            TerminalColor(r: 251, g: 241, b: 199),  // 0 black
            TerminalColor(r: 204, g: 36, b: 29),  // 1 red
            TerminalColor(r: 152, g: 151, b: 26),  // 2 green
            TerminalColor(r: 215, g: 153, b: 33),  // 3 yellow
            TerminalColor(r: 69, g: 133, b: 136),  // 4 blue
            TerminalColor(r: 177, g: 98, b: 134),  // 5 magenta
            TerminalColor(r: 104, g: 157, b: 106),  // 6 cyan
            TerminalColor(r: 60, g: 56, b: 54),  // 7 white
            TerminalColor(r: 146, g: 131, b: 116),  // 8 bright black
            TerminalColor(r: 157, g: 0, b: 6),  // 9 bright red
            TerminalColor(r: 121, g: 116, b: 14),  // 10 bright green
            TerminalColor(r: 181, g: 118, b: 20),  // 11 bright yellow
            TerminalColor(r: 7, g: 102, b: 120),  // 12 bright blue
            TerminalColor(r: 143, g: 63, b: 113),  // 13 bright magenta
            TerminalColor(r: 66, g: 123, b: 88),  // 14 bright cyan
            TerminalColor(r: 40, g: 40, b: 40)  // 15 bright white
        ],
        accent: NSColor(red: 178 / 255, green: 118 / 255, blue: 0 / 255, alpha: 1)
    )

    static let githubDark = TerminalTheme(
        name: "GitHub Dark",
        foreground: TerminalColor(r: 201, g: 209, b: 217),
        background: TerminalColor(r: 13, g: 17, b: 23),
        cursor: TerminalColor(r: 88, g: 166, b: 255),
        selection: NSColor(red: 88 / 255, green: 166 / 255, blue: 255 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 72, g: 79, b: 88),  // 0 black
            TerminalColor(r: 255, g: 123, b: 114),  // 1 red
            TerminalColor(r: 63, g: 185, b: 80),  // 2 green
            TerminalColor(r: 210, g: 153, b: 34),  // 3 yellow
            TerminalColor(r: 88, g: 166, b: 255),  // 4 blue
            TerminalColor(r: 188, g: 140, b: 255),  // 5 magenta
            TerminalColor(r: 57, g: 211, b: 220),  // 6 cyan
            TerminalColor(r: 201, g: 209, b: 217),  // 7 white
            TerminalColor(r: 110, g: 118, b: 129),  // 8 bright black
            TerminalColor(r: 255, g: 139, b: 129),  // 9 bright red
            TerminalColor(r: 78, g: 206, b: 94),  // 10 bright green
            TerminalColor(r: 232, g: 171, b: 49),  // 11 bright yellow
            TerminalColor(r: 102, g: 185, b: 255),  // 12 bright blue
            TerminalColor(r: 208, g: 157, b: 255),  // 13 bright magenta
            TerminalColor(r: 71, g: 232, b: 241),  // 14 bright cyan
            TerminalColor(r: 201, g: 209, b: 217)  // 15 bright white
        ],
        accent: NSColor(red: 88 / 255, green: 166 / 255, blue: 255 / 255, alpha: 1)
    )

    static let githubLight = TerminalTheme(
        name: "GitHub Light",
        foreground: TerminalColor(r: 31, g: 35, b: 40),
        background: TerminalColor(r: 250, g: 251, b: 252),
        cursor: TerminalColor(r: 2, g: 82, b: 204),
        selection: NSColor(red: 2 / 255, green: 82 / 255, blue: 204 / 255, alpha: 0.22),
        ansiColors: [
            TerminalColor(r: 31, g: 35, b: 40),  // 0 black
            TerminalColor(r: 207, g: 34, b: 46),  // 1 red
            TerminalColor(r: 26, g: 127, b: 55),  // 2 green
            TerminalColor(r: 155, g: 103, b: 0),  // 3 yellow
            TerminalColor(r: 2, g: 82, b: 204),  // 4 blue
            TerminalColor(r: 130, g: 80, b: 223),  // 5 magenta
            TerminalColor(r: 5, g: 107, b: 121),  // 6 cyan
            TerminalColor(r: 31, g: 35, b: 40),  // 7 white
            TerminalColor(r: 110, g: 119, b: 129),  // 8 bright black
            TerminalColor(r: 164, g: 38, b: 44),  // 9 bright red
            TerminalColor(r: 0, g: 110, b: 33),  // 10 bright green
            TerminalColor(r: 138, g: 85, b: 0),  // 11 bright yellow
            TerminalColor(r: 0, g: 60, b: 189),  // 12 bright blue
            TerminalColor(r: 114, g: 55, b: 207),  // 13 bright magenta
            TerminalColor(r: 0, g: 90, b: 105),  // 14 bright cyan
            TerminalColor(r: 31, g: 35, b: 40)  // 15 bright white
        ],
        accent: NSColor(red: 2 / 255, green: 82 / 255, blue: 204 / 255, alpha: 1)
    )
}
