import Cocoa

/// Floating dropdown panel that shows URL history matches beneath the browser address bar.
final class URLAutocompletePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let title: String
        let url: URL
    }

    var onSelect: ((URL) -> Void)?

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var items: [Item] = []
    private let rowHeight: CGFloat = 36

    override init() {
        super.init()
    }

    func show(below field: NSTextField, items: [Item]) {
        self.items = items
        if panel == nil { buildPanel() }
        tableView?.reloadData()

        guard let panel = panel,
              let fieldWindow = field.window,
              let tableView = tableView
        else { return }

        let fieldFrame = field.convert(field.bounds, to: nil)
        let screenFrame = fieldWindow.convertToScreen(fieldFrame)

        let panelWidth = max(fieldFrame.width, 300)
        let panelHeight = min(CGFloat(items.count) * rowHeight + 2, rowHeight * 6 + 2)
        let origin = NSPoint(
            x: screenFrame.minX,
            y: screenFrame.minY - panelHeight
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)), display: true)
        tableView.enclosingScrollView?.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        if !panel.isVisible {
            fieldWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func close() {
        guard let panel = panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

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

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true

        let tv = NSTableView()
        tv.headerView = nil
        tv.backgroundColor = NSColor(named: "TableBackground") ?? .windowBackgroundColor
        tv.rowHeight = rowHeight
        tv.intercellSpacing = .zero
        tv.gridStyleMask = []
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.doubleAction = #selector(didDoubleClick(_:))

        let col = NSTableColumn(identifier: .init("url"))
        col.isEditable = false
        tv.addTableColumn(col)
        tv.selectionHighlightStyle = .regular

        scroll.documentView = tv
        p.contentView = scroll

        panel = p
        tableView = tv

        // Single click selects
        tv.action = #selector(didClick(_:))
    }

    @objc private func didClick(_ sender: Any?) {
        guard let tv = tableView else { return }
        let row = tv.clickedRow
        guard row >= 0, row < items.count else { return }
        close()
        onSelect?(items[row].url)
    }

    @objc private func didDoubleClick(_ sender: Any?) {
        didClick(sender)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let id = NSUserInterfaceItemIdentifier("autocomplete-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let title = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.tag = 1

            let subtitle = NSTextField(labelWithString: "")
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.font = .systemFont(ofSize: 10)
            subtitle.textColor = .secondaryLabelColor
            subtitle.lineBreakMode = .byTruncatingMiddle
            subtitle.tag = 2

            cell.addSubview(title)
            cell.addSubview(subtitle)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),

                subtitle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            ])
        }

        (cell.viewWithTag(1) as? NSTextField)?.stringValue = item.title
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = item.url.absoluteString
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        return view
    }
}
