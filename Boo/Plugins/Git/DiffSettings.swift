import Foundation

/// How the diff viewer lays out a change.
enum DiffLayout: String, CaseIterable, Codable, SettingChoice {
    /// Old and new lines in one column, like `git diff`.
    case unified
    /// Old lines left, new lines right.
    case split

    var displayName: String {
        switch self {
        case .unified: return "Unified"
        case .split: return "Side by side"
        }
    }

    static var visibleCases: [DiffLayout] { allCases }
}

/// The diff viewer's app-wide defaults, set under the Git plugin's settings.
/// A viewer tab starts from these and can flip layout and wrap for itself.
enum DiffSettings {
    static let pluginID = "git-panel"
    static let maxContext = 20

    static var layout: DiffLayout {
        DiffLayout(rawValue: AppSettings.shared.pluginString(pluginID, "diffLayout", default: "")) ?? .unified
    }

    static var wrap: Bool { AppSettings.shared.pluginBool(pluginID, "diffWrap", default: false) }

    /// Lines of context around each change (`git diff -U<n>`).
    static var context: Int {
        clampedContext(
            AppSettings.shared.pluginDouble(pluginID, "diffContext", default: Double(AgentReview.defaultContext)))
    }

    static func clampedContext(_ value: Double) -> Int {
        guard value.isFinite else { return AgentReview.defaultContext }
        return min(maxContext, max(0, Int(value.rounded())))
    }
}
