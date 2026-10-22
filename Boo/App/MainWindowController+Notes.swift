import Cocoa

extension MainWindowController {
    /// Appends the active terminal's selection, or else its last command and
    /// output, to the active workspace's note.
    @objc func appendSelectionToNoteAction(_ sender: Any?) {
        guard let view = activeGhosttyView, let workspace = activeWorkspace,
            let (source, text) = view.selectionOrLastOutput()
        else {
            NSSound.beep()
            return
        }
        var command: String?
        if case .output(let ran, _) = source { command = ran }
        let cwd = workspace.pane(for: workspace.activePaneID)?.activeTab.map { tab in
            tab.remoteSession != nil ? (tab.remoteWorkingDirectory ?? tab.workingDirectory) : tab.workingDirectory
        }
        let path = NotesStore.path(folderPath: workspace.folderPath, workspaceID: workspace.id)
        let title = workspace.displayName
        NotesStore.flush(path) {
            guard NotesStore.append(text, command: command, cwd: cwd, to: path) else {
                BooAlert.showTransient("Could not write the note")
                return
            }
            NotesStore.rememberTitle(title, for: path)
            NotificationCenter.default.post(name: .noteAppended, object: path)
            BooAlert.showTransient("Appended to \(title) note")
        }
    }
}
