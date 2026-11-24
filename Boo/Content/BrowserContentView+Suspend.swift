import Cocoa
import WebKit

/// Unloading idle browser tabs: each WKWebView keeps a WebContent process
/// (often 50–300 MB) alive. A tab out of sight for `suspendDelay` (switched
/// away from in its pane, or left in a workspace not on screen), or right away
/// under memory pressure, drops its web view and keeps only what
/// it needs to come back: history, scroll position and zoom. Showing the tab,
/// or an agent command on it, rebuilds the page.
extension BrowserContentView {
    struct SuspendedPage {
        /// WebKit's back/forward list and scroll position; nil if it had none.
        let interactionState: Any?
        let zoom: CGFloat
        let canGoBack: Bool
        let canGoForward: Bool
    }

    /// How long a tab stays loaded once it is out of sight.
    nonisolated(unsafe) static var suspendDelay: TimeInterval = 10 * 60
    /// Tabs that stay loaded however long they are hidden: those an agent
    /// still running opened, since it may come back to the page it set up.
    nonisolated(unsafe) static var keepsLoaded: @MainActor (UUID) -> Bool = {
        AgentBrowser.ownerHandle(of: $0) != nil
    }

    static let memoryPressure = Notification.Name("BooBrowserMemoryPressure")
    nonisolated(unsafe) private static var pressureSource: DispatchSourceMemoryPressure?

    var isSuspended: Bool { suspended != nil }

    /// Not on screen: switched away from in its pane, or its pane belongs to a
    /// workspace that is not shown. Either way it is out of the window.
    var isOutOfSight: Bool { isRetired || window == nil }

    /// Arms the idle timer; any later use of the tab re-arms it.
    func scheduleSuspend() {
        suspendTimer?.invalidate()
        suspendTimer = nil
        guard isOutOfSight, !isSuspended else { return }
        let timer = Timer(timeInterval: Self.suspendDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendIfIdle() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        suspendTimer = timer
    }

    /// Suspends the tab unless something on it is still going on; then it
    /// waits another round.
    func suspendIfIdle() {
        suspendTimer = nil
        guard let webView, canSuspendNow else { return scheduleSuspend() }
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.canSuspendNow else { return }
                guard state == .none || state == .paused else { return self.scheduleSuspend() }
                self.suspend()
            }
        }
    }

    /// Whether the page may be dropped at this moment (media aside, which
    /// WebKit reports asynchronously).
    var canSuspendNow: Bool {
        guard !isSuspended, let webView else { return false }
        // `window` is set while the tab shows or an agent command stages it.
        return window == nil && !webView.isLoading && !Self.isBlank(currentURL)
            && webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
            && !(tabID.map(Self.keepsLoaded) ?? false)
    }

    /// Drops the web view and its WebContent process, keeping what `resume` needs.
    func suspend() {
        guard let webView, !isSuspended else { return }
        suspendTimer?.invalidate()
        suspendTimer = nil
        if let url = webView.url { currentURL = url }
        suspended = SuspendedPage(
            interactionState: webView.interactionState, zoom: webView.pageZoom,
            canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        endFind()
        tearDownWebView()
        booLog(.debug, .app, "browser tab suspended: \(currentURL.host ?? currentURL.absoluteString)")
    }

    /// Rebuilds a suspended tab's page; a loaded tab only re-arms its idle timer.
    func resume() {
        guard let page = suspended else { return scheduleSuspend() }
        suspended = nil
        setupWebView(load: false)
        guard let webView else { return }
        webView.pageZoom = page.zoom
        if let state = page.interactionState {
            webView.interactionState = state
        } else if !Self.isBlank(currentURL) {
            navigate(to: currentURL)
        }
        updateZoomButton()
        updateNavButtons()
        scheduleSuspend()
    }

    @objc func memoryPressureRaised() {
        suspendIfIdle()
    }

    /// One process-wide source that tells every browser tab when memory runs low.
    static func watchMemoryPressure() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: memoryPressure, object: nil)
        }
        source.activate()
        pressureSource = source
    }
}
