import Cocoa

// MARK: - Close Confirmation

extension MainWindowController {
    struct UnsavedEditorLocation {
        let workspaceIndex: Int
        let paneID: UUID
        let tabID: UUID
        let tabIndex: Int
        let editor: EditorContentView
    }

    func unsavedEditorLocation(
        workspaceIndex: Int? = nil,
        paneID: UUID? = nil,
        tabIndex: Int? = nil
    ) -> UnsavedEditorLocation? {
        let workspaceIndices: [Int]
        if let workspaceIndex {
            workspaceIndices = [workspaceIndex]
        } else {
            let activeIndex = appState.activeWorkspaceIndex
            workspaceIndices = [activeIndex] + appState.workspaces.indices.filter { $0 != activeIndex }
        }

        for currentWorkspaceIndex in workspaceIndices
        where currentWorkspaceIndex >= 0 && currentWorkspaceIndex < appState.workspaces.count {
            let workspace = appState.workspaces[currentWorkspaceIndex]
            let paneIDs =
                paneID.map { [$0] } ?? [workspace.activePaneID]
                + workspace.panes.keys.filter { $0 != workspace.activePaneID }

            for currentPaneID in paneIDs {
                guard let pane = workspace.pane(for: currentPaneID),
                    let paneView = workspacePaneViews[workspace.id]?[currentPaneID]
                else { continue }

                let tabIndices = tabIndex.map { [$0] } ?? Array(pane.tabs.indices)
                for currentTabIndex in tabIndices where currentTabIndex >= 0 && currentTabIndex < pane.tabs.count {
                    let tab = pane.tabs[currentTabIndex]
                    guard tab.contentType == .editor,
                        let editor = paneView.editorView(for: tab.id),
                        editor.hasUnsavedChanges
                    else { continue }

                    return UnsavedEditorLocation(
                        workspaceIndex: currentWorkspaceIndex,
                        paneID: currentPaneID,
                        tabID: tab.id,
                        tabIndex: currentTabIndex,
                        editor: editor
                    )
                }
            }
        }

        return nil
    }

    func confirmUnsavedEditorClose(
        _ location: UnsavedEditorLocation,
        proceed: @escaping () -> Void
    ) {
        guard let window else {
            proceed()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(location.editor.fileDisplayName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                location.editor.saveFile { success in
                    guard success else {
                        BooAlert.showError(
                            title: "Could Not Save File",
                            message: "Boo couldn't save \"\(location.editor.fileDisplayName)\".",
                            window: self.window
                        )
                        return
                    }
                    self.saveSession()
                    proceed()
                }
            case .alertSecondButtonReturn:
                proceed()
            default:
                break
            }
        }
    }

    func closeTabAfterConfirmation(
        paneID: UUID,
        tabIndex: Int,
        proceed: @escaping () -> Void
    ) {
        if let location = unsavedEditorLocation(
            workspaceIndex: appState.activeWorkspaceIndex,
            paneID: paneID,
            tabIndex: tabIndex
        ) {
            confirmUnsavedEditorClose(location, proceed: proceed)
        } else if let tabs = activeWorkspace?.pane(for: paneID)?.tabs, tabs.indices.contains(tabIndex),
            tabs[tabIndex].contentType == .browser
        {
            confirmBrowserTabClose(title: tabs[tabIndex].title, proceed: proceed)
        } else {
            proceed()
        }
    }

    /// Browser tabs ask before closing: a page can hold form input or a login
    /// flow that reloading won't bring back. "Don't ask again" turns the
    /// global setting off (Settings → Browser turns it back on).
    func confirmBrowserTabClose(title: String, proceed: @escaping () -> Void) {
        guard AppSettings.shared.browserConfirmClose, let window else { return proceed() }
        let alert = NSAlert()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = name.isEmpty ? "Close this browser tab?" : "Close “\(name)”?"
        alert.informativeText = "The page will be closed. Anything entered on it is lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                AppSettings.shared.browserConfirmClose = false
            }
            proceed()
        }
    }
}
