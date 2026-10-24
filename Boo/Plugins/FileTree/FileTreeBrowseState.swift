import Foundation

/// How the explorer's folder navigation (`..`, Go Up, Open Folder) moves around.
enum ExplorerNavigationMode: String, CaseIterable, Codable, SettingChoice {
    /// Navigate inside the explorer only; the shell's working directory is untouched.
    case browse = "browse"
    /// Navigate by typing `cd` into the terminal, so the explorer follows the shell.
    case terminal = "terminal"

    var displayName: String {
        switch self {
        case .browse: return "Browse in Explorer"
        case .terminal: return "cd in Terminal"
        }
    }

    static var visibleCases: [ExplorerNavigationMode] { allCases }
}

/// Where one terminal's explorer is browsing, independent of the shell's cwd.
///
/// Attached (`detachedPath == nil`) the explorer shows the terminal's cwd and moves with
/// it. Browsing to another folder detaches it: the root stays put until the user re-links
/// it, or — with "follow terminal" on — until the shell itself changes directory.
struct FileTreeBrowseState: Equatable {
    static let historyLimit = 50

    /// Root the explorer shows instead of the terminal's cwd; nil while attached.
    private(set) var detachedPath: String?
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    /// Terminal cwd seen on the previous `reconcile`, to notice the shell moving.
    private(set) var lastTerminalCwd: String?

    var isDetached: Bool { detachedPath != nil }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func root(terminalCwd: String) -> String { detachedPath ?? terminalCwd }

    /// Show `path` as the root, detaching from the terminal. Recorded in history.
    mutating func browse(to path: String, terminalCwd: String) {
        let current = root(terminalCwd: terminalCwd)
        guard path != current else { return }
        Self.push(current, onto: &back)
        forward.removeAll()
        detachedPath = path
    }

    mutating func goBack(terminalCwd: String) {
        guard let target = back.popLast() else { return }
        Self.push(root(terminalCwd: terminalCwd), onto: &forward)
        detachedPath = target
    }

    mutating func goForward(terminalCwd: String) {
        guard let target = forward.popLast() else { return }
        Self.push(root(terminalCwd: terminalCwd), onto: &back)
        detachedPath = target
    }

    /// Re-link to the terminal's cwd; the folder being left stays reachable via Back.
    mutating func attach(terminalCwd: String) {
        guard let current = detachedPath else { return }
        if current != terminalCwd {
            Self.push(current, onto: &back)
            forward.removeAll()
        }
        detachedPath = nil
    }

    /// The one per-cycle root step. When the shell has moved since the last call and
    /// `follow` is on, a detached explorer re-attaches to the shell's new directory; a
    /// browsed folder that `folderExists` rejects (deleted or renamed) is dropped without
    /// entering history. Returns true when the shown root changed.
    @discardableResult
    mutating func reconcile(terminalCwd: String, follow: Bool, folderExists: (String) -> Bool) -> Bool {
        defer { lastTerminalCwd = terminalCwd }
        guard let shown = detachedPath else { return false }
        if follow, let last = lastTerminalCwd, last != terminalCwd {
            attach(terminalCwd: terminalCwd)
            return true
        }
        guard !folderExists(shown) else { return false }
        detachedPath = nil
        return true
    }

    private static func push(_ path: String, onto stack: inout [String]) {
        guard stack.last != path else { return }
        stack.append(path)
        if stack.count > Self.historyLimit { stack.removeFirst(stack.count - Self.historyLimit) }
    }
}
