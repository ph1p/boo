import AppKit

// MARK: - Window placement across displays

extension MainWindowController {
    /// Applies a saved window's frame. Returns the placement to return to once
    /// its display reconnects, nil when the window already sits where it lived.
    static func applySavedPlacement(_ saved: SessionWindow?, to window: NSWindow) -> WindowPlacement? {
        guard let saved else { return nil }
        let screens = PlacementScreen.current
        if let home = saved.homePlacement, WindowPlacementResolver.isScreenConnected(home, in: screens),
            let resolved = WindowPlacementResolver.resolve(home, in: screens)
        {
            window.setFrame(resolved.frame, display: false)
            return nil
        }
        guard let placement = saved.placement, let resolved = WindowPlacementResolver.resolve(placement, in: screens)
        else { return saved.homePlacement }
        window.setFrame(resolved.frame, display: false)
        return saved.homePlacement ?? (resolved.onSavedScreen ? nil : placement)
    }

    func startPlacementTracking() {
        lastPlacement = currentPlacement()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func windowDidMove(_ notification: Notification) {
        schedulePlacementCommit()
    }

    func windowDidResize(_ notification: Notification) {
        schedulePlacementCommit()
    }

    /// The windowed frame (never the fullscreen one) and the display it is on.
    func currentPlacement() -> WindowPlacement? {
        guard let window else { return nil }
        let frame = window.styleMask.contains(.fullScreen) ? (windowedFrame ?? window.frame) : window.frame
        return WindowPlacementResolver.capture(frame, in: PlacementScreen.current)
    }

    /// The last settled placement's display is gone: macOS moved the window,
    /// not the user, so keep where it lived.
    func rememberDisplacedPlacement(in screens: [PlacementScreen]) {
        guard homePlacement == nil, let last = lastPlacement, last.screenID != nil,
            !WindowPlacementResolver.isScreenConnected(last, in: screens)
        else { return }
        homePlacement = last
    }

    /// Settles once the window rests, so a move macOS makes while a display
    /// disconnects can't replace the placement before `screensChanged` sees it.
    private func schedulePlacementCommit() {
        placementCommit?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.commitPlacement() }
        }
        placementCommit = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func commitPlacement() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let screens = PlacementScreen.current
        rememberDisplacedPlacement(in: screens)
        let placement = WindowPlacementResolver.capture(window.frame, in: screens)
        lastPlacement = placement
        // Back on its home display, by the user or by `screensChanged`.
        if let home = homePlacement, home.screenID == placement.screenID { homePlacement = nil }
    }

    private func screensChanged() {
        placementCommit?.cancel()
        let screens = PlacementScreen.current
        rememberDisplacedPlacement(in: screens)
        if let window, !window.styleMask.contains(.fullScreen), let home = homePlacement,
            WindowPlacementResolver.isScreenConnected(home, in: screens),
            let resolved = WindowPlacementResolver.resolve(home, in: screens)
        {
            window.setFrame(resolved.frame, display: true)
            homePlacement = nil
        }
        schedulePlacementCommit()
    }
}
