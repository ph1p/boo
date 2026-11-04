import Cocoa

extension AppSettings {
    // MARK: - Status Bar

    var statusBarShowPath: Bool {
        get { bool(K.statusBarShowPath, default: true) }
        set { set(newValue, forKey: K.statusBarShowPath, topic: .statusBar) }
    }

    var statusBarShowGitBranch: Bool {
        get { pluginBool("git-panel", "showBranch", default: true) }
        set { setPluginSetting("git-panel", "showBranch", newValue, topic: .statusBar) }
    }

    var statusBarShowTime: Bool {
        get { bool(K.statusBarShowTime, default: true) }
        set { set(newValue, forKey: K.statusBarShowTime, topic: .statusBar) }
    }

    var statusBarShowPaneInfo: Bool {
        get { bool(K.statusBarShowPaneInfo, default: true) }
        set { set(newValue, forKey: K.statusBarShowPaneInfo, topic: .statusBar) }
    }

    /// Listening ports of the active workspace's processes.
    var statusBarShowPorts: Bool {
        get { bool(K.statusBarShowPorts, default: true) }
        set { set(newValue, forKey: K.statusBarShowPorts, topic: .statusBar) }
    }

    var statusBarShowConnection: Bool {
        get { bool(K.statusBarShowConnection, default: true) }
        set { set(newValue, forKey: K.statusBarShowConnection, topic: .statusBar) }
    }

    /// Segment IDs on the left side, in visual left-to-right order. Empty means
    /// the built-in order; segments missing from both lists keep their default side.
    var statusBarLeftOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.statusBarLeftOrder) ?? [] }
        set { set(newValue, forKey: K.statusBarLeftOrder, topic: .statusBar) }
    }

    /// Segment IDs on the right side, in visual left-to-right order.
    var statusBarRightOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.statusBarRightOrder) ?? [] }
        set { set(newValue, forKey: K.statusBarRightOrder, topic: .statusBar) }
    }

    /// Segments the user switched off that have no dedicated toggle of their own.
    var statusBarHiddenSegments: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.statusBarHiddenSegments) ?? [] }
        set { set(newValue, forKey: K.statusBarHiddenSegments, topic: .statusBar) }
    }

    var statusBarClockFormat: StatusBarClockFormat {
        get {
            StatusBarClockFormat(rawValue: UserDefaults.standard.integer(forKey: K.statusBarClockFormat))
                ?? .hoursMinutes
        }
        set { set(newValue.rawValue, forKey: K.statusBarClockFormat, topic: .statusBar) }
    }

    var statusBarPathStyle: StatusBarPathStyle {
        get {
            StatusBarPathStyle(rawValue: UserDefaults.standard.integer(forKey: K.statusBarPathStyle)) ?? .abbreviated
        }
        set { set(newValue.rawValue, forKey: K.statusBarPathStyle, topic: .statusBar) }
    }

    /// Characters of the git branch name shown before it is cut with an ellipsis.
    var statusBarBranchMaxLength: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: K.statusBarBranchMaxLength)
            return value > 0 ? value : 20
        }
        set { set(max(4, min(newValue, 80)), forKey: K.statusBarBranchMaxLength, topic: .statusBar) }
    }

    /// Thin divider lines between left-side segments.
    var statusBarSeparators: Bool {
        get { bool(K.statusBarSeparators, default: true) }
        set { set(newValue, forKey: K.statusBarSeparators, topic: .statusBar) }
    }

    /// Built-in segments that had a toggle before segments could be hidden
    /// generically. Their toggle stays the source of truth, so the old settings
    /// and this API never disagree. `path` is handled apart: its toggle is a
    /// file-tree plugin setting.
    nonisolated(unsafe) private static let statusBarSegmentToggles:
        [String: ReferenceWritableKeyPath<AppSettings, Bool>] = [
            "git-branch": \.statusBarShowGitBranch,
            "time": \.statusBarShowTime,
            "pane-info": \.statusBarShowPaneInfo,
            "ports": \.statusBarShowPorts,
            "environment": \.statusBarShowConnection
        ]

    /// Whether the user switched a status bar segment off.
    func isStatusBarSegmentHidden(_ id: String) -> Bool {
        if id == "path" { return !pluginBool("file-tree-local", "showPath", default: true) }
        if let toggle = Self.statusBarSegmentToggles[id] { return !self[keyPath: toggle] }
        return statusBarHiddenSegments.contains(id)
    }

    func setStatusBarSegment(_ id: String, hidden: Bool) {
        if id == "path" {
            setPluginSetting("file-tree-local", "showPath", !hidden, topic: .statusBar)
        } else if let toggle = Self.statusBarSegmentToggles[id] {
            self[keyPath: toggle] = !hidden
        } else {
            var list = statusBarHiddenSegments.filter { $0 != id }
            if hidden { list.append(id) }
            statusBarHiddenSegments = list
        }
    }

    /// Saves both sides' order with one file write and one change notification.
    func setStatusBarOrder(left: [String], right: [String]) {
        UserDefaults.standard.set(left, forKey: K.statusBarLeftOrder)
        UserDefaults.standard.set(right, forKey: K.statusBarRightOrder)
        saveToFile()
        notify(topic: .statusBar)
    }

    /// Back to the built-in order and sides; visibility is left alone.
    func resetStatusBarLayout() {
        UserDefaults.standard.removeObject(forKey: K.statusBarLeftOrder)
        UserDefaults.standard.removeObject(forKey: K.statusBarRightOrder)
        saveToFile()
        notify(topic: .statusBar)
    }
}
