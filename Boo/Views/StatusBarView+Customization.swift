import Cocoa

/// User-facing arrangement of the status bar: which segments show, on which
/// side, in what order, plus the right-click menu that edits it in place.
extension StatusBarView {
    /// One registered segment, as the settings UI and context menu list it.
    struct SegmentInfo: Identifiable, Equatable {
        let id: String
        let displayName: String
        let isLeftByDefault: Bool
    }

    /// Built-in arrangement: left segments by ascending priority, right
    /// segments with the lowest priority nearest the right edge.
    var defaultArrangement: StatusBarLayout.Arrangement {
        .init(left: leftPlugins.map(\.id), right: rightPlugins.reversed().map(\.id))
    }

    /// The arrangement after applying the user's saved order.
    func arrangement(settings: AppSettings = .shared) -> StatusBarLayout.Arrangement {
        StatusBarLayout.arrange(
            defaults: defaultArrangement, leftOrder: settings.statusBarLeftOrder,
            rightOrder: settings.statusBarRightOrder)
    }

    /// Every registered segment, keyed by ID. The first registration wins.
    var pluginsByID: [String: StatusBarPlugin] {
        Dictionary((leftPlugins + rightPlugins).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every registered segment, keyed by ID.
    var segmentCatalog: [String: SegmentInfo] {
        pluginsByID.mapValues {
            SegmentInfo(id: $0.id, displayName: $0.displayName, isLeftByDefault: $0.position == .left)
        }
    }

    /// Saves `arrangement` as the user's order. Both sides are written so a
    /// segment moved across stays there.
    static func save(_ arrangement: StatusBarLayout.Arrangement, settings: AppSettings = .shared) {
        settings.setStatusBarOrder(left: arrangement.left, right: arrangement.right)
    }

    // MARK: - Clock

    /// Repaints at the next minute (or second) boundary while the clock is
    /// drawn, so the time stays current without anything else triggering a draw.
    func updateClockTimer(settings: AppSettings) {
        guard drawnSegments.contains(where: { $0.plugin is TimeSegment }) else {
            clockTimer?.invalidate()
            clockTimer = nil
            return
        }
        let interval: TimeInterval = settings.statusBarClockFormat.showsSeconds ? 1 : 60
        let now = Date().timeIntervalSince1970
        let next = (floor(now / interval) + 1) * interval
        let fireDate = Date(timeIntervalSince1970: next + 0.01)
        // Other redraws within the same minute (or second) keep the pending timer.
        if let clockTimer, clockTimer.isValid, abs(clockTimer.fireDate.timeIntervalSince(fireDate)) < 0.001 { return }
        clockTimer?.invalidate()
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        timer.tolerance = interval == 1 ? 0.05 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        let settings = AppSettings.shared
        let arrangement = arrangement(settings: settings)
        let catalog = segmentCatalog

        @discardableResult
        func add(_ title: String, _ action: Selector?, id: String? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.representedObject = id
            return item
        }

        if let plugin = segment(at: point) {
            add("Hide \u{201C}\(plugin.displayName)\u{201D}", #selector(toggleSegmentFromMenu(_:)), id: plugin.id)
            let isLeft = arrangement.left.contains(plugin.id)
            add(
                isLeft ? "Move to Right Side" : "Move to Left Side", #selector(moveSegmentAcrossFromMenu(_:)),
                id: plugin.id)
            menu.addItem(.separator())
        }

        add("Show in Status Bar", nil).isEnabled = false
        for id in arrangement.left + arrangement.right {
            guard let info = catalog[id] else { continue }
            let item = add(info.displayName, #selector(toggleSegmentFromMenu(_:)), id: id)
            item.state = settings.isStatusBarSegmentHidden(id) ? .off : .on
            item.indentationLevel = 1
            if collapsedSegmentIDs.contains(id) {
                item.toolTip = "Shown, but left out while the window is too narrow"
            }
        }

        menu.addItem(.separator())
        add("Reset Layout", #selector(resetLayoutFromMenu(_:)))
        add("Status Bar Settings\u{2026}", #selector(openStatusBarSettings(_:)))
        return menu
    }

    @objc private func toggleSegmentFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let settings = AppSettings.shared
        settings.setStatusBarSegment(id, hidden: !settings.isStatusBarSegmentHidden(id))
    }

    @objc private func moveSegmentAcrossFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let current = arrangement()
        let toLeft = !current.left.contains(id)
        Self.save(StatusBarLayout.moving(id, toLeft: toLeft, in: current))
    }

    @objc private func resetLayoutFromMenu(_ sender: NSMenuItem) {
        AppSettings.shared.resetStatusBarLayout()
    }

    @objc private func openStatusBarSettings(_ sender: NSMenuItem) {
        SettingsWindowController.shared.showSettings(tab: .statusBar)
    }
}
