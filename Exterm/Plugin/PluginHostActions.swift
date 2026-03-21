/// Closures that plugins use to request actions from the host (MainWindowController).
/// Injected once via PluginRegistry; plugins read from this instead of holding
/// individual callback properties.
/// Deprecated: prefer PluginActions for new code.
@MainActor
struct PluginHostActions {
    var pastePathToActivePane: ((String) -> Void)?
    var openDirectoryInNewTab: ((String) -> Void)?
    var openDirectoryInNewPane: ((String) -> Void)?
    var sendRawToActivePane: ((String) -> Void)?
}
