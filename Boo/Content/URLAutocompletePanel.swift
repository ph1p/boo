import Cocoa

/// Floating dropdown panel that shows URL history matches beneath the browser address bar.
final class URLAutocompletePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let title: String
        let url: URL
    }

    var onSelect: ((URL) -> Void)?

    private var panel: NSPanel?
    private var tableView: HoverTableView?
    private var items: [Item] = []
    private let rowHeight: CGFloat = 44

    override init() {
        super.init()
    }

    // MARK: - Public API

    func show(below anchor: NSView, items: [Item]) {
        self.items = items
        if panel == nil { buildPanel() }

        let theme = AppSettings.shared.theme
        tableView?.backgroundColor = theme.sidebarBg
        tableView?.reloadData()

        guard let panel = panel, let anchorWindow = anchor.window else { return }

        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        let screenFrame = anchorWindow.convertToScreen(anchorFrame)

        let panelWidth = screenFrame.width
        let minHeight = items.count > 1 ? rowHeight * 1.5 : rowHeight
        let panelHeight = min(max(CGFloat(items.count) * rowHeight, minHeight), rowHeight * 6)
        let origin = NSPoint(x: screenFrame.minX, y: screenFrame.minY - panelHeight - 6)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)), display: true)
        tableView?.enclosingScrollView?.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        if !panel.isVisible {
            anchorWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    /// Legacy overload kept for call-sites passing NSTextField directly.
    func show(below field: NSTextField, items: [Item]) {
        show(below: field as NSView, items: items)
    }

    func close() {
        guard let panel = panel else { return }
        tableView?.hoveredRow = -1
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Handle keyboard navigation while focus stays in the URL bar. Returns true if consumed.
    func handleKeyDown(with event: NSEvent) -> Bool {
        guard panel?.isVisible == true, let tv = tableView else { return false }
        let count = items.count
        guard count > 0 else { return false }

        switch event.keyCode {
        case 125:  // down arrow
            let next = min(tv.selectedRow + 1, count - 1)
            tv.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tv.scrollRowToVisible(next)
            return true
        case 126:  // up arrow
            let prev = tv.selectedRow - 1
            if prev < 0 {
                tv.deselectAll(nil)
            } else {
                tv.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                tv.scrollRowToVisible(prev)
            }
            return true
        case 36, 76:  // return / numpad enter
            let row = tv.selectedRow
            guard row >= 0, row < count else { return false }
            close()
            onSelect?(items[row].url)
            return true
        case 53:  // escape
            close()
            return true
        default:
            return false
        }
    }

    // MARK: - Build

    private func buildPanel() {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu

        let theme = AppSettings.shared.theme

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true

        let tv = HoverTableView()
        tv.headerView = nil
        tv.backgroundColor = theme.sidebarBg
        tv.rowHeight = rowHeight
        tv.intercellSpacing = .zero
        tv.gridStyleMask = []
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.action = #selector(didClick(_:))
        tv.doubleAction = #selector(didClick(_:))
        tv.selectionHighlightStyle = .regular

        let col = NSTableColumn(identifier: .init("url"))
        col.isEditable = false
        tv.addTableColumn(col)

        scroll.documentView = tv
        p.contentView = scroll

        panel = p
        tableView = tv
    }

    // MARK: - Actions

    @objc private func didClick(_ sender: Any?) {
        guard let tv = tableView else { return }
        let row = tv.clickedRow
        guard row >= 0, row < items.count else { return }
        close()
        onSelect?(items[row].url)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let theme = AppSettings.shared.theme
        let id = NSUserInterfaceItemIdentifier("autocomplete-cell")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            icon.tag = 3

            let title = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.tag = 1

            let subtitle = NSTextField(labelWithString: "")
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.font = .systemFont(ofSize: 10.5)
            subtitle.lineBreakMode = .byTruncatingMiddle
            subtitle.tag = 2

            cell.addSubview(icon)
            cell.addSubview(title)
            cell.addSubview(subtitle)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),

                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),

                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
            ])
        }

        (cell.viewWithTag(1) as? NSTextField)?.stringValue = item.title.isEmpty ? item.url.host ?? "" : item.title
        (cell.viewWithTag(1) as? NSTextField)?.textColor = theme.chromeText
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = item.url.absoluteString
        (cell.viewWithTag(2) as? NSTextField)?.textColor = theme.chromeMuted

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .light)
        let img = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        if let iv = cell.viewWithTag(3) as? NSImageView {
            iv.image = img
            iv.contentTintColor = theme.chromeMuted
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedRowView(theme: AppSettings.shared.theme)
    }
}

// MARK: - HoverTableView

/// NSTableView subclass that tracks mouse position and propagates the hovered row index
/// to each ThemedRowView so it can draw a hover highlight independently of selection.
final class HoverTableView: NSTableView {
    var hoveredRow: Int = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            refreshRow(oldValue)
            refreshRow(hoveredRow)
        }
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredRow = row(at: pt)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = -1
    }

    private func refreshRow(_ index: Int) {
        guard index >= 0 else { return }
        if let rv = rowView(atRow: index, makeIfNecessary: false) as? ThemedRowView {
            rv.isHovered = index == hoveredRow
        }
    }
}

// MARK: - ThemedRowView

/// Custom row view that draws hover/selection using theme colors instead of system blue.
private final class ThemedRowView: NSTableRowView {
    var theme: TerminalTheme
    var isHovered: Bool = false { didSet { needsDisplay = true } }

    init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        theme.chromeMuted.withAlphaComponent(0.18).setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isHovered && !isSelected {
            theme.chromeMuted.withAlphaComponent(0.09).setFill()
        } else {
            theme.sidebarBg.setFill()
        }
        bounds.fill()
    }
}
