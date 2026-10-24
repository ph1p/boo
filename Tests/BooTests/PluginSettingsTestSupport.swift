import XCTest

@testable import Boo

extension XCTestCase {
    /// Run `body` with the plugin settings replaced by `merge(current)`, restoring the
    /// original dictionary afterwards. Writes UserDefaults directly — `setPluginSetting`
    /// would also rewrite ~/.boo/settings.json.
    @MainActor
    func withPluginSettings(
        _ merge: (inout [String: [String: Any]]) -> Void, _ body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "pluginSettings")
        defer {
            if let original {
                defaults.set(original, forKey: "pluginSettings")
            } else {
                defaults.removeObject(forKey: "pluginSettings")
            }
            AppSettings.shared.reloadPluginSettings()
        }
        var all = defaults.dictionary(forKey: "pluginSettings") as? [String: [String: Any]] ?? [:]
        merge(&all)
        defaults.set(all, forKey: "pluginSettings")
        AppSettings.shared.reloadPluginSettings()
        try body()
    }

    /// Merge `values` into one plugin's settings for the duration of `body`.
    @MainActor
    func withPluginSettings(
        _ pluginID: String, _ values: [String: Any], _ body: () throws -> Void
    ) rethrows {
        try withPluginSettings({ $0[pluginID, default: [:]].merge(values) { _, new in new } }, body)
    }
}
