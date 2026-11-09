import AppKit
import SwiftUI

/// One thing to do with an item or field. The same list feeds the click menu
/// (an `NSMenu` at the pointer) and the SwiftUI context menu. An action with
/// `children` is a submenu; its `run` is unused.
struct OPAction {
    let title: String
    let symbol: String
    var children: [[OPAction]] = []
    let run: @MainActor () -> Void

    static func submenu(_ title: String, symbol: String, _ children: [[OPAction]]) -> OPAction {
        OPAction(title: title, symbol: symbol, children: children) {}
    }
}

@MainActor
enum OPActions {
    static func forItem(_ item: OPItem) -> [[OPAction]] {
        let store = OnePasswordStore.shared
        var groups: [[OPAction]] = [
            [
                OPAction(title: "Copy Password", symbol: "doc.on.doc") { store.copy(.password, of: item) },
                OPAction(title: "Copy Username", symbol: "person") { store.copy(.username, of: item) },
                OPAction(title: "Copy One-Time Code", symbol: "clock") { store.copy(.otp, of: item) }
            ],
            [
                OPAction(title: "Type Password", symbol: "keyboard") { store.type(.password, of: item) },
                OPAction(title: "Type Password and Return", symbol: "return") {
                    store.type(.password, of: item, pressReturn: true)
                },
                OPAction(title: "Type One-Time Code", symbol: "keyboard.badge.ellipsis") {
                    store.type(.otp, of: item)
                }
            ],
            [
                OPAction(title: "Insert op:// Reference", symbol: "link") {
                    store.insertReference(.password, of: item)
                },
                OPAction(title: "Insert op read Command", symbol: "terminal") {
                    store.insertReference(.password, of: item, asRead: true)
                }
            ]
        ]
        var more: [OPAction] = []
        // Fields come from the cache: the row loads them before it opens the menu.
        if let fields = store.details[item.id], !fields.isEmpty {
            more.append(.submenu("Fields", symbol: "list.bullet", [fields.map { fieldMenu($0, of: item) }]))
        }
        if item.webURL != nil {
            more.append(OPAction(title: "Open in Browser", symbol: "safari") { store.openURL(of: item) })
        }
        if !more.isEmpty { groups.append(more) }
        return groups
    }

    /// A field as a submenu entry: "Section › label", plain values shown inline.
    private static func fieldMenu(_ field: OPField, of item: OPItem) -> OPAction {
        var title = field.displayLabel
        if let section = field.section { title = section + " › " + title }
        if !field.isConcealed, let value = field.secret, !value.isEmpty {
            title += ": " + (value.count > 40 ? String(value.prefix(40)) + "…" : value)
        }
        let symbol = field.isOTP ? "clock" : field.isConcealed ? "key" : "text.alignleft"
        return .submenu(title, symbol: symbol, forField(field, of: item))
    }

    static func forField(_ field: OPField, of item: OPItem) -> [[OPAction]] {
        let store = OnePasswordStore.shared
        var groups: [[OPAction]] = [
            [
                OPAction(title: "Copy \(field.displayLabel)", symbol: "doc.on.doc") { store.copy(field, of: item) },
                OPAction(title: "Type into Terminal", symbol: "keyboard") { store.type(field, of: item) },
                OPAction(title: "Type into Terminal and Return", symbol: "return") {
                    store.type(field, of: item, pressReturn: true)
                }
            ]
        ]
        if field.reference != nil {
            groups.append([
                OPAction(title: "Insert op:// Reference", symbol: "link") { store.insertReference(field, of: item) },
                OPAction(title: "Insert op read Command", symbol: "terminal") {
                    store.insertReference(field, of: item, asRead: true)
                }
            ])
        }
        return groups
    }

    /// Pops the actions up as a menu at `location` (screen coordinates).
    static func showMenu(_ groups: [[OPAction]], title: String? = nil, at location: NSPoint = NSEvent.mouseLocation) {
        let menu = makeMenu(groups)
        if let title {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.insertItem(header, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    private static func makeMenu(_ groups: [[OPAction]]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group {
                let item: NSMenuItem
                if action.children.isEmpty {
                    item = ClosureMenuItem(title: action.title) { action.run() }
                } else {
                    item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                    item.submenu = makeMenu(action.children)
                }
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// The same actions as a SwiftUI context menu.
struct OPActionMenu: View {
    let groups: [[OPAction]]

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(Array(group.enumerated()), id: \.offset) { _, action in
                if action.children.isEmpty {
                    Button {
                        action.run()
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                } else {
                    Menu {
                        OPActionMenu(groups: action.children)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }
        }
    }
}

// MARK: - Item Row

struct OnePasswordItemRow: View {
    let item: OPItem
    let showVault: Bool
    let fontScale: SidebarFontScale
    let t: Tokens
    @ObservedObject private var store = OnePasswordStore.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 13))
                .foregroundStyle(t.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(item.title)
                        .font(fontScale.font(.base).weight(.medium))
                        .foregroundStyle(t.text)
                        .lineLimit(1)
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                let subtitle = [item.detail, showVault ? item.vaultName : ""].filter { !$0.isEmpty }
                if !subtitle.isEmpty {
                    Text(subtitle.joined(separator: " · "))
                        .font(fontScale.font(.sm))
                        .foregroundStyle(t.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if store.loadingDetails.contains(item.id) {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(t.accent)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? t.hoverFill : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { openMenu() }
        .help("Click to copy, type or insert")
        .contextMenu { OPActionMenu(groups: OPActions.forItem(item)) }
    }

    /// Loads the fields first (once per item) so the menu can list them; the
    /// menu opens where the click was, even if the pointer moved meanwhile.
    private func openMenu() {
        let location = NSEvent.mouseLocation
        let item = item
        store.loadDetails(item) {
            OPActions.showMenu(OPActions.forItem(item), title: item.title, at: location)
        }
    }
}
