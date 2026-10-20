import Cocoa

// MARK: - Workspace Recipes

extension MainWindowController {

    /// Opens `recipe` as a new workspace and switches to it.
    @discardableResult
    func runRecipe(_ recipe: Recipe, fallbackName: String) throws -> Workspace {
        let plan = try recipe.plan()
        let workspace = Workspace(
            folderPath: plan.folder, id: UUID(), splitTree: plan.tree, activePaneID: plan.firstPaneID)
        workspace.customName = recipe.name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        for (paneID, tabs) in plan.panes {
            let pane = Pane(id: paneID)
            for tab in tabs {
                pane.addTab(workingDirectory: tab.cwd)
                if let launch = tab.launch, let id = pane.tabs.last?.id { GhosttyView.pendingLaunch[id] = launch }
            }
            pane.setActiveTab(0)
            workspace.restorePane(pane)
        }
        presentNewWorkspace(workspace)
        return workspace
    }

    /// Loads and runs the recipe file at `path`, or explains why not.
    func runRecipe(atPath path: String) {
        do {
            try runRecipe(
                RecipeStore.load(path),
                fallbackName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        } catch {
            BooAlert.showError(title: "Cannot Run Recipe", message: error.localizedDescription, window: window)
        }
    }

    @objc func runRecipeAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        runRecipe(atPath: path)
    }

    @objc func saveWorkspaceAsRecipeAction(_ sender: Any?) {
        guard let workspace = activeWorkspace, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Workspace as Recipe"
        alert.informativeText =
            "Saves the layout and each tab's folder to ~/.boo/recipes. Commands stay empty: "
            + "each tab's last command is noted as lastCommand, so copy it into command to run it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = workspace.displayName
        alert.accessoryView = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.saveRecipe(of: workspace, as: name)
        }
        alert.window.makeFirstResponder(input)
    }

    private func saveRecipe(of workspace: Workspace, as name: String) {
        var lastCommands: [UUID: String] = [:]
        for pane in workspace.panes.values {
            for tab in pane.tabs {
                let view = workspacePaneViews[workspace.id]?[pane.id]?.terminalView(forTab: tab.id)
                if let command = view?.commandHistory.last?.command { lastCommands[tab.id] = command }
            }
        }
        let recipe = Recipe(workspace: workspace, name: name, lastCommands: lastCommands)
        do {
            let path = try RecipeStore.save(recipe, as: name)
            BooAlert.showTransient("Saved recipe \(abbreviatePath(path))")
        } catch {
            BooAlert.showError(title: "Cannot Save Recipe", message: error.localizedDescription, window: window)
        }
    }

    @objc func openRecipesFolderAction(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: BooPaths.recipesDir, isDirectory: true))
    }

    // MARK: IPC

    /// `run_recipe {name}` or `{path}`.
    func ipcRunRecipe(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        do {
            let path: String
            if let explicit = json["path"] as? String, !explicit.isEmpty {
                path = (explicit as NSString).expandingTildeInPath
            } else if let name = json["name"] as? String, !name.isEmpty {
                path = try RecipeStore.entry(named: name).path
            } else {
                reply(["ok": false, "error": "run_recipe needs name or path"])
                return
            }
            let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let workspace = try runRecipe(RecipeStore.load(path), fallbackName: fallback)
            reply(["ok": true, "workspace_id": workspace.id.uuidString, "name": workspace.displayName])
        } catch {
            reply(["ok": false, "error": error.localizedDescription])
        }
    }

    func ipcListRecipes(reply: @escaping ([String: Any]) -> Void) {
        let recipes = RecipeStore.list().map { entry -> [String: Any] in
            let folder = (try? RecipeStore.load(entry.path))?.folder
            return ["name": entry.name, "path": entry.path, "folder": folder ?? NSNull()]
        }
        reply(["ok": true, "recipes": recipes])
    }
}

/// Keeps File → Recipes in step with `~/.boo/recipes`: the recipe items above
/// the first separator are rebuilt whenever the menu opens.
@MainActor
final class RecipesMenu: NSObject, NSMenuDelegate {
    static let shared = RecipesMenu()

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Recipes")
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Save Workspace as Recipe…",
            action: #selector(MainWindowController.saveWorkspaceAsRecipeAction(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Open Recipes Folder", action: #selector(MainWindowController.openRecipesFolderAction(_:)),
            keyEquivalent: "")
        refresh(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh(menu) }

    func refresh(_ menu: NSMenu) {
        while let first = menu.items.first, !first.isSeparatorItem { menu.removeItem(first) }
        let entries = RecipeStore.list()
        if entries.isEmpty {
            let none = NSMenuItem(title: "No Recipes", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.insertItem(none, at: 0)
        }
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(
                title: entry.name, action: #selector(MainWindowController.runRecipeAction(_:)), keyEquivalent: "")
            item.representedObject = entry.path
            menu.insertItem(item, at: index)
        }
    }

    /// Palette rows, one per recipe, run in the active window.
    static func paletteItems() -> [PaletteItem] {
        RecipeStore.list().map { entry in
            PaletteItem(
                id: "recipe:\(entry.name)", kind: .recipe, title: entry.name,
                subtitle: (try? RecipeStore.load(entry.path)).map {
                    abbreviatePath(Recipe.expand($0.folder, relativeTo: nil))
                }
                    ?? "invalid recipe",
                perform: { WindowManager.shared.activeController?.runRecipe(atPath: entry.path) })
        }
    }
}
