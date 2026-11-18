import Cocoa
import SwiftUI

/// Fonts for the window chrome (tab bars, workspace bar, toolbar, status bar,
/// palette, find bar). Uses the family from Settings → Fonts → App, or the
/// system font when none is set. Sizes and weights stay as each view designs them.
///
/// Fonts are cached; `AppSettings.notify` clears the cache when the app font changes.
enum AppFont {
    private enum Style: Hashable {
        /// Proportional text.
        case text
        /// Text with digits of equal width, so counters do not jitter.
        case digits
        /// Fixed-width text (paths, branches): the system monospace font, or the
        /// app family with equal-width digits when one is set.
        case mono
    }

    private struct Key: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
        let style: Style
    }

    nonisolated(unsafe) private static var cache: [Key: NSFont] = [:]

    static func ui(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, weight: weight, style: .text)
    }

    static func digits(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, weight: weight, style: .digits)
    }

    static func mono(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, weight: weight, style: .mono)
    }

    /// Drops the cached fonts; the next lookup re-reads the app font setting.
    static func invalidate() {
        cache.removeAll()
    }

    private static func font(size: CGFloat, weight: NSFont.Weight, style: Style) -> NSFont {
        let key = Key(size: size, weight: weight, style: style)
        if let cached = cache[key] { return cached }
        let name = AppSettings.shared.effectiveAppFontName
        let custom = name.isEmpty ? nil : customFont(name, size: size, weight: weight, style: style)
        let resolved = custom ?? systemFont(size: size, weight: weight, style: style)
        cache[key] = resolved
        return resolved
    }

    private static func systemFont(size: CGFloat, weight: NSFont.Weight, style: Style) -> NSFont {
        switch style {
        case .text: NSFont.systemFont(ofSize: size, weight: weight)
        case .digits: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        case .mono: NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    private static func customFont(
        _ family: String, size: CGFloat, weight: NSFont.Weight, style: Style
    ) -> NSFont? {
        var descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        if style != .text {
            descriptor = descriptor.addingAttributes([
                .featureSettings: [
                    [
                        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                    ]
                ]
            ])
        }
        return NSFont(descriptor: descriptor, size: size)
    }
}

extension Font {
    /// The SwiftUI twin of `AppFont.ui`, for chrome built in SwiftUI.
    static func app(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(AppFont.ui(ofSize: size, weight: weight) as CTFont)
    }
}
