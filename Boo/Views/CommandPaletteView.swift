import Cocoa
import SwiftUI

extension MainWindowController {
    @objc func showCommandPaletteAction(_ sender: Any?) {
        guard let window else { return }
        CommandPaletteController.shared.toggle(over: window)
    }
}

/// The ⇧⌘P palette: a borderless child panel at the top of the window. Rows
/// are snapshotted on open, so action enablement reflects the window it
/// opened over. ↑/↓ move, ↩ runs, ⎋ closes (and reverts a theme preview).
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = CommandPaletteController()

    static let width: CGFloat = 580
    static let fieldHeight: CGFloat = 46
    static let maxListHeight: CGFloat = 380

    let model = CommandPaletteModel()
    private var panel: CommandPalettePanel?
    private weak var parentWindow: NSWindow?
    private let field = NSTextField()
    private let separator = NSView()
    private weak var root: NSView?
    private var closing = false

    var isOpen: Bool { panel != nil }

    func toggle(over window: NSWindow) {
        if isOpen {
            dismiss()
        } else {
            open(over: window)
        }
    }

    func open(over window: NSWindow, query: String = "") {
        dismiss()
        parentWindow = window
        model.load(items: PaletteSources.items(), recents: AppSettings.shared.paletteRecents)
        model.onAccept = { [weak self] index in self?.accept(index) }
        model.onSelectionChanged = { [weak self] in self?.previewSelection() }

        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = makeContent()
        self.panel = panel

        field.stringValue = query
        model.query = query
        window.addChildWindow(panel, ordered: .above)
        layout()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        previewSelection()
    }

    /// Closes without running anything; a theme preview reverts.
    func dismiss() {
        guard let panel, !closing else { return }
        closing = true
        if AppSettings.shared.previewTheme != nil { AppSettings.shared.previewTheme = nil }
        close(panel)
        closing = false
    }

    private func close(_ panel: NSPanel) {
        self.panel = nil
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    private func accept(_ index: Int) {
        guard let panel, let item = model.item(at: index) else { return }
        guard item.isEnabled else {
            NSSound.beep()
            return
        }
        AppSettings.shared.paletteRecents = PaletteRanker.recording(item.id, in: AppSettings.shared.paletteRecents)
        // The window takes key back first so responder-chain actions reach it.
        closing = true
        close(panel)
        closing = false
        if item.kind != .theme, AppSettings.shared.previewTheme != nil { AppSettings.shared.previewTheme = nil }
        item.perform()
    }

    private func previewSelection() {
        let item = model.item(at: model.selection)
        if let preview = item?.preview {
            preview()
        } else if AppSettings.shared.previewTheme != nil {
            AppSettings.shared.previewTheme = nil
        }
        applyTheme()
    }

    /// The chrome follows a previewed theme, like the rest of the window.
    private func applyTheme() {
        let theme = AppSettings.shared.theme
        root?.layer?.backgroundColor = theme.cardBg.cgColor
        root?.layer?.borderColor = theme.separator.cgColor
        separator.layer?.backgroundColor = theme.separator.cgColor
        field.textColor = theme.chromeText
        field.placeholderAttributedString = NSAttributedString(
            string: "Search commands, workspaces, tabs, themes   > @ # :",
            attributes: [.foregroundColor: theme.textTertiary, .font: NSFont.systemFont(ofSize: 15)])
    }

    private func makeContent() -> NSView {
        let root = NSView()
        self.root = root
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.cell?.usesSingleLineMode = true

        let list = NSHostingView(rootView: CommandPaletteList(model: model))
        separator.wantsLayer = true

        for view in [field, separator, list] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Self.fieldHeight / 2),
            separator.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        applyTheme()
        return root
    }

    /// Centered near the top of the parent's content area, as tall as the rows need.
    private func layout() {
        guard let panel, let parent = parentWindow else { return }
        let listHeight = min(model.contentHeight, Self.maxListHeight)
        let height = Self.fieldHeight + (listHeight > 0 ? listHeight + 1 : 0)
        let content = parent.contentLayoutRect
        let top = parent.frame.minY + content.maxY - 60
        let x = parent.frame.minX + content.midX - Self.width / 2
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        model.query = field.stringValue
        layout()
        previewSelection()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.move(-1)
        case #selector(NSResponder.moveDown(_:)):
            model.move(1)
        case #selector(NSResponder.insertNewline(_:)):
            accept(model.selection)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    // MARK: - NSWindowDelegate

    /// Clicking elsewhere closes the palette.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

/// Borderless panels refuse key status by default; the search field needs it.
final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandPaletteModel: ObservableObject {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22

    @Published private(set) var groups: [PaletteRanker.Group] = []
    @Published private(set) var selection = 0
    @Published private(set) var theme = AppSettings.shared.theme
    var query = "" {
        didSet { rerank() }
    }
    var onAccept: ((Int) -> Void)?
    var onSelectionChanged: (() -> Void)?

    private var items: [PaletteItem] = []
    private var recents: [String] = []
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.theme = AppSettings.shared.theme }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load(items: [PaletteItem], recents: [String]) {
        self.items = items
        self.recents = recents
        theme = AppSettings.shared.theme
        query = ""
    }

    var flatItems: [PaletteItem] { groups.flatMap(\.items) }

    func item(at index: Int) -> PaletteItem? {
        let flat = flatItems
        return flat.indices.contains(index) ? flat[index] : nil
    }

    var contentHeight: CGFloat {
        guard !groups.isEmpty else { return 0 }
        return CGFloat(groups.count) * Self.headerHeight + CGFloat(flatItems.count) * Self.rowHeight + 8
    }

    func move(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
        onSelectionChanged?()
    }

    func select(_ index: Int) {
        guard index != selection else { return }
        selection = index
        onSelectionChanged?()
    }

    func accept(_ index: Int) {
        onAccept?(index)
    }

    private func rerank() {
        groups = PaletteRanker.rank(items, query: PaletteQuery(query), recents: recents)
        selection = 0
    }
}

struct CommandPaletteList: View {
    @ObservedObject var model: CommandPaletteModel

    var body: some View {
        let theme = model.theme
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(), id: \.offset) { row in
                        switch row.element {
                        case .header(let title):
                            Text(title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: theme.textTertiary))
                                .padding(.horizontal, 14)
                                .frame(height: CommandPaletteModel.headerHeight, alignment: .bottomLeading)
                        case .item(let index, let item):
                            itemRow(item, index: index, theme: theme).id(index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selection) { _, index in proxy.scrollTo(index) }
        }
    }

    private enum Row {
        case header(String)
        case item(Int, PaletteItem)
    }

    private func rows() -> [(offset: Int, element: Row)] {
        var rows: [Row] = []
        var index = 0
        for group in model.groups {
            rows.append(.header(group.kind.title))
            for item in group.items {
                rows.append(.item(index, item))
                index += 1
            }
        }
        return Array(rows.enumerated()).map { ($0.offset, $0.element) }
    }

    private func itemRow(_ item: PaletteItem, index: Int, theme: TerminalTheme) -> some View {
        let selected = index == model.selection
        let primary = item.isEnabled ? theme.chromeText : theme.textTertiary
        return HStack(spacing: 8) {
            Text(item.title).lineLimit(1).truncationMode(.tail)
                .foregroundColor(Color(nsColor: primary))
            if !item.subtitle.isEmpty {
                Text(item.subtitle).lineLimit(1).truncationMode(.middle)
                    .foregroundColor(Color(nsColor: theme.textTertiary))
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.system(size: 11, design: .rounded))
                    .foregroundColor(Color(nsColor: item.isEnabled ? theme.textSecondary : theme.textTertiary))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: CommandPaletteModel.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: selected ? theme.accentSelectionFill : .clear))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(index)
            model.accept(index)
        }
    }
}
