import Foundation

/// Context passed to a registered multi-content tab factory.
/// Also used as the deduplication key — two openMultiContentTab calls with the same
/// `typeID` and equal `key` will focus the existing tab rather than open a new one.
struct PluginTabContext {
    /// The SF Symbol name for the tab icon.
    let icon: String
    /// The tab's display title.
    let title: String
    /// Deduplication key. Two calls with the same typeID + key focus the existing tab.
    /// Defaults to an empty string (all calls with the same typeID share one tab).
    let key: String

    init(title: String, icon: String, key: String = "") {
        self.title = title
        self.icon = icon
        self.key = key
    }
}
