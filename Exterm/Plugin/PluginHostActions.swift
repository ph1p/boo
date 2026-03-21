/// Closures that plugins use to request actions from the host (MainWindowController).
/// Injected once via PluginRegistry; plugins read from this instead of holding
/// individual callback properties.
@MainActor
struct PluginHostActions {
    var pastePathToActivePane: ((String) -> Void)?
    var openDirectoryInNewTab: ((String) -> Void)?
    var openDirectoryInNewPane: ((String) -> Void)?
    var sendRawToActivePane: ((String) -> Void)?
    weak var bridge: TerminalBridge?
}
