import Foundation

/// A tab within a workspace: owns a split tree and terminal sessions.
final class TerminalTab {
    let id: UUID
    let workingDirectory: String

    var title: String { (workingDirectory as NSString).lastPathComponent }

    private(set) var splitTree: SplitTree
    private(set) var sessions: [UUID: TerminalSession] = [:]
    var activePaneID: UUID

    init(workingDirectory: String) {
        self.id = UUID()
        self.workingDirectory = workingDirectory
        let rootID = UUID()
        self.splitTree = .leaf(id: rootID)
        self.activePaneID = rootID
    }

    func createSession(for paneID: UUID, terminalView: TerminalView, onDirectoryChanged: ((String) -> Void)?) -> TerminalSession {
        let cwd = sessions[activePaneID]?.currentDirectory ?? workingDirectory

        let session = TerminalSession(
            terminalView: terminalView,
            workingDirectory: cwd
        )

        session.onDirectoryChanged = { [weak self] newPath in
            guard let self = self else { return }
            if paneID == self.activePaneID {
                onDirectoryChanged?(newPath)
            }
        }

        sessions[paneID] = session
        return session
    }

    func didActivatePane(_ paneID: UUID, onDirectoryChanged: ((String) -> Void)?) {
        activePaneID = paneID
        if let session = sessions[paneID] {
            onDirectoryChanged?(session.currentDirectory)
        }
    }

    @discardableResult
    func splitActivePane(direction: SplitTree.SplitDirection) -> UUID {
        let (newTree, newID) = splitTree.splitting(leafID: activePaneID, direction: direction)
        splitTree = newTree
        return newID
    }

    func closePane(_ paneID: UUID) -> Bool {
        sessions[paneID]?.stop()
        sessions.removeValue(forKey: paneID)

        if let newTree = splitTree.removing(leafID: paneID) {
            splitTree = newTree
            if activePaneID == paneID {
                activePaneID = splitTree.leafIDs.first ?? UUID()
            }
            return true
        }
        return false
    }

    func stopAll() {
        for (_, session) in sessions {
            session.stop()
        }
        sessions.removeAll()
    }
}
