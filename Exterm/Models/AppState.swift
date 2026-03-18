import Foundation

/// Global application state: manages workspaces.
final class AppState {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceIndex: Int = -1

    var activeWorkspace: Workspace? {
        guard activeWorkspaceIndex >= 0, activeWorkspaceIndex < workspaces.count else { return nil }
        return workspaces[activeWorkspaceIndex]
    }

    func addWorkspace(_ workspace: Workspace) {
        workspaces.append(workspace)
        activeWorkspaceIndex = workspaces.count - 1
    }

    func removeWorkspace(at index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        workspaces[index].stopAll()
        workspaces.remove(at: index)
        if activeWorkspaceIndex >= workspaces.count {
            activeWorkspaceIndex = workspaces.count - 1
        }
    }

    func setActiveWorkspace(_ index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        activeWorkspaceIndex = index
    }

    func moveWorkspace(from source: Int, to destination: Int) {
        guard source != destination, source >= 0, source < workspaces.count,
              destination >= 0, destination <= workspaces.count else { return }
        let ws = workspaces.remove(at: source)
        let dest = destination > source ? destination - 1 : destination
        workspaces.insert(ws, at: dest)
        if activeWorkspaceIndex == source {
            activeWorkspaceIndex = dest
        } else if source < activeWorkspaceIndex && dest >= activeWorkspaceIndex {
            activeWorkspaceIndex -= 1
        } else if source > activeWorkspaceIndex && dest <= activeWorkspaceIndex {
            activeWorkspaceIndex += 1
        }
    }
}
