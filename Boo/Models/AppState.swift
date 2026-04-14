import Foundation

/// Global application state: manages workspaces.
final class AppState {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceIndex: Int = -1

    func nextGeneratedWorkspaceName() -> String {
        "Workspace \(workspaces.count + 1)"
    }

    var activeWorkspace: Workspace? {
        guard activeWorkspaceIndex >= 0, activeWorkspaceIndex < workspaces.count else { return nil }
        return workspaces[activeWorkspaceIndex]
    }

    func workspace(withID workspaceID: UUID) -> Workspace? {
        workspaces.first(where: { $0.id == workspaceID })
    }

    func workspaceContainingPane(_ paneID: UUID) -> Workspace? {
        workspaces.first(where: { $0.pane(for: paneID) != nil })
    }

    func indexOfWorkspace(containingPane paneID: UUID) -> Int? {
        workspaces.firstIndex(where: { $0.pane(for: paneID) != nil })
    }

    static func ensureUniquePaneIDsAcrossWorkspaces(_ workspaces: [Workspace]) {
        var seenPaneIDs = Set<UUID>()

        for workspace in workspaces {
            workspace.normalizePaneState()

            let leafIDs = workspace.splitTree.leafIDs
            var remappedPaneIDs: [UUID: UUID] = [:]

            for paneID in leafIDs where seenPaneIDs.contains(paneID) {
                var replacementID = UUID()
                while seenPaneIDs.contains(replacementID) || remappedPaneIDs.values.contains(replacementID) {
                    replacementID = UUID()
                }
                remappedPaneIDs[paneID] = replacementID
                NSLog(
                    "[WorkspaceSwitch] remapDuplicatePaneID workspace=\(workspace.id.uuidString) oldPane=\(paneID.uuidString) newPane=\(replacementID.uuidString)"
                )
            }

            workspace.remapPaneIDs(remappedPaneIDs)
            workspace.normalizePaneState()
            seenPaneIDs.formUnion(workspace.splitTree.leafIDs)
        }
    }

    func ensureUniquePaneIDsAcrossWorkspaces() {
        Self.ensureUniquePaneIDsAcrossWorkspaces(workspaces)
    }

    @discardableResult
    func replaceSplitTree(for workspaceID: UUID, with splitTree: SplitTree) -> Bool {
        guard let workspace = workspace(withID: workspaceID) else { return false }
        workspace.splitTree = splitTree
        workspace.normalizePaneState()
        return true
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

    func togglePin(at index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        workspaces[index].isPinned.toggle()

        if workspaces[index].isPinned {
            // Move to end of pinned group
            let pinnedEnd = workspaces.prefix(index).filter { $0.isPinned }.count
            if index != pinnedEnd {
                let ws = workspaces.remove(at: index)
                workspaces.insert(ws, at: pinnedEnd)
                // Fix active index
                if activeWorkspaceIndex == index {
                    activeWorkspaceIndex = pinnedEnd
                } else if activeWorkspaceIndex >= pinnedEnd && activeWorkspaceIndex < index {
                    activeWorkspaceIndex += 1
                }
            }
        } else {
            // Move to start of unpinned group (right after last pinned)
            let pinnedEnd = workspaces.filter { $0.isPinned }.count
            if index != pinnedEnd {
                let ws = workspaces.remove(at: index)
                workspaces.insert(ws, at: pinnedEnd)
                if activeWorkspaceIndex == index {
                    activeWorkspaceIndex = pinnedEnd
                } else if activeWorkspaceIndex > index && activeWorkspaceIndex <= pinnedEnd {
                    activeWorkspaceIndex -= 1
                }
            }
        }
    }

    func moveWorkspace(from source: Int, to destination: Int) {
        guard source != destination, source >= 0, source < workspaces.count,
            destination >= 0, destination <= workspaces.count
        else { return }
        guard !workspaces[source].isPinned else { return }
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
