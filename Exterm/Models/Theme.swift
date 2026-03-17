import Cocoa

struct TerminalTheme {
    let name: String
    let foreground: TerminalColor
    let background: TerminalColor
    let cursor: TerminalColor
    let selection: NSColor
    let ansiColors: [TerminalColor] // 16 colors: 8 normal + 8 bright

    // UI chrome colors
    let chromeBg: NSColor      // toolbar, status bar
    let chromeText: NSColor
    let chromeMuted: NSColor
    let sidebarBg: NSColor
    let accentColor: NSColor
}

extension TerminalTheme {
    static let themes: [TerminalTheme] = [
        .defaultDark,
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
        .oneDark,
        .rosePine,
        .kanagawa,
    ]

    static let defaultDark = TerminalTheme(
        name: "Default Dark",
        foreground: TerminalColor(r: 228, g: 228, b: 232),
        background: TerminalColor(r: 21, g: 21, b: 23),
        cursor: TerminalColor(r: 228, g: 228, b: 232),
        selection: NSColor(red: 77/255, green: 143/255, blue: 232/255, alpha: 0.3),
        ansiColors: [
            TerminalColor(r: 50, g: 50, b: 55),       // 0 black
            TerminalColor(r: 255, g: 92, b: 87),      // 1 red
            TerminalColor(r: 90, g: 247, b: 142),     // 2 green
            TerminalColor(r: 243, g: 249, b: 157),    // 3 yellow
            TerminalColor(r: 87, g: 199, b: 255),     // 4 blue
            TerminalColor(r: 215, g: 131, b: 255),    // 5 magenta
            TerminalColor(r: 90, g: 240, b: 225),     // 6 cyan
            TerminalColor(r: 228, g: 228, b: 232),    // 7 white
            TerminalColor(r: 102, g: 102, b: 110),    // 8 bright black
            TerminalColor(r: 255, g: 110, b: 103),    // 9 bright red
            TerminalColor(r: 98, g: 255, b: 158),     // 10 bright green
            TerminalColor(r: 255, g: 255, b: 170),    // 11 bright yellow
            TerminalColor(r: 105, g: 212, b: 255),    // 12 bright blue
            TerminalColor(r: 225, g: 150, b: 255),    // 13 bright magenta
            TerminalColor(r: 104, g: 250, b: 237),    // 14 bright cyan
            TerminalColor(r: 242, g: 242, b: 246),    // 15 bright white
        ],
        chromeBg: NSColor(red: 13/255, green: 13/255, blue: 15/255, alpha: 1),
        chromeText: NSColor(red: 228/255, green: 228/255, blue: 232/255, alpha: 1),
        chromeMuted: NSColor(red: 100/255, green: 100/255, blue: 108/255, alpha: 1),
        sidebarBg: NSColor(red: 24/255, green: 24/255, blue: 27/255, alpha: 1),
        accentColor: NSColor(red: 77/255, green: 143/255, blue: 232/255, alpha: 1)
    )

    static let tokyoNight = TerminalTheme(
        name: "Tokyo Night",
        foreground: TerminalColor(r: 192, g: 202, b: 245),
        background: TerminalColor(r: 26, g: 27, b: 38),
        cursor: TerminalColor(r: 192, g: 202, b: 245),
        selection: NSColor(red: 40/255, green: 52/255, blue: 96/255, alpha: 0.6),
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
            TerminalColor(r: 192, g: 202, b: 245),
        ],
        chromeBg: NSColor(red: 22/255, green: 22/255, blue: 30/255, alpha: 1),
        chromeText: NSColor(red: 192/255, green: 202/255, blue: 245/255, alpha: 1),
        chromeMuted: NSColor(red: 86/255, green: 95/255, blue: 137/255, alpha: 1),
        sidebarBg: NSColor(red: 30/255, green: 31/255, blue: 42/255, alpha: 1),
        accentColor: NSColor(red: 122/255, green: 162/255, blue: 247/255, alpha: 1)
    )

    static let catppuccinLatte = TerminalTheme(
        name: "Catppuccin Latte",
        foreground: TerminalColor(r: 76, g: 79, b: 105),
        background: TerminalColor(r: 239, g: 241, b: 245),
        cursor: TerminalColor(r: 76, g: 79, b: 105),
        selection: NSColor(red: 172/255, green: 176/255, blue: 190/255, alpha: 0.4),
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
            TerminalColor(r: 76, g: 79, b: 105),
        ],
        chromeBg: NSColor(red: 230/255, green: 233/255, blue: 239/255, alpha: 1),
        chromeText: NSColor(red: 76/255, green: 79/255, blue: 105/255, alpha: 1),
        chromeMuted: NSColor(red: 108/255, green: 111/255, blue: 133/255, alpha: 1),
        sidebarBg: NSColor(red: 239/255, green: 241/255, blue: 245/255, alpha: 1),
        accentColor: NSColor(red: 30/255, green: 102/255, blue: 245/255, alpha: 1)
    )

    static let catppuccinFrappe = TerminalTheme(
        name: "Catppuccin Frappé",
        foreground: TerminalColor(r: 198, g: 208, b: 245),
        background: TerminalColor(r: 48, g: 52, b: 70),
        cursor: TerminalColor(r: 242, g: 213, b: 207),
        selection: NSColor(red: 81/255, green: 87/255, blue: 109/255, alpha: 0.4),
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
            TerminalColor(r: 198, g: 208, b: 245),
        ],
        chromeBg: NSColor(red: 41/255, green: 44/255, blue: 60/255, alpha: 1),
        chromeText: NSColor(red: 198/255, green: 208/255, blue: 245/255, alpha: 1),
        chromeMuted: NSColor(red: 115/255, green: 121/255, blue: 148/255, alpha: 1),
        sidebarBg: NSColor(red: 48/255, green: 52/255, blue: 70/255, alpha: 1),
        accentColor: NSColor(red: 140/255, green: 170/255, blue: 238/255, alpha: 1)
    )

    static let catppuccinMacchiato = TerminalTheme(
        name: "Catppuccin Macchiato",
        foreground: TerminalColor(r: 202, g: 211, b: 245),
        background: TerminalColor(r: 36, g: 39, b: 58),
        cursor: TerminalColor(r: 244, g: 219, b: 214),
        selection: NSColor(red: 73/255, green: 77/255, blue: 100/255, alpha: 0.4),
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
            TerminalColor(r: 202, g: 211, b: 245),
        ],
        chromeBg: NSColor(red: 30/255, green: 32/255, blue: 48/255, alpha: 1),
        chromeText: NSColor(red: 202/255, green: 211/255, blue: 245/255, alpha: 1),
        chromeMuted: NSColor(red: 110/255, green: 115/255, blue: 141/255, alpha: 1),
        sidebarBg: NSColor(red: 36/255, green: 39/255, blue: 58/255, alpha: 1),
        accentColor: NSColor(red: 138/255, green: 173/255, blue: 244/255, alpha: 1)
    )

    static let catppuccinMocha = TerminalTheme(
        name: "Catppuccin Mocha",
        foreground: TerminalColor(r: 205, g: 214, b: 244),
        background: TerminalColor(r: 30, g: 30, b: 46),
        cursor: TerminalColor(r: 245, g: 224, b: 220),
        selection: NSColor(red: 88/255, green: 91/255, blue: 112/255, alpha: 0.4),
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
            TerminalColor(r: 205, g: 214, b: 244),
        ],
        chromeBg: NSColor(red: 24/255, green: 24/255, blue: 37/255, alpha: 1),
        chromeText: NSColor(red: 205/255, green: 214/255, blue: 244/255, alpha: 1),
        chromeMuted: NSColor(red: 108/255, green: 112/255, blue: 134/255, alpha: 1),
        sidebarBg: NSColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 1),
        accentColor: NSColor(red: 137/255, green: 180/255, blue: 250/255, alpha: 1)
    )

    static let solarizedDark = TerminalTheme(
        name: "Solarized Dark",
        foreground: TerminalColor(r: 131, g: 148, b: 150),
        background: TerminalColor(r: 0, g: 43, b: 54),
        cursor: TerminalColor(r: 131, g: 148, b: 150),
        selection: NSColor(red: 7/255, green: 54/255, blue: 66/255, alpha: 0.8),
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
            TerminalColor(r: 253, g: 246, b: 227),
        ],
        chromeBg: NSColor(red: 0/255, green: 34/255, blue: 43/255, alpha: 1),
        chromeText: NSColor(red: 131/255, green: 148/255, blue: 150/255, alpha: 1),
        chromeMuted: NSColor(red: 88/255, green: 110/255, blue: 117/255, alpha: 1),
        sidebarBg: NSColor(red: 7/255, green: 54/255, blue: 66/255, alpha: 1),
        accentColor: NSColor(red: 38/255, green: 139/255, blue: 210/255, alpha: 1)
    )

    static let dracula = TerminalTheme(
        name: "Dracula",
        foreground: TerminalColor(r: 248, g: 248, b: 242),
        background: TerminalColor(r: 40, g: 42, b: 54),
        cursor: TerminalColor(r: 248, g: 248, b: 242),
        selection: NSColor(red: 68/255, green: 71/255, blue: 90/255, alpha: 0.6),
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
            TerminalColor(r: 255, g: 255, b: 255),
        ],
        chromeBg: NSColor(red: 33/255, green: 34/255, blue: 44/255, alpha: 1),
        chromeText: NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1),
        chromeMuted: NSColor(red: 98/255, green: 114/255, blue: 164/255, alpha: 1),
        sidebarBg: NSColor(red: 40/255, green: 42/255, blue: 54/255, alpha: 1),
        accentColor: NSColor(red: 189/255, green: 147/255, blue: 249/255, alpha: 1)
    )

    static let nord = TerminalTheme(
        name: "Nord",
        foreground: TerminalColor(r: 216, g: 222, b: 233),
        background: TerminalColor(r: 46, g: 52, b: 64),
        cursor: TerminalColor(r: 216, g: 222, b: 233),
        selection: NSColor(red: 67/255, green: 76/255, blue: 94/255, alpha: 0.6),
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
            TerminalColor(r: 236, g: 239, b: 244),
        ],
        chromeBg: NSColor(red: 40/255, green: 44/255, blue: 52/255, alpha: 1),
        chromeText: NSColor(red: 216/255, green: 222/255, blue: 233/255, alpha: 1),
        chromeMuted: NSColor(red: 116/255, green: 125/255, blue: 140/255, alpha: 1),
        sidebarBg: NSColor(red: 46/255, green: 52/255, blue: 64/255, alpha: 1),
        accentColor: NSColor(red: 136/255, green: 192/255, blue: 208/255, alpha: 1)
    )

    static let gruvboxDark = TerminalTheme(
        name: "Gruvbox Dark",
        foreground: TerminalColor(r: 235, g: 219, b: 178),
        background: TerminalColor(r: 40, g: 40, b: 40),
        cursor: TerminalColor(r: 235, g: 219, b: 178),
        selection: NSColor(red: 80/255, green: 73/255, blue: 69/255, alpha: 0.6),
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
            TerminalColor(r: 235, g: 219, b: 178),
        ],
        chromeBg: NSColor(red: 29/255, green: 32/255, blue: 33/255, alpha: 1),
        chromeText: NSColor(red: 235/255, green: 219/255, blue: 178/255, alpha: 1),
        chromeMuted: NSColor(red: 146/255, green: 131/255, blue: 116/255, alpha: 1),
        sidebarBg: NSColor(red: 40/255, green: 40/255, blue: 40/255, alpha: 1),
        accentColor: NSColor(red: 215/255, green: 153/255, blue: 33/255, alpha: 1)
    )

    static let oneDark = TerminalTheme(
        name: "One Dark",
        foreground: TerminalColor(r: 171, g: 178, b: 191),
        background: TerminalColor(r: 40, g: 44, b: 52),
        cursor: TerminalColor(r: 171, g: 178, b: 191),
        selection: NSColor(red: 62/255, green: 68/255, blue: 81/255, alpha: 0.6),
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
            TerminalColor(r: 200, g: 204, b: 212),
        ],
        chromeBg: NSColor(red: 33/255, green: 37/255, blue: 43/255, alpha: 1),
        chromeText: NSColor(red: 171/255, green: 178/255, blue: 191/255, alpha: 1),
        chromeMuted: NSColor(red: 92/255, green: 99/255, blue: 112/255, alpha: 1),
        sidebarBg: NSColor(red: 40/255, green: 44/255, blue: 52/255, alpha: 1),
        accentColor: NSColor(red: 97/255, green: 175/255, blue: 239/255, alpha: 1)
    )

    static let solarizedLight = TerminalTheme(
        name: "Solarized Light",
        foreground: TerminalColor(r: 101, g: 123, b: 131),
        background: TerminalColor(r: 253, g: 246, b: 227),
        cursor: TerminalColor(r: 101, g: 123, b: 131),
        selection: NSColor(red: 238/255, green: 232/255, blue: 213/255, alpha: 0.8),
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
            TerminalColor(r: 0, g: 43, b: 54),
        ],
        chromeBg: NSColor(red: 238/255, green: 232/255, blue: 213/255, alpha: 1),
        chromeText: NSColor(red: 101/255, green: 123/255, blue: 131/255, alpha: 1),
        chromeMuted: NSColor(red: 147/255, green: 161/255, blue: 161/255, alpha: 1),
        sidebarBg: NSColor(red: 253/255, green: 246/255, blue: 227/255, alpha: 1),
        accentColor: NSColor(red: 38/255, green: 139/255, blue: 210/255, alpha: 1)
    )

    static let rosePine = TerminalTheme(
        name: "Rosé Pine",
        foreground: TerminalColor(r: 224, g: 222, b: 244),
        background: TerminalColor(r: 25, g: 23, b: 36),
        cursor: TerminalColor(r: 224, g: 222, b: 244),
        selection: NSColor(red: 38/255, green: 35/255, blue: 53/255, alpha: 0.8),
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
            TerminalColor(r: 224, g: 222, b: 244),
        ],
        chromeBg: NSColor(red: 21/255, green: 19/255, blue: 30/255, alpha: 1),
        chromeText: NSColor(red: 224/255, green: 222/255, blue: 244/255, alpha: 1),
        chromeMuted: NSColor(red: 110/255, green: 106/255, blue: 134/255, alpha: 1),
        sidebarBg: NSColor(red: 25/255, green: 23/255, blue: 36/255, alpha: 1),
        accentColor: NSColor(red: 196/255, green: 167/255, blue: 231/255, alpha: 1)
    )

    static let kanagawa = TerminalTheme(
        name: "Kanagawa",
        foreground: TerminalColor(r: 220, g: 215, b: 186),
        background: TerminalColor(r: 31, g: 31, b: 40),
        cursor: TerminalColor(r: 220, g: 215, b: 186),
        selection: NSColor(red: 43/255, green: 43/255, blue: 58/255, alpha: 0.8),
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
            TerminalColor(r: 220, g: 215, b: 186),
        ],
        chromeBg: NSColor(red: 22/255, green: 22/255, blue: 29/255, alpha: 1),
        chromeText: NSColor(red: 220/255, green: 215/255, blue: 186/255, alpha: 1),
        chromeMuted: NSColor(red: 84/255, green: 84/255, blue: 109/255, alpha: 1),
        sidebarBg: NSColor(red: 31/255, green: 31/255, blue: 40/255, alpha: 1),
        accentColor: NSColor(red: 126/255, green: 156/255, blue: 216/255, alpha: 1)
    )
}
