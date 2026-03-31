import Cocoa

/// Centralized density metrics for consistent spacing across all components.
/// All components read from this instead of hardcoded values.
struct DensityMetrics {
    let listItemHeight: CGFloat
    let statusBarHeight: CGFloat
    let panelPaddingH: CGFloat
    let panelPaddingV: CGFloat
    let panelGap: CGFloat
    let iconSize: CGFloat
    let fontSize: CGFloat

    static var current: DensityMetrics {
        DensityMetrics(for: AppSettings.shared.sidebarDensity)
    }

    init(for density: SidebarDensity) {
        switch density {
        case .comfortable:
            listItemHeight = 28
            statusBarHeight = 28
            panelPaddingH = 12
            panelPaddingV = 8
            panelGap = 8
            iconSize = 16
            fontSize = 13
        case .compact:
            listItemHeight = 22
            statusBarHeight = 24
            panelPaddingH = 8
            panelPaddingV = 6
            panelGap = 4
            iconSize = 14
            fontSize = 12
        }
    }

    /// Whether animations should be used (respects reduced motion preference).
    static var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
