import Cocoa

extension AppSettings {
    // MARK: - Plugins

    var disabledPluginIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.disabledPluginIDs) ?? [] }
        set {
            _disabledPluginIDsSet = nil
            set(newValue, forKey: K.disabledPluginIDs, topic: .plugins)
        }
    }

    /// Cached Set for O(1) lookups — invalidated on write.
    var disabledPluginIDsSet: Set<String> {
        if let cached = _disabledPluginIDsSet { return cached }
        let result = Set(disabledPluginIDs)
        _disabledPluginIDsSet = result
        return result
    }

    /// Whether a plugin is currently enabled (not in the disabled list).
    func isPluginEnabled(_ pluginID: String) -> Bool {
        !disabledPluginIDsSet.contains(pluginID)
    }

    /// Plugins open in the sidebar by default when opening a new pane or starting the app.
    /// Saved tab order for the sidebar tab bar (plugin IDs in display order).
    var sidebarTabOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.sidebarPluginOrder) ?? [] }
        set { set(newValue, forKey: K.sidebarPluginOrder) }
    }

    // MARK: - Sidebar State Persistence

    /// Persisted section heights per section ID. Survives app restart.
    var sidebarSectionHeights: [String: CGFloat] {
        guard let dict = pluginSettingsDict["__sidebar"]?["sectionHeights"] as? [String: Double] else {
            return [:]
        }
        return dict.mapValues { CGFloat($0) }
    }

    /// Persisted section order per plugin ID. Survives app restart.
    var sidebarSectionOrder: [String: [String]] {
        pluginSettingsDict["__sidebar"]?["sectionOrder"] as? [String: [String]] ?? [:]
    }

    /// Persisted expanded section IDs for global sidebar state.
    var sidebarGlobalExpandedSectionIDs: Set<String> {
        Set(pluginSettingsDict["__sidebar"]?["globalExpandedSectionIDs"] as? [String] ?? [])
    }

    /// Persisted explicitly-collapsed section IDs for global sidebar state.
    var sidebarGlobalUserCollapsedSectionIDs: Set<String> {
        Set(pluginSettingsDict["__sidebar"]?["globalUserCollapsedSectionIDs"] as? [String] ?? [])
    }

    /// Persisted selected plugin tab for global sidebar state.
    var sidebarGlobalSelectedPluginTabID: String? {
        pluginSettingsDict["__sidebar"]?["globalSelectedPluginTabID"] as? String
    }

    /// Persisted scroll offsets for global sidebar state.
    var sidebarGlobalScrollOffsets: [String: CGPoint] {
        guard let dict = pluginSettingsDict["__sidebar"]?["globalScrollOffsets"] as? [String: [Double]] else {
            return [:]
        }
        return dict.compactMapValues { values in
            guard values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
    }

    /// Write both sidebar state keys in one dict mutation + one disk write.
    func saveSidebarState(
        heights: [String: CGFloat],
        order: [String: [String]],
        globalExpandedSectionIDs: Set<String>? = nil,
        globalUserCollapsedSectionIDs: Set<String>? = nil,
        globalSelectedPluginTabID: String? = nil,
        globalScrollOffsets: [String: CGPoint]? = nil
    ) {
        var sidebarDict = pluginSettingsDict["__sidebar"] ?? [:]
        sidebarDict["sectionHeights"] = heights.mapValues { Double($0) }
        sidebarDict["sectionOrder"] = order
        if let globalExpandedSectionIDs {
            sidebarDict["globalExpandedSectionIDs"] = Array(globalExpandedSectionIDs)
        }
        if let globalUserCollapsedSectionIDs {
            sidebarDict["globalUserCollapsedSectionIDs"] = Array(globalUserCollapsedSectionIDs)
        }
        if let globalSelectedPluginTabID {
            sidebarDict["globalSelectedPluginTabID"] = globalSelectedPluginTabID
        }
        if let globalScrollOffsets {
            sidebarDict["globalScrollOffsets"] = globalScrollOffsets.mapValues { [Double($0.x), Double($0.y)] }
        }
        var all = pluginSettingsDict
        all["__sidebar"] = sidebarDict
        pluginSettingsDict = all
        saveToFile()
    }

    /// nil = never asked, true = user approved, false = user declined.
    var sshControlMasterApproved: Bool? {
        get {
            UserDefaults.standard.object(forKey: K.sshControlMasterApproved) == nil
                ? nil : UserDefaults.standard.bool(forKey: K.sshControlMasterApproved)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: K.sshControlMasterApproved)
            saveToFile()
        }
    }

    // MARK: - Plugin Settings

    /// Cached — plugins read settings on every sidebar cycle, and bridging the whole
    /// UserDefaults dictionary per read adds up. Invalidated on write.
    var pluginSettingsDict: [String: [String: Any]] {
        get {
            if let cached = _pluginSettingsDict { return cached }
            let dict = UserDefaults.standard.dictionary(forKey: K.pluginSettings) as? [String: [String: Any]] ?? [:]
            _pluginSettingsDict = dict
            return dict
        }
        set {
            UserDefaults.standard.set(newValue, forKey: K.pluginSettings)
            _pluginSettingsDict = newValue
        }
    }

    /// Drop the cached plugin settings after the defaults key was written directly.
    func reloadPluginSettings() {
        _pluginSettingsDict = nil
    }

    func pluginSetting<T>(_ pluginID: String, _ key: String, default defaultValue: T) -> T {
        guard let dict = pluginSettingsDict[pluginID], let val = dict[key] as? T else { return defaultValue }
        return val
    }

    func pluginBool(_ pluginID: String, _ key: String, default defaultValue: Bool) -> Bool {
        pluginSetting(pluginID, key, default: defaultValue)
    }

    func pluginString(_ pluginID: String, _ key: String, default defaultValue: String) -> String {
        pluginSetting(pluginID, key, default: defaultValue)
    }

    func pluginDouble(_ pluginID: String, _ key: String, default defaultValue: Double) -> Double {
        pluginSetting(pluginID, key, default: defaultValue)
    }

    func setPluginSetting(_ pluginID: String, _ key: String, _ value: Any, topic: SettingsTopic? = .plugins) {
        var all = pluginSettingsDict
        var plugin = all[pluginID] ?? [:]
        plugin[key] = value
        all[pluginID] = plugin
        pluginSettingsDict = all
        saveToFile()
        notify(topic: topic)
    }

    /// Returns the full settings dictionary for a given plugin ID.
    func pluginSettingsDict(for pluginID: String) -> [String: Any] {
        pluginSettingsDict[pluginID] ?? [:]
    }

    /// Replaces the full settings dictionary for a given plugin ID.
    func setPluginSettingsDict(_ dict: [String: Any], for pluginID: String) {
        var all = pluginSettingsDict
        all[pluginID] = dict
        pluginSettingsDict = all
        saveToFile()
    }

    func migratePluginIdentity(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        var didChange = false

        var all = pluginSettingsDict
        if all[newID] == nil, let oldSettings = all[oldID] {
            all[newID] = oldSettings
            didChange = true
        }

        if var sidebar = all["__sidebar"] {
            if var order = sidebar["sectionOrder"] as? [String: [String]],
                order[newID] == nil,
                let oldOrder = order[oldID]
            {
                order[newID] = oldOrder
                order.removeValue(forKey: oldID)
                sidebar["sectionOrder"] = order
                didChange = true
            }
            if sidebar["globalSelectedPluginTabID"] as? String == oldID {
                sidebar["globalSelectedPluginTabID"] = newID
                didChange = true
            }
            all["__sidebar"] = sidebar
        }

        if didChange {
            pluginSettingsDict = all
        }

        let migratedOrder = sidebarTabOrder.map { $0 == oldID ? newID : $0 }
        if migratedOrder != sidebarTabOrder {
            var seen = Set<String>()
            sidebarTabOrder = migratedOrder.filter { seen.insert($0).inserted }
            didChange = true
        }

        var disabled = disabledPluginIDs
        if disabled.contains(oldID) {
            disabled.removeAll { $0 == oldID || $0 == newID }
            disabled.append(newID)
            disabledPluginIDs = disabled
            didChange = true
        }

        if didChange {
            saveToFile()
            notify(topic: .plugins)
        }
    }
}
