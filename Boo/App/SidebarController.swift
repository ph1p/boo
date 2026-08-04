import Cocoa
import SwiftUI

/// Controller responsible for sidebar panel management, plugin tab selection,
/// section heights, and scroll offset persistence.
///
/// Extracted from MainWindowController to achieve single-responsibility.
/// Coordinates with WindowStateCoordinator for state persistence.
@MainActor
final class SidebarController {
    // MARK: - Dependencies

    weak var windowController: MainWindowController?
    private var coordinator: WindowStateCoordinator {
        guard let wc = windowController else {
            fatalError("SidebarController accessed after windowController was deallocated")
        }
        return wc.coordinator
    }

    // MARK: - UI Components

    /// Container view holding sidebar content and tab bar.
    var sidebarContainer: NSView!

    /// Tab bar for switching between plugin tabs.
    var sidebarTabBarView: SidebarTabBarView?

    /// Active constraints for tab bar position (top/bottom).
    var sidebarTabBarPositionConstraints: [NSLayoutConstraint] = []

    /// One panel view per plugin tab — keyed by plugin ID.
    var pluginPanelViews: [String: NSView] = [:]

    // MARK: - State

    /// Currently active plugin tab ID.
    var activePluginTabID: String?

    /// Cached detail views per plugin, reused when context and generations match.
    var cachedDetailViews: [String: (context: TerminalContext, generations: [UInt64], view: AnyView)] = [:]

    /// Generation counter per plugin — incremented only when the view is recreated.
    var pluginViewGeneration: [String: UInt64] = [:]

    /// Monotonic counter for assigning generations.
    var viewGenerationCounter: UInt64 = 0

    // MARK: - Visibility

    /// Whether the sidebar is currently visible.
    var isVisible: Bool = false

    /// True when the user explicitly hid the sidebar (Cmd+B).
    /// Prevents plugin cycle from auto-showing on tab switch.
    var isUserHidden: Bool = false

    /// Current sidebar position (left/right).
    var position: SidebarPosition = .right
    /// Last intended visible width. This is the canonical width while hidden or restoring.
    private var intendedVisibleWidth: CGFloat?

    /// When > 0, splitViewDidResizeSubviews should not overwrite workspace sidebar state.
    var suppressSidebarStateSync: Int = 0

    /// Incremented on each workspace activation; async callbacks check this to self-cancel if stale.
    private var activationGeneration: UInt64 = 0

    // MARK: - Computed State Accessors

    /// Expanded plugin section IDs.
    var expandedPluginIDs: Set<String> {
        get { coordinator.expandedPluginIDs }
        set { coordinator.expandedPluginIDs = newValue }
    }

    /// Section IDs the user has explicitly collapsed.
    var userCollapsedSectionIDs: Set<String> {
        get { coordinator.userCollapsedSectionIDs }
        set { coordinator.userCollapsedSectionIDs = newValue }
    }

    /// Persisted sidebar section heights.
    var savedSectionHeights: [String: CGFloat] {
        get { coordinator.sidebarSectionHeights }
        set { coordinator.sidebarSectionHeights = newValue }
    }

    /// Persisted sidebar scroll offsets.
    var savedScrollOffsets: [String: CGPoint] {
        get { coordinator.sidebarScrollOffsets }
        set { coordinator.sidebarScrollOffsets = newValue }
    }

    /// Persisted sidebar section order per plugin.
    var savedSectionOrder: [String: [String]] {
        get { coordinator.sidebarSectionOrder }
        set { coordinator.sidebarSectionOrder = newValue }
    }

    // MARK: - Initialization

    init(windowController: MainWindowController) {
        self.windowController = windowController
        self.isVisible = !AppSettings.shared.sidebarDefaultHidden
        self.isUserHidden = AppSettings.shared.sidebarDefaultHidden
        self.position = AppSettings.shared.sidebarPosition
        self.intendedVisibleWidth = AppSettings.shared.sidebarWidth
    }

    // MARK: - Tab Bar Position

    /// Apply constraints for tab bar position (top/bottom).
    func applyTabBarPositionConstraints() {
        guard let tabBar = sidebarTabBarView, let container = sidebarContainer else { return }
        NSLayoutConstraint.deactivate(sidebarTabBarPositionConstraints)

        // Nudged off the sidebar island's edge on whichever side it docks to, so the
        // pills don't sit flush against the rounded corner. Only the outer side gets
        // it — the inner side already has the panel content below/above it.
        let edgePad = IslandMetrics.tabBarEdgePadding
        if AppSettings.shared.sidebarTabBarPosition == .bottom {
            sidebarTabBarPositionConstraints = [
                tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -edgePad)
            ]
        } else {
            sidebarTabBarPositionConstraints = [
                tabBar.topAnchor.constraint(equalTo: container.topAnchor, constant: edgePad)
            ]
        }
        NSLayoutConstraint.activate(sidebarTabBarPositionConstraints)
    }

    // MARK: - Content Anchors

    /// Top anchor for sidebar content views.
    var contentTopAnchor: NSLayoutYAxisAnchor {
        guard let container = sidebarContainer else { return sidebarContainer.topAnchor }
        return AppSettings.shared.sidebarTabBarPosition == .bottom
            ? container.topAnchor
            : (sidebarTabBarView?.bottomAnchor ?? container.topAnchor)
    }

    /// Bottom anchor for sidebar content views.
    var contentBottomAnchor: NSLayoutYAxisAnchor {
        guard let container = sidebarContainer else { return sidebarContainer.bottomAnchor }
        return AppSettings.shared.sidebarTabBarPosition == .bottom
            ? (sidebarTabBarView?.topAnchor ?? container.bottomAnchor)
            : container.bottomAnchor
    }

    // MARK: - Visibility

    /// Capture current sidebar visibility and intended width into a SidebarWorkspaceState.
    func captureLiveState(for workspace: Workspace? = nil) -> SidebarWorkspaceState {
        let targetWorkspace = workspace ?? windowController?.activeWorkspace
        let fallbackState = resolveEffectiveSidebarState(for: targetWorkspace)
        let width: CGFloat = {
            if isVisible,
                let renderedWidth = currentRenderedSidebarWidth()
            {
                intendedVisibleWidth = renderedWidth
                return renderedWidth
            }
            // When hidden, prefer the workspace's own stored width over intendedVisibleWidth,
            // since intendedVisibleWidth may have been stomped by a different workspace's restore.
            return fallbackState.width ?? intendedVisibleWidth ?? AppSettings.shared.sidebarWidth
        }()
        let captured = SidebarWorkspaceState(isVisible: isVisible, width: width)
        debugLog(
            "[Sidebar] captureLiveState → visible=\(String(describing: captured.isVisible)), width=\(captured.width ?? -1), ws=\(targetWorkspace?.id.uuidString.prefix(8) ?? "nil"), suppress=\(suppressSidebarStateSync)"
        )
        return captured
    }

    /// Apply restored sidebar visibility and width without persisting transient layout state.
    func applyRestoredState(_ state: SidebarWorkspaceState) {
        let resolvedState = resolvedRestoredState(from: state)
        let visible = resolvedState.isVisible ?? isVisible
        let width = resolvedState.width ?? intendedVisibleWidth ?? AppSettings.shared.sidebarWidth
        debugLog(
            "[Sidebar] applyRestoredState → visible=\(visible), width=\(width), ws=\(windowController?.activeWorkspace?.id.uuidString.prefix(8) ?? "nil")"
        )
        intendedVisibleWidth = width
        isUserHidden = !visible
        setVisibility(visible, desiredWidth: width, userInitiated: false, persist: false)
    }

    /// Toggle sidebar visibility.
    /// - Parameter userInitiated: Whether the user explicitly toggled (prevents auto-show).
    func toggle(userInitiated: Bool) {
        // Don't allow showing when no tabs available
        if !isVisible && sidebarTabBarView?.sidebarTabs.isEmpty == true {
            return
        }
        let desiredWidth =
            intendedVisibleWidth ?? resolveEffectiveSidebarState().width ?? AppSettings.shared.sidebarWidth
        debugLog(
            "[Sidebar] toggle userInitiated=\(userInitiated) isVisible=\(isVisible)→\(!isVisible) ws=\(windowController?.activeWorkspace?.id.uuidString.prefix(8) ?? "nil")"
        )
        setVisibility(!isVisible, desiredWidth: desiredWidth, userInitiated: userInitiated, persist: true)
    }

    private func applySidebarWidth(_ width: CGFloat) {
        guard isVisible, let wc = windowController, wc.mainSplitView.subviews.count >= 2 else { return }
        // layoutSubtreeIfNeeded on mainSplitView alone won't update its bounds when
        // the parent constraint pass hasn't run yet; force from the window root.
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        intendedVisibleWidth = width
        let renderedWidth = SidebarStateResolver.normalizedWidth(
            width,
            environment: stateEnvironment(splitViewWidth: wc.mainSplitView.bounds.width)
        )
        let pos = SidebarStateResolver.dividerPosition(
            forSidebarWidth: renderedWidth,
            environment: stateEnvironment(splitViewWidth: wc.mainSplitView.bounds.width)
        )
        wc.mainSplitView.setPosition(pos, ofDividerAt: 0)
    }

    func syncWorkspaceSidebarState() {
        guard suppressSidebarStateSync == 0 else {
            debugLog("[Sidebar] syncWorkspaceSidebarState suppressed (suppress=\(suppressSidebarStateSync))")
            return
        }
        persistLiveState()
    }

    /// Bump activation generation and return the new value. The async width-restore
    /// callback captures this and no-ops if the generation has since advanced.
    func beginActivation() -> UInt64 {
        activationGeneration &+= 1
        return activationGeneration
    }

    func restoreActiveWorkspaceWidth(ifGeneration gen: UInt64? = nil) {
        if let gen, gen != activationGeneration {
            debugLog("[Sidebar] restoreActiveWorkspaceWidth cancelled (stale gen \(gen) vs \(activationGeneration))")
            return
        }
        guard isVisible, let width = resolveEffectiveSidebarState().width else { return }
        debugLog(
            "[Sidebar] restoreActiveWorkspaceWidth applying width=\(width) ws=\(windowController?.activeWorkspace?.id.uuidString.prefix(8) ?? "nil")"
        )
        applySidebarWidth(width)
    }

    func resolveEffectiveSidebarState(for workspace: Workspace? = nil) -> SidebarWorkspaceState {
        SidebarStateResolver.effectiveState(
            workspaceState: (workspace ?? windowController?.activeWorkspace)?.sidebarState,
            environment: stateEnvironment()
        )
    }

    @discardableResult
    func persistLiveState(for workspace: Workspace? = nil) -> SidebarWorkspaceState {
        let capturedState = captureLiveState(for: workspace)
        return persistResolvedState(capturedState, for: workspace)
    }

    @discardableResult
    func persistResolvedState(_ state: SidebarWorkspaceState, for workspace: Workspace? = nil) -> SidebarWorkspaceState
    {
        let target = SidebarStateResolver.persistenceTarget(
            usesPerWorkspaceState: AppSettings.shared.sidebarPerWorkspaceState
        )

        switch target {
        case .workspace:
            let targetWS = workspace ?? windowController?.activeWorkspace
            debugLog(
                "[Sidebar] persistResolvedState → target=workspace ws=\(targetWS?.id.uuidString.prefix(8) ?? "nil") visible=\(String(describing: state.isVisible)), width=\(state.width ?? -1)"
            )
            targetWS?.sidebarState = state
        case .appSettings:
            let persistToSettings = { [state] in
                if let isVisible = state.isVisible {
                    let hidden = !isVisible
                    if AppSettings.shared.sidebarDefaultHidden != hidden {
                        AppSettings.shared.sidebarDefaultHidden = hidden
                    }
                }
                if let width = state.width,
                    abs(AppSettings.shared.sidebarWidth - width) > 0.001
                {
                    AppSettings.shared.sidebarWidth = width
                }
            }
            if let windowController {
                windowController.performWhileIgnoringSidebarLayoutSettingsRefresh {
                    persistToSettings()
                }
            } else {
                persistToSettings()
            }
        }

        return state
    }

    private func resolvedRestoredState(from state: SidebarWorkspaceState) -> SidebarWorkspaceState {
        let effectiveState = SidebarWorkspaceState(
            isVisible: state.isVisible ?? resolveEffectiveSidebarState().isVisible,
            width: state.width ?? resolveEffectiveSidebarState().width ?? intendedVisibleWidth
        )
        return SidebarStateResolver.renderedState(
            from: effectiveState,
            environment: stateEnvironment()
        )
    }

    private func stateEnvironment(splitViewWidth: CGFloat? = nil) -> SidebarStateEnvironment {
        SidebarStateEnvironment(
            defaultState: Workspace.defaultSidebarState(),
            usesPerWorkspaceState: AppSettings.shared.sidebarPerWorkspaceState,
            position: position,
            splitViewWidth: splitViewWidth ?? windowController?.mainSplitView.bounds.width,
            dividerThickness: windowController?.mainSplitView.dividerThickness ?? 1,
            backingScaleFactor: windowController?.window?.backingScaleFactor
                ?? windowController?.mainSplitView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
        )
    }

    private func currentRenderedSidebarWidth() -> CGFloat? {
        guard let wc = windowController else { return nil }
        let idx = position == .left ? 0 : 1
        guard idx < wc.mainSplitView.subviews.count else { return nil }
        return SidebarStateResolver.normalizedWidth(
            wc.mainSplitView.subviews[idx].frame.width,
            environment: stateEnvironment(splitViewWidth: wc.mainSplitView.bounds.width)
        )
    }

    private func setVisibility(
        _ visible: Bool,
        desiredWidth: CGFloat,
        userInitiated: Bool,
        persist: Bool
    ) {
        guard let wc = windowController else { return }

        if userInitiated {
            isUserHidden = !visible
        }
        intendedVisibleWidth = desiredWidth

        if isVisible != visible {
            isVisible = visible
            if visible {
                if position == .left {
                    wc.mainSplitView.subviews.insert(sidebarContainer, at: 0)
                } else {
                    wc.mainSplitView.addSubview(sidebarContainer)
                }
                wc.mainSplitView.adjustSubviews()
            } else {
                sidebarContainer.removeFromSuperview()
            }
        }

        if visible {
            applySidebarWidth(desiredWidth)
            DispatchQueue.main.async { [weak self] in
                self?.applySidebarWidth(desiredWidth)
            }
        }

        wc.statusBar.sidebarVisible = isVisible
        AppStore.shared.sidebarVisible = isVisible
        wc.statusBar.needsDisplay = true
        wc.refreshToolbar()

        for (_, pv) in wc.paneViews {
            pv.currentTerminalView?.needsDisplay = true
            pv.currentTerminalView?.needsLayout = true
        }

        if persist {
            persistLiveState()
        }
    }

}
