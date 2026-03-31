import Foundation

/// Marker protocol for values stored in a plugin state bag.
/// Conforming types can be stored and retrieved type-safely.
/// ADR-2: Future-proof for Codable, Equatable, Sendable extensions.
protocol PluginStateValue {}

/// Per-terminal storage for plugin-cached data.
/// Each terminal owns one PluginStateBag. When a terminal closes,
/// the bag is released and all cached plugin data is freed.
///
/// All access must be on the main thread (same as all UI code).
@MainActor
final class PluginStateBag {
    private var storage: [String: any PluginStateValue] = [:]

    /// Retrieve a typed value for a plugin.
    func get<T: PluginStateValue>(_ type: T.Type, for pluginID: String) -> T? {
        storage[pluginID] as? T
    }

    /// Store a value for a plugin. Overwrites any previous value.
    func set(_ value: any PluginStateValue, for pluginID: String) {
        storage[pluginID] = value
    }

    /// Remove a plugin's cached state.
    func remove(for pluginID: String) {
        storage.removeValue(forKey: pluginID)
    }

    /// Remove all cached state (called when terminal closes).
    func removeAll() {
        storage.removeAll()
    }

    /// Number of stored entries.
    var count: Int { storage.count }
}
