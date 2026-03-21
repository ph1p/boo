import Combine
import Foundation

/// Global observable store — the single source of truth for app-wide state.
///
/// Any view or plugin can read `AppStore.shared` to get the current terminal context,
/// theme, sidebar state, and visible plugin set. Published properties use Equatable
/// guards to suppress spurious updates.
///
/// Updated by `MainWindowController` at the end of each plugin cycle and on
/// sidebar/theme changes. This is a read projection — it does not own or manage
/// the underlying state.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    // MARK: - Terminal Context

    /// The current terminal context for the focused pane/tab.
    @Published private(set) var context: TerminalContext = .empty

    // MARK: - Theme

    /// Current theme snapshot, updated on theme change.
    @Published private(set) var theme: ThemeSnapshot

    // MARK: - Sidebar

    /// Whether the sidebar is currently visible.
    @Published var sidebarVisible: Bool = false

    /// IDs of plugins currently open in the sidebar.
    @Published var openPluginIDs: Set<String> = []

    /// IDs of plugins passing their when-clause (context-dependent visibility).
    @Published private(set) var visiblePluginIDs: Set<String> = []

    // MARK: - Init

    private init() {
        self.theme = ThemeSnapshot(from: AppSettings.shared.theme)
    }

    // MARK: - Update Methods

    /// Called at the end of each plugin cycle.
    func updateContext(_ newContext: TerminalContext) {
        if context != newContext {
            context = newContext
        }
    }

    /// Called at the end of each plugin cycle.
    func updateVisiblePlugins(_ ids: Set<String>) {
        if visiblePluginIDs != ids {
            visiblePluginIDs = ids
        }
    }

    /// Called when the theme changes.
    func refreshTheme() {
        theme = ThemeSnapshot(from: AppSettings.shared.theme)
    }
}
