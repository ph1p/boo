import Cocoa

struct TerminalTheme {
    let name: String
    let foreground: TerminalColor
    let background: TerminalColor
    let cursor: TerminalColor
    let selection: NSColor
    let ansiColors: [TerminalColor]  // 16 colors: 8 normal + 8 bright

    // UI chrome colors
    let chromeBg: NSColor  // toolbar, status bar
    let chromeText: NSColor
    let chromeMuted: NSColor
    let sidebarBg: NSColor
    let accentColor: NSColor

    /// Opaque border color: chromeMuted at 20% blended over chromeBg.
    /// Use this instead of `chromeMuted.withAlphaComponent(0.2)` for borders
    /// so overlapping draws don't produce darker artifacts.
    var chromeBorder: NSColor {
        let alpha: CGFloat = 0.2
        let fg = chromeMuted
        let bg = chromeBg
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Sidebar border: chromeMuted at 20% blended over sidebarBg.
    var sidebarBorder: NSColor {
        let alpha: CGFloat = 0.2
        let fg = chromeMuted
        let bg = sidebarBg
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Whether this is a dark theme (background luminance < 0.5).
    var isDark: Bool {
        let r = CGFloat(background.r) / 255
        let g = CGFloat(background.g) / 255
        let b = CGFloat(background.b) / 255
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }
}

extension TerminalTheme {
    static let themes: [TerminalTheme] = [
        .defaultDark,
        .defaultLight,
        .tokyoNight,
        .catppuccinLatte,
        .catppuccinFrappe,
        .catppuccinMacchiato,
        .catppuccinMocha,
        .solarizedDark,
        .solarizedLight,
        .dracula,
        .nord,
        .gruvboxDark,
        .gruvboxLight,
        .oneDark,
        .oneLight,
        .rosePine,
        .kanagawa,
        .everforestDark,
        .everforestLight,
        .githubDark,
        .githubLight,
        .ayuDark,
        .ayuLight,
        .monokai,
        .materialDark,
        .materialLight,
        .palenight,
        .horizonDark,
        .cobalt2,
        .nightOwl,
        .synthwave84,
        .moonlight,
    ]

    static let defaultDark = TerminalTheme(
        name: "Default Dark",
        foreground: TerminalColor(r: 228, g: 228, b: 232),
        background: TerminalColor(r: 21, g: 21, b: 23),
        cursor: TerminalColor(r: 228, g: 228, b: 232),
        selection: NSColor(red: 77 / 255, green: 143 / 255, blue: 232 / 255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 50, g: 50, b: 55),  // 0 black
            TerminalColor(r: 255, g: 92, b: 87),  // 1 red
            TerminalColor(r: 90, g: 247, b: 142),  // 2 green
            TerminalColor(r: 243, g: 249, b: 157),  // 3 yellow
            TerminalColor(r: 87, g: 199, b: 255),  // 4 blue
            TerminalColor(r: 215, g: 131, b: 255),  // 5 magenta
            TerminalColor(r: 90, g: 240, b: 225),  // 6 cyan
            TerminalColor(r: 228, g: 228, b: 232),  // 7 white
            TerminalColor(r: 102, g: 102, b: 110),  // 8 bright black
            TerminalColor(r: 255, g: 110, b: 103),  // 9 bright red
            TerminalColor(r: 98, g: 255, b: 158),  // 10 bright green
            TerminalColor(r: 255, g: 255, b: 170),  // 11 bright yellow
            TerminalColor(r: 105, g: 212, b: 255),  // 12 bright blue
            TerminalColor(r: 225, g: 150, b: 255),  // 13 bright magenta
            TerminalColor(r: 104, g: 250, b: 237),  // 14 bright cyan
            TerminalColor(r: 242, g: 242, b: 246)  // 15 bright white
        ],
        chromeBg: NSColor(red: 13 / 255, green: 13 / 255, blue: 15 / 255, alpha: 1),
        chromeText: NSColor(red: 228 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1),
        chromeMuted: NSColor(red: 100 / 255, green: 100 / 255, blue: 108 / 255, alpha: 1),
        sidebarBg: NSColor(red: 24 / 255, green: 24 / 255, blue: 27 / 255, alpha: 1),
        accentColor: NSColor(red: 77 / 255, green: 143 / 255, blue: 232 / 255, alpha: 1)
    )

    static let tokyoNight = TerminalTheme(
        name: "Tokyo Night",
        foreground: TerminalColor(r: 192, g: 202, b: 245),
        background: TerminalColor(r: 26, g: 27, b: 38),
        cursor: TerminalColor(r: 192, g: 202, b: 245),
        selection: NSColor(red: 40 / 255, green: 52 / 255, blue: 96 / 255, alpha: 0.6),
        ansiColors: [
            TerminalColor(r: 21, g: 22, b: 30),
            TerminalColor(r: 247, g: 118, b: 142),
            TerminalColor(r: 158, g: 206, b: 106),
            TerminalColor(r: 224, g: 175, b: 104),
            TerminalColor(r: 122, g: 162, b: 247),
            TerminalColor(r: 187, g: 154, b: 247),
            TerminalColor(r: 125, g: 207, b: 255),
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
        chromeBg: NSColor(red: 22 / 255, green: 22 / 255, blue: 30 / 255, alpha: 1),
        chromeText: NSColor(red: 192 / 255, green: 202 / 255, blue: 245 / 255, alpha: 1),
        chromeMuted: NSColor(red: 86 / 255, green: 95 / 255, blue: 137 / 255, alpha: 1),
        sidebarBg: NSColor(red: 30 / 255, green: 31 / 255, blue: 42 / 255, alpha: 1),
        accentColor: NSColor(red: 122 / 255, green: 162 / 255, blue: 247 / 255, alpha: 1)
    )

    static let catppuccinLatte = TerminalTheme(
        name: "Catppuccin Latte",
        foreground: TerminalColor(r: 76, g: 79, b: 105),
        background: TerminalColor(r: 239, g: 241, b: 245),
        cursor: TerminalColor(r: 76, g: 79, b: 105),
        selection: NSColor(red: 172 / 255, green: 176 / 255, blue: 190 / 255, alpha: 0.4),
        ansiColors: [
            TerminalColor(r: 92, g: 95, b: 119),
            TerminalColor(r: 210, g: 15, b: 57),
            TerminalColor(r: 64, g: 160, b: 43),
            TerminalColor(r: 223, g: 142, b: 29),
            TerminalColor(r: 30, g: 102, b: 245),
            TerminalColor(r: 136, g: 57, b: 239),
            TerminalColor(r: 23, g: 146, b: 153),
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
        chromeBg: NSColor(red: 230 / 255, green: 233 / 255, blue: 239 / 255, alpha: 1),
        chromeText: NSColor(red: 76 / 255, green: 79 / 255, blue: 105 / 255, alpha: 1),
        chromeMuted: NSColor(red: 108 / 255, green: 111 / 255, blue: 133 / 255, alpha: 1),
        sidebarBg: NSColor(red: 239 / 255, green: 241 / 255, blue: 245 / 255, alpha: 1),
        accentColor: NSColor(red: 30 / 255, green: 102 / 255, blue: 245 / 255, alpha: 1)
    )

    static let catppuccinFrappe = TerminalTheme(
        name: "Catppuccin Frappé",
        foreground: TerminalColor(r: 198, g: 208, b: 245),
        background: TerminalColor(r: 48, g: 52, b: 70),
        cursor: TerminalColor(r: 242, g: 213, b: 207),
        selection: NSColor(red: 81 / 255, green: 87 / 255, blue: 109 / 255, alpha: 0.4),
        ansiColors: [
            TerminalColor(r: 65, g: 69, b: 89),
            TerminalColor(r: 231, g: 130, b: 132),
            TerminalColor(r: 166, g: 209, b: 137),
            TerminalColor(r: 229, g: 200, b: 144),
            TerminalColor(r: 140, g: 170, b: 238),
            TerminalColor(r: 202, g: 158, b: 230),
            TerminalColor(r: 129, g: 200, b: 190),
            TerminalColor(r: 181, g: 191, b: 226),
            TerminalColor(r: 98, g: 104, b: 128),
            TerminalColor(r: 231, g: 130, b: 132),
            TerminalColor(r: 166, g: 209, b: 137),
            TerminalColor(r: 229, g: 200, b: 144),
            TerminalColor(r: 140, g: 170, b: 238),
            TerminalColor(r: 202, g: 158, b: 230),
            TerminalColor(r: 129, g: 200, b: 190),
            TerminalColor(r: 198, g: 208, b: 245)
        ],
        chromeBg: NSColor(red: 41 / 255, green: 44 / 255, blue: 60 / 255, alpha: 1),
        chromeText: NSColor(red: 198 / 255, green: 208 / 255, blue: 245 / 255, alpha: 1),
        chromeMuted: NSColor(red: 115 / 255, green: 121 / 255, blue: 148 / 255, alpha: 1),
        sidebarBg: NSColor(red: 48 / 255, green: 52 / 255, blue: 70 / 255, alpha: 1),
        accentColor: NSColor(red: 140 / 255, green: 170 / 255, blue: 238 / 255, alpha: 1)
    )

    static let catppuccinMacchiato = TerminalTheme(
        name: "Catppuccin Macchiato",
        foreground: TerminalColor(r: 202, g: 211, b: 245),
        background: TerminalColor(r: 36, g: 39, b: 58),
        cursor: TerminalColor(r: 244, g: 219, b: 214),
        selection: NSColor(red: 73 / 255, green: 77 / 255, blue: 100 / 255, alpha: 0.4),
        ansiColors: [
            TerminalColor(r: 54, g: 58, b: 79),
            TerminalColor(r: 237, g: 135, b: 150),
            TerminalColor(r: 166, g: 218, b: 149),
            TerminalColor(r: 238, g: 212, b: 159),
            TerminalColor(r: 138, g: 173, b: 244),
            TerminalColor(r: 198, g: 160, b: 246),
            TerminalColor(r: 139, g: 213, b: 202),
            TerminalColor(r: 184, g: 192, b: 224),
            TerminalColor(r: 91, g: 96, b: 120),
            TerminalColor(r: 237, g: 135, b: 150),
            TerminalColor(r: 166, g: 218, b: 149),
            TerminalColor(r: 238, g: 212, b: 159),
            TerminalColor(r: 138, g: 173, b: 244),
            TerminalColor(r: 198, g: 160, b: 246),
            TerminalColor(r: 139, g: 213, b: 202),
            TerminalColor(r: 202, g: 211, b: 245)
        ],
        chromeBg: NSColor(red: 30 / 255, green: 32 / 255, blue: 48 / 255, alpha: 1),
        chromeText: NSColor(red: 202 / 255, green: 211 / 255, blue: 245 / 255, alpha: 1),
        chromeMuted: NSColor(red: 110 / 255, green: 115 / 255, blue: 141 / 255, alpha: 1),
        sidebarBg: NSColor(red: 36 / 255, green: 39 / 255, blue: 58 / 255, alpha: 1),
        accentColor: NSColor(red: 138 / 255, green: 173 / 255, blue: 244 / 255, alpha: 1)
    )

    static let catppuccinMocha = TerminalTheme(
        name: "Catppuccin Mocha",
        foreground: TerminalColor(r: 205, g: 214, b: 244),
        background: TerminalColor(r: 30, g: 30, b: 46),
        cursor: TerminalColor(r: 245, g: 224, b: 220),
        selection: NSColor(red: 88 / 255, green: 91 / 255, blue: 112 / 255, alpha: 0.4),
        ansiColors: [
            TerminalColor(r: 69, g: 71, b: 90),
            TerminalColor(r: 243, g: 139, b: 168),
            TerminalColor(r: 166, g: 227, b: 161),
            TerminalColor(r: 249, g: 226, b: 175),
            TerminalColor(r: 137, g: 180, b: 250),
            TerminalColor(r: 203, g: 166, b: 247),
            TerminalColor(r: 148, g: 226, b: 213),
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
        chromeBg: NSColor(red: 24 / 255, green: 24 / 255, blue: 37 / 255, alpha: 1),
        chromeText: NSColor(red: 205 / 255, green: 214 / 255, blue: 244 / 255, alpha: 1),
        chromeMuted: NSColor(red: 108 / 255, green: 112 / 255, blue: 134 / 255, alpha: 1),
        sidebarBg: NSColor(red: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1),
        accentColor: NSColor(red: 137 / 255, green: 180 / 255, blue: 250 / 255, alpha: 1)
    )

    static let solarizedDark = TerminalTheme(
        name: "Solarized Dark",
        foreground: TerminalColor(r: 131, g: 148, b: 150),
        background: TerminalColor(r: 0, g: 43, b: 54),
        cursor: TerminalColor(r: 131, g: 148, b: 150),
        selection: NSColor(red: 7 / 255, green: 54 / 255, blue: 66 / 255, alpha: 0.8),
        ansiColors: [
            TerminalColor(r: 7, g: 54, b: 66),
            TerminalColor(r: 220, g: 50, b: 47),
            TerminalColor(r: 133, g: 153, b: 0),
            TerminalColor(r: 181, g: 137, b: 0),
            TerminalColor(r: 38, g: 139, b: 210),
            TerminalColor(r: 211, g: 54, b: 130),
            TerminalColor(r: 42, g: 161, b: 152),
            TerminalColor(r: 238, g: 232, b: 213),
            TerminalColor(r: 0, g: 43, b: 54),
            TerminalColor(r: 203, g: 75, b: 22),
            TerminalColor(r: 88, g: 110, b: 117),
            TerminalColor(r: 101, g: 123, b: 131),
            TerminalColor(r: 131, g: 148, b: 150),
            TerminalColor(r: 108, g: 113, b: 196),
            TerminalColor(r: 147, g: 161, b: 161),
            TerminalColor(r: 253, g: 246, b: 227)
        ],
        chromeBg: NSColor(red: 0 / 255, green: 34 / 255, blue: 43 / 255, alpha: 1),
        chromeText: NSColor(red: 131 / 255, green: 148 / 255, blue: 150 / 255, alpha: 1),
        chromeMuted: NSColor(red: 88 / 255, green: 110 / 255, blue: 117 / 255, alpha: 1),
        sidebarBg: NSColor(red: 7 / 255, green: 54 / 255, blue: 66 / 255, alpha: 1),
        accentColor: NSColor(red: 38 / 255, green: 139 / 255, blue: 210 / 255, alpha: 1)
    )

    static let dracula = TerminalTheme(
        name: "Dracula",
        foreground: TerminalColor(r: 248, g: 248, b: 242),
        background: TerminalColor(r: 40, g: 42, b: 54),
        cursor: TerminalColor(r: 248, g: 248, b: 242),
        selection: NSColor(red: 68 / 255, green: 71 / 255, blue: 90 / 255, alpha: 0.6),
        ansiColors: [
            TerminalColor(r: 33, g: 34, b: 44),
            TerminalColor(r: 255, g: 85, b: 85),
            TerminalColor(r: 80, g: 250, b: 123),
            TerminalColor(r: 241, g: 250, b: 140),
            TerminalColor(r: 98, g: 114, b: 164),
            TerminalColor(r: 189, g: 147, b: 249),
            TerminalColor(r: 139, g: 233, b: 253),
            TerminalColor(r: 248, g: 248, b: 242),
            TerminalColor(r: 98, g: 114, b: 164),
            TerminalColor(r: 255, g: 110, b: 110),
            TerminalColor(r: 105, g: 255, b: 148),
            TerminalColor(r: 255, g: 255, b: 165),
            TerminalColor(r: 125, g: 141, b: 191),
            TerminalColor(r: 212, g: 170, b: 255),
            TerminalColor(r: 164, g: 255, b: 255),
            TerminalColor(r: 255, g: 255, b: 255)
        ],
        chromeBg: NSColor(red: 33 / 255, green: 34 / 255, blue: 44 / 255, alpha: 1),
        chromeText: NSColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1),
        chromeMuted: NSColor(red: 98 / 255, green: 114 / 255, blue: 164 / 255, alpha: 1),
        sidebarBg: NSColor(red: 40 / 255, green: 42 / 255, blue: 54 / 255, alpha: 1),
        accentColor: NSColor(red: 189 / 255, green: 147 / 255, blue: 249 / 255, alpha: 1)
    )

    static let nord = TerminalTheme(
        name: "Nord",
        foreground: TerminalColor(r: 216, g: 222, b: 233),
        background: TerminalColor(r: 46, g: 52, b: 64),
        cursor: TerminalColor(r: 216, g: 222, b: 233),
        selection: NSColor(red: 67 / 255, green: 76 / 255, blue: 94 / 255, alpha: 0.6),
        ansiColors: [
            TerminalColor(r: 59, g: 66, b: 82),
            TerminalColor(r: 191, g: 97, b: 106),
            TerminalColor(r: 163, g: 190, b: 140),
            TerminalColor(r: 235, g: 203, b: 139),
            TerminalColor(r: 129, g: 161, b: 193),
            TerminalColor(r: 180, g: 142, b: 173),
            TerminalColor(r: 136, g: 192, b: 208),
            TerminalColor(r: 229, g: 233, b: 240),
            TerminalColor(r: 76, g: 86, b: 106),
            TerminalColor(r: 191, g: 97, b: 106),
            TerminalColor(r: 163, g: 190, b: 140),
            TerminalColor(r: 235, g: 203, b: 139),
            TerminalColor(r: 129, g: 161, b: 193),
            TerminalColor(r: 180, g: 142, b: 173),
            TerminalColor(r: 143, g: 188, b: 187),
            TerminalColor(r: 236, g: 239, b: 244)
        ],
        chromeBg: NSColor(red: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1),
        chromeText: NSColor(red: 216 / 255, green: 222 / 255, blue: 233 / 255, alpha: 1),
        chromeMuted: NSColor(red: 116 / 255, green: 125 / 255, blue: 140 / 255, alpha: 1),
        sidebarBg: NSColor(red: 46 / 255, green: 52 / 255, blue: 64 / 255, alpha: 1),
        accentColor: NSColor(red: 136 / 255, green: 192 / 255, blue: 208 / 255, alpha: 1)
    )

    static let gruvboxDark = TerminalTheme(
        name: "Gruvbox Dark",
        foreground: TerminalColor(r: 235, g: 219, b: 178),
        background: TerminalColor(r: 40, g: 40, b: 40),
        cursor: TerminalColor(r: 235, g: 219, b: 178),
        selection: NSColor(red: 80 / 255, green: 73 / 255, blue: 69 / 255, alpha: 0.6),
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
        chromeBg: NSColor(red: 29 / 255, green: 32 / 255, blue: 33 / 255, alpha: 1),
        chromeText: NSColor(red: 235 / 255, green: 219 / 255, blue: 178 / 255, alpha: 1),
        chromeMuted: NSColor(red: 146 / 255, green: 131 / 255, blue: 116 / 255, alpha: 1),
        sidebarBg: NSColor(red: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1),
        accentColor: NSColor(red: 215 / 255, green: 153 / 255, blue: 33 / 255, alpha: 1)
    )

    static let oneDark = TerminalTheme(
        name: "One Dark",
        foreground: TerminalColor(r: 171, g: 178, b: 191),
        background: TerminalColor(r: 40, g: 44, b: 52),
        cursor: TerminalColor(r: 171, g: 178, b: 191),
        selection: NSColor(red: 62 / 255, green: 68 / 255, blue: 81 / 255, alpha: 0.6),
        ansiColors: [
            TerminalColor(r: 40, g: 44, b: 52),
            TerminalColor(r: 224, g: 108, b: 117),
            TerminalColor(r: 152, g: 195, b: 121),
            TerminalColor(r: 229, g: 192, b: 123),
            TerminalColor(r: 97, g: 175, b: 239),
            TerminalColor(r: 198, g: 120, b: 221),
            TerminalColor(r: 86, g: 182, b: 194),
            TerminalColor(r: 171, g: 178, b: 191),
            TerminalColor(r: 92, g: 99, b: 112),
            TerminalColor(r: 224, g: 108, b: 117),
            TerminalColor(r: 152, g: 195, b: 121),
            TerminalColor(r: 229, g: 192, b: 123),
            TerminalColor(r: 97, g: 175, b: 239),
            TerminalColor(r: 198, g: 120, b: 221),
            TerminalColor(r: 86, g: 182, b: 194),
            TerminalColor(r: 200, g: 204, b: 212)
        ],
        chromeBg: NSColor(red: 33 / 255, green: 37 / 255, blue: 43 / 255, alpha: 1),
        chromeText: NSColor(red: 171 / 255, green: 178 / 255, blue: 191 / 255, alpha: 1),
        chromeMuted: NSColor(red: 92 / 255, green: 99 / 255, blue: 112 / 255, alpha: 1),
        sidebarBg: NSColor(red: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1),
        accentColor: NSColor(red: 97 / 255, green: 175 / 255, blue: 239 / 255, alpha: 1)
    )

    static let solarizedLight = TerminalTheme(
        name: "Solarized Light",
        foreground: TerminalColor(r: 101, g: 123, b: 131),
        background: TerminalColor(r: 253, g: 246, b: 227),
        cursor: TerminalColor(r: 101, g: 123, b: 131),
        selection: NSColor(red: 238 / 255, green: 232 / 255, blue: 213 / 255, alpha: 0.8),
        ansiColors: [
            TerminalColor(r: 238, g: 232, b: 213),
            TerminalColor(r: 220, g: 50, b: 47),
            TerminalColor(r: 133, g: 153, b: 0),
            TerminalColor(r: 181, g: 137, b: 0),
            TerminalColor(r: 38, g: 139, b: 210),
            TerminalColor(r: 211, g: 54, b: 130),
            TerminalColor(r: 42, g: 161, b: 152),
            TerminalColor(r: 7, g: 54, b: 66),
            TerminalColor(r: 147, g: 161, b: 161),
            TerminalColor(r: 203, g: 75, b: 22),
            TerminalColor(r: 88, g: 110, b: 117),
            TerminalColor(r: 101, g: 123, b: 131),
            TerminalColor(r: 131, g: 148, b: 150),
            TerminalColor(r: 108, g: 113, b: 196),
            TerminalColor(r: 147, g: 161, b: 161),
            TerminalColor(r: 0, g: 43, b: 54)
        ],
        chromeBg: NSColor(red: 238 / 255, green: 232 / 255, blue: 213 / 255, alpha: 1),
        chromeText: NSColor(red: 101 / 255, green: 123 / 255, blue: 131 / 255, alpha: 1),
        chromeMuted: NSColor(red: 147 / 255, green: 161 / 255, blue: 161 / 255, alpha: 1),
        sidebarBg: NSColor(red: 253 / 255, green: 246 / 255, blue: 227 / 255, alpha: 1),
        accentColor: NSColor(red: 38 / 255, green: 139 / 255, blue: 210 / 255, alpha: 1)
    )

    static let rosePine = TerminalTheme(
        name: "Rosé Pine",
        foreground: TerminalColor(r: 224, g: 222, b: 244),
        background: TerminalColor(r: 25, g: 23, b: 36),
        cursor: TerminalColor(r: 224, g: 222, b: 244),
        selection: NSColor(red: 38 / 255, green: 35 / 255, blue: 53 / 255, alpha: 0.8),
        ansiColors: [
            TerminalColor(r: 38, g: 35, b: 53),
            TerminalColor(r: 235, g: 111, b: 146),
            TerminalColor(r: 49, g: 116, b: 143),
            TerminalColor(r: 246, g: 193, b: 119),
            TerminalColor(r: 156, g: 207, b: 216),
            TerminalColor(r: 196, g: 167, b: 231),
            TerminalColor(r: 234, g: 154, b: 151),
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
        chromeBg: NSColor(red: 21 / 255, green: 19 / 255, blue: 30 / 255, alpha: 1),
        chromeText: NSColor(red: 224 / 255, green: 222 / 255, blue: 244 / 255, alpha: 1),
        chromeMuted: NSColor(red: 110 / 255, green: 106 / 255, blue: 134 / 255, alpha: 1),
        sidebarBg: NSColor(red: 25 / 255, green: 23 / 255, blue: 36 / 255, alpha: 1),
        accentColor: NSColor(red: 196 / 255, green: 167 / 255, blue: 231 / 255, alpha: 1)
    )

    static let kanagawa = TerminalTheme(
        name: "Kanagawa",
        foreground: TerminalColor(r: 220, g: 215, b: 186),
        background: TerminalColor(r: 31, g: 31, b: 40),
        cursor: TerminalColor(r: 220, g: 215, b: 186),
        selection: NSColor(red: 43 / 255, green: 43 / 255, blue: 58 / 255, alpha: 0.8),
        ansiColors: [
            TerminalColor(r: 22, g: 22, b: 29),
            TerminalColor(r: 195, g: 64, b: 67),
            TerminalColor(r: 118, g: 148, b: 106),
            TerminalColor(r: 192, g: 163, b: 110),
            TerminalColor(r: 126, g: 156, b: 216),
            TerminalColor(r: 149, g: 127, b: 184),
            TerminalColor(r: 106, g: 149, b: 137),
            TerminalColor(r: 220, g: 215, b: 186),
            TerminalColor(r: 84, g: 84, b: 109),
            TerminalColor(r: 255, g: 90, b: 100),
            TerminalColor(r: 152, g: 187, b: 108),
            TerminalColor(r: 226, g: 194, b: 125),
            TerminalColor(r: 126, g: 156, b: 216),
            TerminalColor(r: 149, g: 127, b: 184),
            TerminalColor(r: 115, g: 171, b: 150),
            TerminalColor(r: 220, g: 215, b: 186)
        ],
        chromeBg: NSColor(red: 22 / 255, green: 22 / 255, blue: 29 / 255, alpha: 1),
        chromeText: NSColor(red: 220 / 255, green: 215 / 255, blue: 186 / 255, alpha: 1),
        chromeMuted: NSColor(red: 84 / 255, green: 84 / 255, blue: 109 / 255, alpha: 1),
        sidebarBg: NSColor(red: 31 / 255, green: 31 / 255, blue: 40 / 255, alpha: 1),
        accentColor: NSColor(red: 126 / 255, green: 156 / 255, blue: 216 / 255, alpha: 1)
    )

    static let gruvboxLight = TerminalTheme(
        name: "Gruvbox Light",
        foreground: TerminalColor(r: 60, g: 56, b: 54),
        background: TerminalColor(r: 251, g: 241, b: 199),
        cursor: TerminalColor(r: 60, g: 56, b: 54),
        selection: NSColor(red: 213 / 255, green: 196 / 255, blue: 161 / 255, alpha: 0.5),
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
        chromeBg: NSColor(red: 242 / 255, green: 229 / 255, blue: 188 / 255, alpha: 1),
        chromeText: NSColor(red: 60 / 255, green: 56 / 255, blue: 54 / 255, alpha: 1),
        chromeMuted: NSColor(red: 146 / 255, green: 131 / 255, blue: 116 / 255, alpha: 1),
        sidebarBg: NSColor(red: 245 / 255, green: 235 / 255, blue: 193 / 255, alpha: 1),
        accentColor: NSColor(red: 215 / 255, green: 153 / 255, blue: 33 / 255, alpha: 1)
    )

    static let oneLight = TerminalTheme(
        name: "One Light",
        foreground: TerminalColor(r: 56, g: 58, b: 66),
        background: TerminalColor(r: 250, g: 250, b: 250),
        cursor: TerminalColor(r: 82, g: 139, b: 255),
        selection: NSColor(red: 56 / 255, green: 58 / 255, blue: 66 / 255, alpha: 0.1),
        ansiColors: [
            TerminalColor(r: 56, g: 58, b: 66),  // 0 black
            TerminalColor(r: 228, g: 86, b: 73),  // 1 red
            TerminalColor(r: 80, g: 161, b: 79),  // 2 green
            TerminalColor(r: 193, g: 132, b: 1),  // 3 yellow
            TerminalColor(r: 64, g: 120, b: 242),  // 4 blue
            TerminalColor(r: 166, g: 38, b: 164),  // 5 magenta
            TerminalColor(r: 1, g: 132, b: 188),  // 6 cyan
            TerminalColor(r: 56, g: 58, b: 66),  // 7 white
            TerminalColor(r: 160, g: 161, b: 167),  // 8 bright black
            TerminalColor(r: 228, g: 86, b: 73),  // 9 bright red
            TerminalColor(r: 80, g: 161, b: 79),  // 10 bright green
            TerminalColor(r: 193, g: 132, b: 1),  // 11 bright yellow
            TerminalColor(r: 64, g: 120, b: 242),  // 12 bright blue
            TerminalColor(r: 166, g: 38, b: 164),  // 13 bright magenta
            TerminalColor(r: 1, g: 132, b: 188),  // 14 bright cyan
            TerminalColor(r: 56, g: 58, b: 66)  // 15 bright white
        ],
        chromeBg: NSColor(red: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 1),
        chromeText: NSColor(red: 56 / 255, green: 58 / 255, blue: 66 / 255, alpha: 1),
        chromeMuted: NSColor(red: 160 / 255, green: 161 / 255, blue: 167 / 255, alpha: 1),
        sidebarBg: NSColor(red: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1),
        accentColor: NSColor(red: 64 / 255, green: 120 / 255, blue: 242 / 255, alpha: 1)
    )

    static let everforestDark = TerminalTheme(
        name: "Everforest Dark",
        foreground: TerminalColor(r: 211, g: 198, b: 170),
        background: TerminalColor(r: 39, g: 46, b: 34),
        cursor: TerminalColor(r: 211, g: 198, b: 170),
        selection: NSColor(red: 80 / 255, green: 96 / 255, blue: 64 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 72, g: 84, b: 60),  // 0 black
            TerminalColor(r: 230, g: 126, b: 128),  // 1 red
            TerminalColor(r: 167, g: 192, b: 128),  // 2 green
            TerminalColor(r: 219, g: 188, b: 127),  // 3 yellow
            TerminalColor(r: 127, g: 187, b: 179),  // 4 blue
            TerminalColor(r: 214, g: 153, b: 182),  // 5 magenta
            TerminalColor(r: 131, g: 192, b: 146),  // 6 cyan
            TerminalColor(r: 211, g: 198, b: 170),  // 7 white
            TerminalColor(r: 113, g: 128, b: 97),  // 8 bright black
            TerminalColor(r: 230, g: 126, b: 128),  // 9 bright red
            TerminalColor(r: 167, g: 192, b: 128),  // 10 bright green
            TerminalColor(r: 219, g: 188, b: 127),  // 11 bright yellow
            TerminalColor(r: 127, g: 187, b: 179),  // 12 bright blue
            TerminalColor(r: 214, g: 153, b: 182),  // 13 bright magenta
            TerminalColor(r: 131, g: 192, b: 146),  // 14 bright cyan
            TerminalColor(r: 211, g: 198, b: 170)  // 15 bright white
        ],
        chromeBg: NSColor(red: 31 / 255, green: 37 / 255, blue: 28 / 255, alpha: 1),
        chromeText: NSColor(red: 211 / 255, green: 198 / 255, blue: 170 / 255, alpha: 1),
        chromeMuted: NSColor(red: 113 / 255, green: 128 / 255, blue: 97 / 255, alpha: 1),
        sidebarBg: NSColor(red: 39 / 255, green: 46 / 255, blue: 34 / 255, alpha: 1),
        accentColor: NSColor(red: 167 / 255, green: 192 / 255, blue: 128 / 255, alpha: 1)
    )

    static let everforestLight = TerminalTheme(
        name: "Everforest Light",
        foreground: TerminalColor(r: 92, g: 103, b: 76),
        background: TerminalColor(r: 253, g: 246, b: 227),
        cursor: TerminalColor(r: 92, g: 103, b: 76),
        selection: NSColor(red: 167 / 255, green: 192 / 255, blue: 128 / 255, alpha: 0.2),
        ansiColors: [
            TerminalColor(r: 92, g: 103, b: 76),  // 0 black
            TerminalColor(r: 247, g: 83, b: 65),  // 1 red
            TerminalColor(r: 143, g: 185, b: 69),  // 2 green
            TerminalColor(r: 223, g: 163, b: 55),  // 3 yellow
            TerminalColor(r: 57, g: 150, b: 159),  // 4 blue
            TerminalColor(r: 223, g: 105, b: 149),  // 5 magenta
            TerminalColor(r: 53, g: 168, b: 120),  // 6 cyan
            TerminalColor(r: 92, g: 103, b: 76),  // 7 white
            TerminalColor(r: 147, g: 160, b: 129),  // 8 bright black
            TerminalColor(r: 247, g: 83, b: 65),  // 9 bright red
            TerminalColor(r: 143, g: 185, b: 69),  // 10 bright green
            TerminalColor(r: 223, g: 163, b: 55),  // 11 bright yellow
            TerminalColor(r: 57, g: 150, b: 159),  // 12 bright blue
            TerminalColor(r: 223, g: 105, b: 149),  // 13 bright magenta
            TerminalColor(r: 53, g: 168, b: 120),  // 14 bright cyan
            TerminalColor(r: 92, g: 103, b: 76)  // 15 bright white
        ],
        chromeBg: NSColor(red: 239 / 255, green: 231 / 255, blue: 213 / 255, alpha: 1),
        chromeText: NSColor(red: 92 / 255, green: 103 / 255, blue: 76 / 255, alpha: 1),
        chromeMuted: NSColor(red: 147 / 255, green: 160 / 255, blue: 129 / 255, alpha: 1),
        sidebarBg: NSColor(red: 246 / 255, green: 238 / 255, blue: 220 / 255, alpha: 1),
        accentColor: NSColor(red: 143 / 255, green: 185 / 255, blue: 69 / 255, alpha: 1)
    )

    static let githubDark = TerminalTheme(
        name: "GitHub Dark",
        foreground: TerminalColor(r: 201, g: 209, b: 217),
        background: TerminalColor(r: 13, g: 17, b: 23),
        cursor: TerminalColor(r: 201, g: 209, b: 217),
        selection: NSColor(red: 56 / 255, green: 139 / 255, blue: 253 / 255, alpha: 0.3),
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
            TerminalColor(r: 255, g: 123, b: 114),  // 9 bright red
            TerminalColor(r: 63, g: 185, b: 80),  // 10 bright green
            TerminalColor(r: 210, g: 153, b: 34),  // 11 bright yellow
            TerminalColor(r: 88, g: 166, b: 255),  // 12 bright blue
            TerminalColor(r: 188, g: 140, b: 255),  // 13 bright magenta
            TerminalColor(r: 57, g: 211, b: 220),  // 14 bright cyan
            TerminalColor(r: 201, g: 209, b: 217)  // 15 bright white
        ],
        chromeBg: NSColor(red: 1 / 255, green: 4 / 255, blue: 9 / 255, alpha: 1),
        chromeText: NSColor(red: 201 / 255, green: 209 / 255, blue: 217 / 255, alpha: 1),
        chromeMuted: NSColor(red: 110 / 255, green: 118 / 255, blue: 129 / 255, alpha: 1),
        sidebarBg: NSColor(red: 13 / 255, green: 17 / 255, blue: 23 / 255, alpha: 1),
        accentColor: NSColor(red: 88 / 255, green: 166 / 255, blue: 255 / 255, alpha: 1)
    )

    static let githubLight = TerminalTheme(
        name: "GitHub Light",
        foreground: TerminalColor(r: 31, g: 35, b: 40),
        background: TerminalColor(r: 255, g: 255, b: 255),
        cursor: TerminalColor(r: 31, g: 35, b: 40),
        selection: NSColor(red: 56 / 255, green: 139 / 255, blue: 253 / 255, alpha: 0.2),
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
            TerminalColor(r: 26, g: 127, b: 55),  // 10 bright green
            TerminalColor(r: 155, g: 103, b: 0),  // 11 bright yellow
            TerminalColor(r: 2, g: 82, b: 204),  // 12 bright blue
            TerminalColor(r: 130, g: 80, b: 223),  // 13 bright magenta
            TerminalColor(r: 5, g: 107, b: 121),  // 14 bright cyan
            TerminalColor(r: 31, g: 35, b: 40)  // 15 bright white
        ],
        chromeBg: NSColor(red: 246 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1),
        chromeText: NSColor(red: 31 / 255, green: 35 / 255, blue: 40 / 255, alpha: 1),
        chromeMuted: NSColor(red: 110 / 255, green: 119 / 255, blue: 129 / 255, alpha: 1),
        sidebarBg: NSColor(red: 255 / 255, green: 255 / 255, blue: 255 / 255, alpha: 1),
        accentColor: NSColor(red: 2 / 255, green: 82 / 255, blue: 204 / 255, alpha: 1)
    )

    static let ayuDark = TerminalTheme(
        name: "Ayu Dark",
        foreground: TerminalColor(r: 179, g: 177, b: 168),
        background: TerminalColor(r: 10, g: 14, b: 20),
        cursor: TerminalColor(r: 232, g: 177, b: 82),
        selection: NSColor(red: 39 / 255, green: 82 / 255, blue: 120 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 1, g: 10, b: 16),  // 0 black
            TerminalColor(r: 242, g: 104, b: 82),  // 1 red
            TerminalColor(r: 170, g: 212, b: 108),  // 2 green
            TerminalColor(r: 232, g: 177, b: 82),  // 3 yellow
            TerminalColor(r: 57, g: 186, b: 230),  // 4 blue
            TerminalColor(r: 217, g: 151, b: 225),  // 5 magenta
            TerminalColor(r: 149, g: 230, b: 203),  // 6 cyan
            TerminalColor(r: 179, g: 177, b: 168),  // 7 white
            TerminalColor(r: 71, g: 75, b: 82),  // 8 bright black
            TerminalColor(r: 242, g: 104, b: 82),  // 9 bright red
            TerminalColor(r: 170, g: 212, b: 108),  // 10 bright green
            TerminalColor(r: 232, g: 177, b: 82),  // 11 bright yellow
            TerminalColor(r: 57, g: 186, b: 230),  // 12 bright blue
            TerminalColor(r: 217, g: 151, b: 225),  // 13 bright magenta
            TerminalColor(r: 149, g: 230, b: 203),  // 14 bright cyan
            TerminalColor(r: 179, g: 177, b: 168)  // 15 bright white
        ],
        chromeBg: NSColor(red: 1 / 255, green: 10 / 255, blue: 16 / 255, alpha: 1),
        chromeText: NSColor(red: 179 / 255, green: 177 / 255, blue: 168 / 255, alpha: 1),
        chromeMuted: NSColor(red: 71 / 255, green: 75 / 255, blue: 82 / 255, alpha: 1),
        sidebarBg: NSColor(red: 10 / 255, green: 14 / 255, blue: 20 / 255, alpha: 1),
        accentColor: NSColor(red: 232 / 255, green: 177 / 255, blue: 82 / 255, alpha: 1)
    )

    static let ayuLight = TerminalTheme(
        name: "Ayu Light",
        foreground: TerminalColor(r: 95, g: 102, b: 117),
        background: TerminalColor(r: 252, g: 252, b: 252),
        cursor: TerminalColor(r: 255, g: 106, b: 0),
        selection: NSColor(red: 3 / 255, green: 130 / 255, blue: 240 / 255, alpha: 0.15),
        ansiColors: [
            TerminalColor(r: 95, g: 102, b: 117),  // 0 black
            TerminalColor(r: 240, g: 113, b: 120),  // 1 red
            TerminalColor(r: 134, g: 179, b: 69),  // 2 green
            TerminalColor(r: 255, g: 106, b: 0),  // 3 yellow
            TerminalColor(r: 54, g: 163, b: 217),  // 4 blue
            TerminalColor(r: 163, g: 122, b: 204),  // 5 magenta
            TerminalColor(r: 78, g: 191, b: 153),  // 6 cyan
            TerminalColor(r: 95, g: 102, b: 117),  // 7 white
            TerminalColor(r: 171, g: 178, b: 191),  // 8 bright black
            TerminalColor(r: 240, g: 113, b: 120),  // 9 bright red
            TerminalColor(r: 134, g: 179, b: 69),  // 10 bright green
            TerminalColor(r: 255, g: 106, b: 0),  // 11 bright yellow
            TerminalColor(r: 54, g: 163, b: 217),  // 12 bright blue
            TerminalColor(r: 163, g: 122, b: 204),  // 13 bright magenta
            TerminalColor(r: 78, g: 191, b: 153),  // 14 bright cyan
            TerminalColor(r: 95, g: 102, b: 117)  // 15 bright white
        ],
        chromeBg: NSColor(red: 242 / 255, green: 242 / 255, blue: 242 / 255, alpha: 1),
        chromeText: NSColor(red: 95 / 255, green: 102 / 255, blue: 117 / 255, alpha: 1),
        chromeMuted: NSColor(red: 171 / 255, green: 178 / 255, blue: 191 / 255, alpha: 1),
        sidebarBg: NSColor(red: 248 / 255, green: 248 / 255, blue: 248 / 255, alpha: 1),
        accentColor: NSColor(red: 255 / 255, green: 106 / 255, blue: 0 / 255, alpha: 1)
    )

    // MARK: Default Light

    static let defaultLight = TerminalTheme(
        name: "Default Light",
        foreground: TerminalColor(r: 40, g: 40, b: 45),
        background: TerminalColor(r: 255, g: 255, b: 255),
        cursor: TerminalColor(r: 40, g: 40, b: 45),
        selection: NSColor(red: 60 / 255, green: 130 / 255, blue: 220 / 255, alpha: 0.2),
        ansiColors: [
            TerminalColor(r: 58, g: 58, b: 66),   // 0 black
            TerminalColor(r: 200, g: 40, b: 41),   // 1 red
            TerminalColor(r: 50, g: 155, b: 50),   // 2 green
            TerminalColor(r: 180, g: 110, b: 0),   // 3 yellow
            TerminalColor(r: 0, g: 100, b: 200),   // 4 blue
            TerminalColor(r: 150, g: 50, b: 200),  // 5 magenta
            TerminalColor(r: 0, g: 140, b: 155),   // 6 cyan
            TerminalColor(r: 120, g: 120, b: 130), // 7 white
            TerminalColor(r: 100, g: 100, b: 110), // 8 bright black
            TerminalColor(r: 220, g: 60, b: 60),   // 9 bright red
            TerminalColor(r: 60, g: 175, b: 60),   // 10 bright green
            TerminalColor(r: 200, g: 130, b: 0),   // 11 bright yellow
            TerminalColor(r: 20, g: 120, b: 220),  // 12 bright blue
            TerminalColor(r: 170, g: 70, b: 220),  // 13 bright magenta
            TerminalColor(r: 0, g: 160, b: 175),   // 14 bright cyan
            TerminalColor(r: 40, g: 40, b: 45)     // 15 bright white
        ],
        chromeBg: NSColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1),
        chromeText: NSColor(red: 40 / 255, green: 40 / 255, blue: 45 / 255, alpha: 1),
        chromeMuted: NSColor(red: 130 / 255, green: 130 / 255, blue: 140 / 255, alpha: 1),
        sidebarBg: NSColor(red: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1),
        accentColor: NSColor(red: 0 / 255, green: 100 / 255, blue: 200 / 255, alpha: 1)
    )

    // MARK: Monokai

    static let monokai = TerminalTheme(
        name: "Monokai",
        foreground: TerminalColor(r: 248, g: 248, b: 242),
        background: TerminalColor(r: 39, g: 40, b: 34),
        cursor: TerminalColor(r: 248, g: 248, b: 240),
        selection: NSColor(red: 73 / 255, green: 72 / 255, blue: 62 / 255, alpha: 0.6),
        ansiColors: [
            TerminalColor(r: 39, g: 40, b: 34),    // 0 black
            TerminalColor(r: 249, g: 38, b: 114),  // 1 red
            TerminalColor(r: 166, g: 226, b: 46),  // 2 green
            TerminalColor(r: 244, g: 191, b: 117), // 3 yellow
            TerminalColor(r: 102, g: 217, b: 239), // 4 blue
            TerminalColor(r: 174, g: 129, b: 255), // 5 magenta
            TerminalColor(r: 161, g: 239, b: 228), // 6 cyan
            TerminalColor(r: 248, g: 248, b: 242), // 7 white
            TerminalColor(r: 117, g: 113, b: 94),  // 8 bright black
            TerminalColor(r: 249, g: 38, b: 114),  // 9 bright red
            TerminalColor(r: 166, g: 226, b: 46),  // 10 bright green
            TerminalColor(r: 244, g: 191, b: 117), // 11 bright yellow
            TerminalColor(r: 102, g: 217, b: 239), // 12 bright blue
            TerminalColor(r: 174, g: 129, b: 255), // 13 bright magenta
            TerminalColor(r: 161, g: 239, b: 228), // 14 bright cyan
            TerminalColor(r: 249, g: 248, b: 245)  // 15 bright white
        ],
        chromeBg: NSColor(red: 30 / 255, green: 31 / 255, blue: 26 / 255, alpha: 1),
        chromeText: NSColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1),
        chromeMuted: NSColor(red: 117 / 255, green: 113 / 255, blue: 94 / 255, alpha: 1),
        sidebarBg: NSColor(red: 45 / 255, green: 46 / 255, blue: 40 / 255, alpha: 1),
        accentColor: NSColor(red: 166 / 255, green: 226 / 255, blue: 46 / 255, alpha: 1)
    )

    // MARK: Material Dark

    static let materialDark = TerminalTheme(
        name: "Material Dark",
        foreground: TerminalColor(r: 238, g: 238, b: 238),
        background: TerminalColor(r: 38, g: 50, b: 56),
        cursor: TerminalColor(r: 238, g: 238, b: 238),
        selection: NSColor(red: 80 / 255, green: 130 / 255, blue: 160 / 255, alpha: 0.4),
        ansiColors: [
            TerminalColor(r: 38, g: 50, b: 56),    // 0 black
            TerminalColor(r: 239, g: 83, b: 80),   // 1 red
            TerminalColor(r: 102, g: 187, b: 106), // 2 green
            TerminalColor(r: 249, g: 168, b: 37),  // 3 yellow
            TerminalColor(r: 66, g: 165, b: 245),  // 4 blue
            TerminalColor(r: 171, g: 71, b: 188),  // 5 magenta
            TerminalColor(r: 38, g: 198, b: 218),  // 6 cyan
            TerminalColor(r: 238, g: 238, b: 238), // 7 white
            TerminalColor(r: 84, g: 110, b: 122),  // 8 bright black
            TerminalColor(r: 255, g: 138, b: 128), // 9 bright red
            TerminalColor(r: 165, g: 214, b: 167), // 10 bright green
            TerminalColor(r: 255, g: 224, b: 130), // 11 bright yellow
            TerminalColor(r: 144, g: 202, b: 249), // 12 bright blue
            TerminalColor(r: 206, g: 147, b: 216), // 13 bright magenta
            TerminalColor(r: 128, g: 222, b: 234), // 14 bright cyan
            TerminalColor(r: 255, g: 255, b: 255)  // 15 bright white
        ],
        chromeBg: NSColor(red: 28 / 255, green: 39 / 255, blue: 45 / 255, alpha: 1),
        chromeText: NSColor(red: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1),
        chromeMuted: NSColor(red: 84 / 255, green: 110 / 255, blue: 122 / 255, alpha: 1),
        sidebarBg: NSColor(red: 44 / 255, green: 58 / 255, blue: 65 / 255, alpha: 1),
        accentColor: NSColor(red: 66 / 255, green: 165 / 255, blue: 245 / 255, alpha: 1)
    )

    // MARK: Material Light

    static let materialLight = TerminalTheme(
        name: "Material Light",
        foreground: TerminalColor(r: 84, g: 110, b: 122),
        background: TerminalColor(r: 250, g: 250, b: 250),
        cursor: TerminalColor(r: 84, g: 110, b: 122),
        selection: NSColor(red: 66 / 255, green: 165 / 255, blue: 245 / 255, alpha: 0.2),
        ansiColors: [
            TerminalColor(r: 84, g: 110, b: 122),  // 0 black
            TerminalColor(r: 229, g: 57, b: 53),   // 1 red
            TerminalColor(r: 67, g: 160, b: 71),   // 2 green
            TerminalColor(r: 251, g: 140, b: 0),   // 3 yellow
            TerminalColor(r: 30, g: 136, b: 229),  // 4 blue
            TerminalColor(r: 142, g: 36, b: 170),  // 5 magenta
            TerminalColor(r: 0, g: 172, b: 193),   // 6 cyan
            TerminalColor(r: 144, g: 164, b: 174), // 7 white
            TerminalColor(r: 120, g: 144, b: 156), // 8 bright black
            TerminalColor(r: 239, g: 83, b: 80),   // 9 bright red
            TerminalColor(r: 102, g: 187, b: 106), // 10 bright green
            TerminalColor(r: 255, g: 167, b: 38),  // 11 bright yellow
            TerminalColor(r: 66, g: 165, b: 245),  // 12 bright blue
            TerminalColor(r: 171, g: 71, b: 188),  // 13 bright magenta
            TerminalColor(r: 38, g: 198, b: 218),  // 14 bright cyan
            TerminalColor(r: 84, g: 110, b: 122)   // 15 bright white
        ],
        chromeBg: NSColor(red: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 1),
        chromeText: NSColor(red: 84 / 255, green: 110 / 255, blue: 122 / 255, alpha: 1),
        chromeMuted: NSColor(red: 144 / 255, green: 164 / 255, blue: 174 / 255, alpha: 1),
        sidebarBg: NSColor(red: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1),
        accentColor: NSColor(red: 30 / 255, green: 136 / 255, blue: 229 / 255, alpha: 1)
    )

    // MARK: Palenight

    static let palenight = TerminalTheme(
        name: "Palenight",
        foreground: TerminalColor(r: 166, g: 172, b: 205),
        background: TerminalColor(r: 41, g: 45, b: 62),
        cursor: TerminalColor(r: 255, g: 203, b: 107),
        selection: NSColor(red: 84 / 255, green: 90 / 255, blue: 120 / 255, alpha: 0.4),
        ansiColors: [
            TerminalColor(r: 41, g: 45, b: 62),    // 0 black
            TerminalColor(r: 240, g: 113, b: 120), // 1 red
            TerminalColor(r: 195, g: 232, b: 141), // 2 green
            TerminalColor(r: 255, g: 203, b: 107), // 3 yellow
            TerminalColor(r: 130, g: 170, b: 255), // 4 blue
            TerminalColor(r: 199, g: 146, b: 234), // 5 magenta
            TerminalColor(r: 137, g: 221, b: 255), // 6 cyan
            TerminalColor(r: 166, g: 172, b: 205), // 7 white
            TerminalColor(r: 84, g: 90, b: 120),   // 8 bright black
            TerminalColor(r: 255, g: 85, b: 114),  // 9 bright red
            TerminalColor(r: 195, g: 232, b: 141), // 10 bright green
            TerminalColor(r: 255, g: 203, b: 107), // 11 bright yellow
            TerminalColor(r: 130, g: 170, b: 255), // 12 bright blue
            TerminalColor(r: 199, g: 146, b: 234), // 13 bright magenta
            TerminalColor(r: 137, g: 221, b: 255), // 14 bright cyan
            TerminalColor(r: 215, g: 218, b: 234)  // 15 bright white
        ],
        chromeBg: NSColor(red: 33 / 255, green: 37 / 255, blue: 52 / 255, alpha: 1),
        chromeText: NSColor(red: 166 / 255, green: 172 / 255, blue: 205 / 255, alpha: 1),
        chromeMuted: NSColor(red: 84 / 255, green: 90 / 255, blue: 120 / 255, alpha: 1),
        sidebarBg: NSColor(red: 48 / 255, green: 53 / 255, blue: 72 / 255, alpha: 1),
        accentColor: NSColor(red: 130 / 255, green: 170 / 255, blue: 255 / 255, alpha: 1)
    )

    // MARK: Horizon Dark

    static let horizonDark = TerminalTheme(
        name: "Horizon Dark",
        foreground: TerminalColor(r: 228, g: 212, b: 213),
        background: TerminalColor(r: 28, g: 23, b: 30),
        cursor: TerminalColor(r: 232, g: 173, b: 85),
        selection: NSColor(red: 79 / 255, green: 51 / 255, blue: 64 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 9, g: 8, b: 16),      // 0 black
            TerminalColor(r: 232, g: 106, b: 120), // 1 red
            TerminalColor(r: 41, g: 205, b: 145),  // 2 green
            TerminalColor(r: 232, g: 173, b: 85),  // 3 yellow
            TerminalColor(r: 38, g: 162, b: 255),  // 4 blue
            TerminalColor(r: 178, g: 117, b: 255), // 5 magenta
            TerminalColor(r: 9, g: 189, b: 185),   // 6 cyan
            TerminalColor(r: 228, g: 212, b: 213), // 7 white
            TerminalColor(r: 79, g: 51, b: 64),    // 8 bright black
            TerminalColor(r: 246, g: 121, b: 121), // 9 bright red
            TerminalColor(r: 111, g: 232, b: 185), // 10 bright green
            TerminalColor(r: 255, g: 202, b: 122), // 11 bright yellow
            TerminalColor(r: 38, g: 162, b: 255),  // 12 bright blue
            TerminalColor(r: 209, g: 154, b: 255), // 13 bright magenta
            TerminalColor(r: 9, g: 215, b: 210),   // 14 bright cyan
            TerminalColor(r: 242, g: 233, b: 234)  // 15 bright white
        ],
        chromeBg: NSColor(red: 20 / 255, green: 16 / 255, blue: 22 / 255, alpha: 1),
        chromeText: NSColor(red: 228 / 255, green: 212 / 255, blue: 213 / 255, alpha: 1),
        chromeMuted: NSColor(red: 79 / 255, green: 51 / 255, blue: 64 / 255, alpha: 1),
        sidebarBg: NSColor(red: 35 / 255, green: 29 / 255, blue: 37 / 255, alpha: 1),
        accentColor: NSColor(red: 232 / 255, green: 173 / 255, blue: 85 / 255, alpha: 1)
    )

    // MARK: Cobalt2

    static let cobalt2 = TerminalTheme(
        name: "Cobalt2",
        foreground: TerminalColor(r: 255, g: 255, b: 255),
        background: TerminalColor(r: 19, g: 44, b: 68),
        cursor: TerminalColor(r: 255, g: 191, b: 0),
        selection: NSColor(red: 0 / 255, green: 100 / 255, blue: 163 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 19, g: 44, b: 68),    // 0 black
            TerminalColor(r: 255, g: 0, b: 109),   // 1 red
            TerminalColor(r: 135, g: 232, b: 90),  // 2 green
            TerminalColor(r: 255, g: 191, b: 0),   // 3 yellow
            TerminalColor(r: 0, g: 149, b: 255),   // 4 blue
            TerminalColor(r: 207, g: 106, b: 255), // 5 magenta
            TerminalColor(r: 0, g: 220, b: 220),   // 6 cyan
            TerminalColor(r: 255, g: 255, b: 255), // 7 white
            TerminalColor(r: 0, g: 84, b: 141),    // 8 bright black
            TerminalColor(r: 255, g: 85, b: 139),  // 9 bright red
            TerminalColor(r: 175, g: 255, b: 115), // 10 bright green
            TerminalColor(r: 255, g: 210, b: 70),  // 11 bright yellow
            TerminalColor(r: 71, g: 175, b: 255),  // 12 bright blue
            TerminalColor(r: 225, g: 140, b: 255), // 13 bright magenta
            TerminalColor(r: 0, g: 240, b: 240),   // 14 bright cyan
            TerminalColor(r: 255, g: 255, b: 255)  // 15 bright white
        ],
        chromeBg: NSColor(red: 13 / 255, green: 33 / 255, blue: 52 / 255, alpha: 1),
        chromeText: NSColor(red: 255 / 255, green: 255 / 255, blue: 255 / 255, alpha: 1),
        chromeMuted: NSColor(red: 0 / 255, green: 84 / 255, blue: 141 / 255, alpha: 1),
        sidebarBg: NSColor(red: 24 / 255, green: 53 / 255, blue: 80 / 255, alpha: 1),
        accentColor: NSColor(red: 255 / 255, green: 191 / 255, blue: 0 / 255, alpha: 1)
    )

    // MARK: Night Owl

    static let nightOwl = TerminalTheme(
        name: "Night Owl",
        foreground: TerminalColor(r: 214, g: 222, b: 235),
        background: TerminalColor(r: 1, g: 22, b: 39),
        cursor: TerminalColor(r: 128, g: 203, b: 196),
        selection: NSColor(red: 1 / 255, green: 82 / 255, blue: 131 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 1, g: 22, b: 39),     // 0 black
            TerminalColor(r: 255, g: 88, b: 116),  // 1 red
            TerminalColor(r: 173, g: 219, b: 103), // 2 green
            TerminalColor(r: 255, g: 203, b: 107), // 3 yellow
            TerminalColor(r: 130, g: 170, b: 255), // 4 blue
            TerminalColor(r: 199, g: 146, b: 234), // 5 magenta
            TerminalColor(r: 128, g: 203, b: 196), // 6 cyan
            TerminalColor(r: 214, g: 222, b: 235), // 7 white
            TerminalColor(r: 1, g: 56, b: 97),     // 8 bright black
            TerminalColor(r: 255, g: 88, b: 116),  // 9 bright red
            TerminalColor(r: 195, g: 232, b: 141), // 10 bright green
            TerminalColor(r: 255, g: 239, b: 153), // 11 bright yellow
            TerminalColor(r: 130, g: 170, b: 255), // 12 bright blue
            TerminalColor(r: 215, g: 174, b: 255), // 13 bright magenta
            TerminalColor(r: 149, g: 230, b: 203), // 14 bright cyan
            TerminalColor(r: 214, g: 222, b: 235)  // 15 bright white
        ],
        chromeBg: NSColor(red: 1 / 255, green: 15 / 255, blue: 28 / 255, alpha: 1),
        chromeText: NSColor(red: 214 / 255, green: 222 / 255, blue: 235 / 255, alpha: 1),
        chromeMuted: NSColor(red: 1 / 255, green: 56 / 255, blue: 97 / 255, alpha: 1),
        sidebarBg: NSColor(red: 1 / 255, green: 28 / 255, blue: 48 / 255, alpha: 1),
        accentColor: NSColor(red: 128 / 255, green: 203 / 255, blue: 196 / 255, alpha: 1)
    )

    // MARK: Synthwave '84

    static let synthwave84 = TerminalTheme(
        name: "Synthwave '84",
        foreground: TerminalColor(r: 255, g: 255, b: 255),
        background: TerminalColor(r: 26, g: 20, b: 46),
        cursor: TerminalColor(r: 255, g: 45, b: 195),
        selection: NSColor(red: 73 / 255, green: 42 / 255, blue: 119 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 26, g: 20, b: 46),    // 0 black
            TerminalColor(r: 254, g: 55, b: 104),  // 1 red
            TerminalColor(r: 114, g: 241, b: 184), // 2 green
            TerminalColor(r: 255, g: 246, b: 133), // 3 yellow
            TerminalColor(r: 54, g: 168, b: 255),  // 4 blue
            TerminalColor(r: 255, g: 45, b: 195),  // 5 magenta
            TerminalColor(r: 54, g: 249, b: 255),  // 6 cyan
            TerminalColor(r: 255, g: 255, b: 255), // 7 white
            TerminalColor(r: 73, g: 42, b: 119),   // 8 bright black
            TerminalColor(r: 254, g: 100, b: 141), // 9 bright red
            TerminalColor(r: 149, g: 255, b: 203), // 10 bright green
            TerminalColor(r: 255, g: 249, b: 168), // 11 bright yellow
            TerminalColor(r: 107, g: 193, b: 255), // 12 bright blue
            TerminalColor(r: 255, g: 100, b: 220), // 13 bright magenta
            TerminalColor(r: 107, g: 255, b: 255), // 14 bright cyan
            TerminalColor(r: 255, g: 255, b: 255)  // 15 bright white
        ],
        chromeBg: NSColor(red: 18 / 255, green: 13 / 255, blue: 35 / 255, alpha: 1),
        chromeText: NSColor(red: 255 / 255, green: 255 / 255, blue: 255 / 255, alpha: 1),
        chromeMuted: NSColor(red: 73 / 255, green: 42 / 255, blue: 119 / 255, alpha: 1),
        sidebarBg: NSColor(red: 32 / 255, green: 26 / 255, blue: 56 / 255, alpha: 1),
        accentColor: NSColor(red: 255 / 255, green: 45 / 255, blue: 195 / 255, alpha: 1)
    )

    // MARK: Moonlight

    static let moonlight = TerminalTheme(
        name: "Moonlight",
        foreground: TerminalColor(r: 195, g: 203, b: 237),
        background: TerminalColor(r: 23, g: 24, b: 38),
        cursor: TerminalColor(r: 130, g: 170, b: 255),
        selection: NSColor(red: 56 / 255, green: 60 / 255, blue: 90 / 255, alpha: 0.5),
        ansiColors: [
            TerminalColor(r: 23, g: 24, b: 38),    // 0 black
            TerminalColor(r: 255, g: 117, b: 127), // 1 red
            TerminalColor(r: 186, g: 230, b: 126), // 2 green
            TerminalColor(r: 255, g: 217, b: 125), // 3 yellow
            TerminalColor(r: 130, g: 170, b: 255), // 4 blue
            TerminalColor(r: 197, g: 152, b: 245), // 5 magenta
            TerminalColor(r: 134, g: 225, b: 220), // 6 cyan
            TerminalColor(r: 195, g: 203, b: 237), // 7 white
            TerminalColor(r: 56, g: 60, b: 90),    // 8 bright black
            TerminalColor(r: 255, g: 137, b: 145), // 9 bright red
            TerminalColor(r: 195, g: 235, b: 147), // 10 bright green
            TerminalColor(r: 255, g: 228, b: 153), // 11 bright yellow
            TerminalColor(r: 155, g: 188, b: 255), // 12 bright blue
            TerminalColor(r: 210, g: 168, b: 255), // 13 bright magenta
            TerminalColor(r: 155, g: 235, b: 230), // 14 bright cyan
            TerminalColor(r: 215, g: 220, b: 245)  // 15 bright white
        ],
        chromeBg: NSColor(red: 16 / 255, green: 17 / 255, blue: 28 / 255, alpha: 1),
        chromeText: NSColor(red: 195 / 255, green: 203 / 255, blue: 237 / 255, alpha: 1),
        chromeMuted: NSColor(red: 56 / 255, green: 60 / 255, blue: 90 / 255, alpha: 1),
        sidebarBg: NSColor(red: 29 / 255, green: 31 / 255, blue: 50 / 255, alpha: 1),
        accentColor: NSColor(red: 130 / 255, green: 170 / 255, blue: 255 / 255, alpha: 1)
    )
}
