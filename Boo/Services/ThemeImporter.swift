import Foundation

/// Converts third-party terminal color schemes into Boo custom themes.
/// Supported: iTerm2 `.itermcolors` property lists and Ghostty theme files
/// (`palette = N=#rrggbb`, `background`, `foreground`, `cursor-color`,
/// `selection-background`). Chrome colors are derived from the terminal
/// colors so an imported theme looks coherent without manual tweaking.
enum ThemeImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case unrecognizedFormat
        case missingColors

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .unrecognizedFormat: return "The file is not an iTerm2 or Ghostty color scheme."
            case .missingColors: return "The file does not define a background and foreground color."
            }
        }
    }

    static func importTheme(at url: URL) throws -> CustomThemeData {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let name = url.deletingPathExtension().lastPathComponent
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return try parseITerm(plist, name: name)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.unrecognizedFormat }
        return try parseGhostty(text, name: name)
    }

    // MARK: - iTerm2

    static func parseITerm(_ plist: [String: Any], name: String) throws -> CustomThemeData {
        func color(_ key: String) -> TerminalColor? {
            guard let dict = plist[key] as? [String: Any] else { return nil }
            func component(_ c: String) -> UInt8? {
                guard let v = (dict["\(c) Component"] as? NSNumber)?.doubleValue else { return nil }
                return UInt8((min(max(v, 0), 1) * 255).rounded())
            }
            guard let r = component("Red"), let g = component("Green"), let b = component("Blue") else { return nil }
            return TerminalColor(r: r, g: g, b: b)
        }
        guard plist.keys.contains(where: { $0.hasPrefix("Ansi ") || $0.hasSuffix(" Color") }) else {
            throw ImportError.unrecognizedFormat
        }
        guard let bg = color("Background Color"), let fg = color("Foreground Color") else {
            throw ImportError.missingColors
        }
        let palette = (0..<16).map { color("Ansi \($0) Color") }
        return build(
            name: name, foreground: fg, background: bg, cursor: color("Cursor Color"),
            selection: color("Selection Color"), palette: palette)
    }

    // MARK: - Ghostty

    static func parseGhostty(_ text: String, name: String) throws -> CustomThemeData {
        var palette = [TerminalColor?](repeating: nil, count: 16)
        var bg: TerminalColor?
        var fg: TerminalColor?
        var cursor: TerminalColor?
        var selection: TerminalColor?
        var sawKey = false

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "palette":
                // "N=#rrggbb"
                let parts = value.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, let idx = Int(parts[0]), (0..<16).contains(idx) {
                    palette[idx] = TerminalColor(hex: parts[1])
                    sawKey = true
                }
            case "background":
                bg = TerminalColor(hex: value)
                sawKey = true
            case "foreground":
                fg = TerminalColor(hex: value)
                sawKey = true
            case "cursor-color":
                cursor = TerminalColor(hex: value)
                sawKey = true
            case "selection-background":
                selection = TerminalColor(hex: value)
                sawKey = true
            default: continue
            }
        }
        guard sawKey else { throw ImportError.unrecognizedFormat }
        guard let bg, let fg else { throw ImportError.missingColors }
        return build(name: name, foreground: fg, background: bg, cursor: cursor, selection: selection, palette: palette)
    }

    // MARK: - Assembly

    /// Fills gaps from Boo's default palette and derives the chrome colors.
    static func build(
        name: String, foreground fg: TerminalColor, background bg: TerminalColor,
        cursor: TerminalColor?, selection: TerminalColor?, palette: [TerminalColor?]
    ) -> CustomThemeData {
        let fallback = TerminalTheme.themes.first?.ansiColors ?? []
        let ansi = (0..<16).map { i in
            palette.indices.contains(i) ? (palette[i] ?? fallback[safe: i] ?? fg) : (fallback[safe: i] ?? fg)
        }
        let dark = bg.luminance < 0.5
        return CustomThemeData(
            name: name,
            foreground: fg,
            background: bg,
            cursor: cursor ?? fg,
            selectionHex: (selection ?? mix(fg, bg, 0.3)).hexString,
            ansiColors: ansi,
            chromeBgHex: bg.hexString,
            chromeTextHex: fg.hexString,
            chromeMutedHex: mix(fg, bg, 0.5).hexString,
            sidebarBgHex: bg.highlight(dark ? 0.03 : -0.03).hexString,
            accentHex: ansi[4].hexString
        )
    }

    /// Linear blend: `t` of `a` over `b`.
    static func mix(_ a: TerminalColor, _ b: TerminalColor, _ t: Double) -> TerminalColor {
        func ch(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * t + Double(y) * (1 - t)).rounded()) }
        return TerminalColor(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b))
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
