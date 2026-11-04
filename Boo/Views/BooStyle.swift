import SwiftUI

/// Boo's shared metrics: the numbers behind every themed control, so a button,
/// a field and a picker in one row line up and round the same way.
/// Colours live on `Tokens` / `TerminalTheme`; see documentation/STYLEGUIDE.md.
enum BooStyle {
    /// Spacing scale (pt). Pick the nearest step instead of a one-off value.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    /// Corner radii (always `.continuous`).
    enum Radius {
        /// Checkboxes, tiny badges.
        static let tiny: CGFloat = 3.5
        /// Buttons, fields, pickers, segments' track.
        static let control: CGFloat = 6
        /// Large call-to-action buttons.
        static let large: CGFloat = 8
        /// Cards and inline forms.
        static let card: CGFloat = 10
    }

    /// Control heights: small controls share one height so they align in a row.
    enum Height {
        /// Small buttons, text fields, steppers, segmented and menu pickers.
        static let control: CGFloat = 24
        /// Full-width calls to action.
        static let large: CGFloat = 32
    }

    /// Fixed-size type for chrome that does not follow the sidebar font scale.
    enum Font {
        static let body = SwiftUI.Font.system(size: 12)
        static let control = SwiftUI.Font.system(size: 11, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11)
        static let sectionTitle = SwiftUI.Font.system(size: 11, weight: .semibold)
    }
}
