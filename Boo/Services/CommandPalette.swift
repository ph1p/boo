import Cocoa

/// One row of the command palette.
@MainActor
struct PaletteItem: Identifiable {
    enum Kind: Int, CaseIterable {
        case action, workspace, tab, bookmark, theme, recipe

        var title: String {
            switch self {
            case .action: return "Actions"
            case .workspace: return "Workspaces"
            case .tab: return "Tabs"
            case .bookmark: return "Bookmarks"
            case .theme: return "Themes"
            case .recipe: return "Recipes"
            }
        }
    }

    /// Kind-prefixed ("action:Terminal/Split Right"); what recency remembers.
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String = ""
    var shortcut: String?
    var isEnabled = true
    let perform: @MainActor () -> Void
    /// Runs while the row is highlighted (themes preview live).
    var preview: (@MainActor () -> Void)?
}

/// What the user typed: an optional kind prefix and the search text.
struct PaletteQuery: Equatable {
    var kind: PaletteItem.Kind?
    var text: String

    init(kind: PaletteItem.Kind?, text: String) {
        self.kind = kind
        self.text = text
    }

    /// `>` actions, `@` workspaces, `#` tabs, `:` themes.
    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let prefixes: [Character: PaletteItem.Kind] = [">": .action, "@": .workspace, "#": .tab, ":": .theme]
        if let first = trimmed.first, let kind = prefixes[first] {
            self.kind = kind
            text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            kind = nil
            text = trimmed
        }
    }
}

/// Subsequence fuzzy matching, scored like most editors' quick-open: matches
/// at word starts and runs of consecutive characters count most.
enum FuzzyMatcher {
    /// nil when `query`'s characters don't all appear in `text` in order.
    static func score(_ query: String, _ text: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }
        let original = Array(text)
        let haystack = Array(text.lowercased())
        guard haystack.count == original.count else { return nil }  // case folding changed length
        var score = 0
        var index = 0
        var previousMatch = -2
        for (position, character) in haystack.enumerated() where index < needle.count {
            guard character == needle[index] else { continue }
            var points = 1
            if position == previousMatch + 1 { points += 8 }
            if position == 0 {
                points += 10
            } else {
                let before = original[position - 1]
                let isWordStart =
                    !before.isLetter && !before.isNumber || (before.isLowercase && original[position].isUppercase)
                if isWordStart { points += 6 }
            }
            score += points
            previousMatch = position
            index += 1
        }
        guard index == needle.count else { return nil }
        // Shorter texts win ties: "Split Right" over "Split Right and Focus".
        return score * 10 - min(haystack.count, 99)
    }
}

enum PaletteRanker {
    static let recentLimit = 50

    struct Group {
        let kind: PaletteItem.Kind
        let items: [PaletteItem]
    }

    /// Matching items grouped by kind. Within a group: fuzzy score plus a
    /// recency bonus. Groups follow their best item; with no text, the
    /// fixed kind order.
    @MainActor
    static func rank(_ items: [PaletteItem], query: PaletteQuery, recents: [String]) -> [Group] {
        let recentRank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var scored: [PaletteItem.Kind: [(item: PaletteItem, score: Int)]] = [:]
        for item in items where query.kind == nil || item.kind == query.kind {
            let haystack = item.subtitle.isEmpty ? item.title : "\(item.title) \(item.subtitle)"
            guard let match = FuzzyMatcher.score(query.text, item.title) ?? FuzzyMatcher.score(query.text, haystack)
            else { continue }
            let recency = recentRank[item.id].map { (recentLimit - $0) * 4 } ?? 0
            scored[item.kind, default: []].append((item, match + recency))
        }
        let groups = scored.map { kind, entries -> (Group, Int) in
            // Stable: equal scores keep the source order.
            let sorted = entries.enumerated().sorted {
                $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
            }.map(\.element)
            return (Group(kind: kind, items: sorted.map(\.item)), sorted.first?.score ?? 0)
        }
        if query.text.isEmpty {
            return groups.map(\.0).sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
        return groups.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.kind.rawValue < $1.0.kind.rawValue }.map(\.0)
    }

    /// `recents` with `id` moved to the front, capped at `recentLimit`.
    static func recording(_ id: String, in recents: [String]) -> [String] {
        Array(([id] + recents.filter { $0 != id }).prefix(recentLimit))
    }
}

/// Collects palette rows from the live app.
@MainActor
enum PaletteSources {
    static func items(menu: NSMenu? = NSApplication.shared.mainMenu) -> [PaletteItem] {
        actions(menu: menu) + workspaces() + tabs() + bookmarks() + themes() + extraSources.flatMap { $0() }
    }

    /// Further sources (recipes register here).
    static var extraSources: [@MainActor () -> [PaletteItem]] = []

    static func actions(menu: NSMenu?) -> [PaletteItem] {
        ActionRegistry.actions(in: menu).filter { !$0.isAlternate && $0.id != paletteActionID }.map { action in
            PaletteItem(
                id: "action:\(action.id)", kind: .action,
                title: action.path.dropFirst().joined(separator: " › "),
                subtitle: action.path[0], shortcut: action.shortcut, isEnabled: action.isEnabled,
                perform: { action.perform() })
        }
    }

    static let paletteActionID = "View/Command Palette…"

    static func workspaces() -> [PaletteItem] {
        let controllers = WindowManager.shared.controllers
        return controllers.enumerated().flatMap { windowIndex, controller in
            controller.appState.workspaces.map { workspace in
                PaletteItem(
                    id: "workspace:\(workspace.id.uuidString)", kind: .workspace, title: workspace.displayName,
                    subtitle: controllers.count > 1
                        ? "Window \(windowIndex + 1) · \(abbreviate(workspace.folderPath))"
                        : abbreviate(workspace.folderPath),
                    perform: { [weak controller] in
                        guard let controller,
                            let index = controller.appState.workspaces.firstIndex(where: { $0.id == workspace.id })
                        else { return }
                        controller.window?.makeKeyAndOrderFront(nil)
                        if index != controller.appState.activeWorkspaceIndex { controller.activateWorkspace(index) }
                    })
            }
        }
    }

    static func tabs() -> [PaletteItem] {
        WindowManager.shared.controllers.flatMap { controller in
            controller.appState.workspaces.flatMap { workspace in
                workspace.panes.values.flatMap { pane in
                    pane.tabs.enumerated().map { index, tab in
                        PaletteItem(
                            id: "tab:\(tab.id.uuidString)", kind: .tab, title: tab.title,
                            subtitle: "\(workspace.displayName) · \(abbreviate(tab.state.workingDirectory))",
                            perform: { [weak controller] in
                                guard let controller else { return }
                                controller.window?.makeKeyAndOrderFront(nil)
                                controller.focusActivity(workspaceID: workspace.id, paneID: pane.id, tabIndex: index)
                            })
                    }
                }
            }
        }
    }

    static func bookmarks() -> [PaletteItem] {
        BookmarkService.shared.bookmarks(for: "local").map { bookmark in
            PaletteItem(
                id: "bookmark:\(bookmark.id.uuidString)", kind: .bookmark, title: bookmark.name,
                subtitle: abbreviate(bookmark.path),
                perform: {
                    WindowManager.shared.activeController?.sendRawToActivePane(
                        "cd \(shellEscape(bookmark.path))\r")
                })
        }
    }

    static func themes() -> [PaletteItem] {
        let current = AppSettings.shared.themeName
        return AppSettings.shared.allThemes.map { theme in
            PaletteItem(
                id: "theme:\(theme.name)", kind: .theme, title: theme.name,
                subtitle: theme.name == current ? "current" : (theme.isDark ? "dark" : "light"),
                perform: {
                    AppSettings.shared.previewTheme = nil
                    AppSettings.shared.themeName = theme.name
                },
                preview: { AppSettings.shared.previewTheme = theme })
        }
    }

    private static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
