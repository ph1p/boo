import Cocoa
import SwiftUI

/// Where the ⌃R search was opened: drives the chips and the same-directory boost.
struct HistorySearchContext: Equatable {
    var workspaceID: UUID?
    /// The ssh/container target; nil for a local shell.
    var host: String?
    var cwd: String
}

/// ⌃R history search: a borderless child panel over the terminal it was
/// opened from. ↩ puts the command on the prompt, ⌘↩ runs it, ⌘C copies it,
/// ⌘⌫ forgets it, ⌘1–⌘4 toggle the chips, ⌃R/⌃S move like the shell's own.
@MainActor
final class HistorySearchController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = HistorySearchController()

    static let maxWidth: CGFloat = 680
    static let fieldHeight: CGFloat = 42
    static let chipsHeight: CGFloat = 30
    static let footerHeight: CGFloat = 24

    let model = HistorySearchModel()
    private var panel: CommandPalettePanel?
    private weak var terminal: GhosttyView?
    private let field = NSTextField()
    private weak var root: NSView?
    private var keyMonitor: Any?
    private var closing = false

    var isOpen: Bool { panel != nil }

    func open(for terminal: GhosttyView, context: HistorySearchContext) {
        dismiss()
        guard let window = terminal.window else { return }
        self.terminal = terminal
        model.reset(context: context)
        model.onLayout = { [weak self] in self?.layout() }
        model.onAccept = { [weak self] index, run in self?.accept(index, run: run) }

        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: Self.fieldHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = makeContent()
        self.panel = panel

        field.stringValue = ""
        window.addChildWindow(panel, ordered: .above)
        layout()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        installKeyMonitor()
    }

    func dismiss() {
        guard let panel, !closing else { return }
        closing = true
        self.panel = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.cancel()
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        if let terminal { terminal.window?.makeFirstResponder(terminal) }
        closing = false
    }

    private func accept(_ index: Int, run: Bool) {
        guard let entry = model.entry(at: index) else { return }
        let terminal = self.terminal
        dismiss()
        terminal?.replacePromptLine(with: entry.command, run: run)
    }

    private func copySelection() {
        guard let entry = model.entry(at: model.selection) else { return }
        PluginActions.copyToPasteboard(entry.command)
        dismiss()
    }

    /// Keys the text field doesn't bind: ⌘↩, ⌘C with no field selection, ⌘⌫,
    /// ⌘1–4 and ⌃R/⌃S.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (mods, event.keyCode) {
            case (.command, 0x24), (.command, 0x4C):  // Return, keypad Enter
                self.model.accept(self.model.selection, run: true)
            case (.command, 0x08):  // C
                if let editor = panel.fieldEditor(false, for: self.field) as? NSTextView,
                    editor.selectedRange().length > 0
                {
                    return event
                }
                self.copySelection()
            case (.command, 0x33):  // Delete
                self.model.deleteSelected()
            case (.command, 0x12): self.model.toggle(.workspace)  // 1
            case (.command, 0x13): self.model.toggle(.failed)  // 2
            case (.command, 0x14): self.model.toggle(.host)  // 3
            case (.command, 0x15): self.model.toggle(.directory)  // 4
            case (.control, 0x0F): self.model.move(1)  // ⌃R: older
            case (.control, 0x01): self.model.move(-1)  // ⌃S: newer
            default:
                return event
            }
            return nil
        }
    }

    private func makeContent() -> NSView {
        let root = NSView()
        self.root = root
        let theme = AppSettings.shared.theme
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.backgroundColor = theme.cardBg.cgColor
        root.layer?.borderColor = theme.separator.cgColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.textColor = theme.chromeText
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(
            string: "Search history",
            attributes: [.foregroundColor: theme.textTertiary, .font: NSFont.systemFont(ofSize: 14)])

        let body = NSHostingView(rootView: HistorySearchBody(model: model))
        for view in [field, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Self.fieldHeight / 2),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.fieldHeight),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }

    /// Centered near the top of the terminal, as tall as the rows need.
    private func layout() {
        guard let panel, let terminal, let window = terminal.window else { return }
        let frame = window.convertToScreen(terminal.convert(terminal.bounds, to: nil))
        let width = min(Self.maxWidth, max(320, frame.width - 24))
        let maxList = max(HistorySearchModel.rowHeight * 3, frame.height - 100)
        let listHeight = min(model.listHeight, maxList)
        let height = Self.fieldHeight + Self.chipsHeight + listHeight + Self.footerHeight
        let top = frame.maxY - 16
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        model.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): model.move(-1)
        case #selector(NSResponder.moveDown(_:)): model.move(1)
        case #selector(NSResponder.insertNewline(_:)): model.accept(model.selection, run: false)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

@MainActor
final class HistorySearchModel: ObservableObject {
    static let rowHeight: CGFloat = 30

    enum Chip: CaseIterable {
        case workspace, failed, host, directory
    }

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var selection = 0
    @Published private(set) var chips: Set<Chip> = []
    @Published private(set) var context = HistorySearchContext(cwd: "")
    @Published private(set) var loaded = false
    var text = "" {
        didSet { if text != oldValue { refresh() } }
    }
    var onLayout: (() -> Void)?
    var onAccept: ((Int, Bool) -> Void)?

    private let store: HistoryStore
    private var task: Task<Void, Never>?

    init(store: HistoryStore = .shared) {
        self.store = store
    }

    var listHeight: CGFloat {
        entries.isEmpty ? 44 : CGFloat(entries.count) * Self.rowHeight + 8
    }

    func reset(context: HistorySearchContext) {
        self.context = context
        chips = []
        text = ""
        entries = []
        loaded = false
        refresh()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    var filter: HistoryFilter {
        var f = HistoryFilter(text: text, preferredCwd: context.cwd)
        if chips.contains(.workspace) { f.workspaceID = context.workspaceID }
        if chips.contains(.failed) { f.failedOnly = true }
        if chips.contains(.host) { f.host = .some(context.host) }
        if chips.contains(.directory) { f.cwd = context.cwd }
        return f
    }

    func toggle(_ chip: Chip) {
        if chips.remove(chip) == nil { chips.insert(chip) }
        refresh()
    }

    func entry(at index: Int) -> HistoryEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = max(0, min(entries.count - 1, selection + delta))
    }

    func select(_ index: Int) {
        selection = index
    }

    func accept(_ index: Int, run: Bool) {
        onAccept?(index, run)
    }

    func deleteSelected() {
        guard let entry = entry(at: selection) else { return }
        entries.remove(at: selection)
        selection = min(selection, max(0, entries.count - 1))
        onLayout?()
        store.delete(command: entry.command)
    }

    private func refresh() {
        task?.cancel()
        let filter = self.filter
        let store = self.store
        task = Task { [weak self] in
            // Coalesces fast typing; the first open runs right away.
            if self?.loaded == true { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let results = await store.search(filter, limit: 100)
            guard !Task.isCancelled, let self else { return }
            self.entries = results
            self.selection = 0
            self.loaded = true
            self.onLayout?()
        }
    }
}

struct HistorySearchBody: View {
    @ObservedObject var model: HistorySearchModel

    var body: some View {
        let theme = AppSettings.shared.theme
        VStack(spacing: 0) {
            separator(theme)
            chips(theme)
                .frame(height: HistorySearchController.chipsHeight)
            separator(theme)
            list(theme)
            separator(theme)
            footer(theme)
                .frame(height: HistorySearchController.footerHeight)
        }
    }

    private func separator(_ theme: TerminalTheme) -> some View {
        Rectangle().fill(Color(nsColor: theme.separator)).frame(height: 1)
    }

    private func chips(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 6) {
            chip(.workspace, "This workspace", key: "⌘1", theme: theme)
            chip(.failed, "Failed", key: "⌘2", theme: theme)
            chip(.host, model.context.host ?? "Local", key: "⌘3", theme: theme)
            chip(
                .directory, (model.context.cwd as NSString).abbreviatingWithTildeInPath, key: "⌘4",
                theme: theme)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func chip(
        _ chip: HistorySearchModel.Chip, _ title: String, key: String, theme: TerminalTheme
    )
        -> some View
    {
        let on = model.chips.contains(chip)
        return Button {
            model.toggle(chip)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
                .foregroundColor(Color(nsColor: on ? theme.chromeText : theme.textSecondary))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(Color(nsColor: on ? theme.accentSelectionFill : .clear))
                )
                .overlay(Capsule().stroke(Color(nsColor: theme.separator), lineWidth: on ? 0 : 1))
        }
        .buttonStyle(.plain)
        .help("\(title) (\(key))")
        .frame(maxWidth: 220)
    }

    @ViewBuilder
    private func list(_ theme: TerminalTheme) -> some View {
        if model.entries.isEmpty {
            Text(model.loaded ? (model.text.isEmpty ? "No history yet" : "No matches") : "")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: theme.textTertiary))
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, index: index, theme: theme).id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.selection) { _, index in proxy.scrollTo(index) }
            }
        }
    }

    private func row(_ entry: HistoryEntry, index: Int, theme: TerminalTheme) -> some View {
        let selected = index == model.selection
        return HStack(spacing: 8) {
            Text(entry.command.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
                .foregroundColor(Color(nsColor: theme.chromeText))
            Spacer(minLength: 8)
            if entry.failed, let code = entry.exitCode {
                Text("✗ \(code)").font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: theme.error))
            }
            if entry.count > 1 {
                Text("×\(entry.count)").font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: theme.textTertiary))
            }
            if entry.cwd != model.context.cwd {
                Text((entry.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5)).lineLimit(1).truncationMode(.head)
                    .foregroundColor(Color(nsColor: theme.textTertiary))
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            Text(formatCompactAge(entry.startedAt))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(Color(nsColor: theme.textTertiary))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: HistorySearchModel.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: selected ? theme.accentSelectionFill : .clear))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.accept(index, run: false) }
        .onTapGesture { model.select(index) }
    }

    private func footer(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 14) {
            Text("↩ insert")
            Text("⌘↩ run")
            Text("⌘C copy")
            Text("⌘⌫ forget")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundColor(Color(nsColor: theme.textTertiary))
        .padding(.horizontal, 12)
    }
}
