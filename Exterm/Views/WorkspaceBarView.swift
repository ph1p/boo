import Cocoa

protocol WorkspaceBarViewDelegate: AnyObject {
    func workspaceBar(_ bar: WorkspaceBarView, didSelectAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, didCloseAt index: Int)
}

class WorkspaceBarView: NSView {
    weak var delegate: WorkspaceBarViewDelegate?

    struct Item {
        let name: String
        let path: String
    }

    private(set) var items: [Item] = []
    private(set) var selectedIndex: Int = -1

    private let barHeight: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func setItems(_ items: [Item], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background — deepest layer
        ctx.setFillColor(CGColor(red: 13/255, green: 13/255, blue: 15/255, alpha: 1))
        ctx.fill(bounds)

        // Bottom separator
        ctx.setFillColor(CGColor(red: 42/255, green: 42/255, blue: 47/255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))

        var x: CGFloat = 72 // Clear traffic lights

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            let title = item.name as NSString

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular),
                .foregroundColor: isSelected
                    ? NSColor(red: 228/255, green: 228/255, blue: 232/255, alpha: 1)
                    : NSColor(red: 86/255, green: 86/255, blue: 94/255, alpha: 1)
            ]
            let titleSize = title.size(withAttributes: attrs)
            let pillWidth = titleSize.width + 36
            let pillHeight: CGFloat = 20
            let pillY = (barHeight - pillHeight) / 2

            if isSelected {
                let pillRect = CGRect(x: x, y: pillY, width: pillWidth, height: pillHeight)
                ctx.setFillColor(CGColor(red: 35/255, green: 35/255, blue: 39/255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }

            let textX = x + 10
            let textY = (barHeight - titleSize.height) / 2
            title.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            // Close button
            let closeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(red: 86/255, green: 86/255, blue: 94/255, alpha: 1)
            ]
            let closeStr = "\u{2715}" as NSString
            let closeSize = closeStr.size(withAttributes: closeAttrs)
            closeStr.draw(
                at: NSPoint(x: x + pillWidth - closeSize.width - 8, y: (barHeight - closeSize.height) / 2),
                withAttributes: closeAttrs
            )

            x += pillWidth + 6
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var x: CGFloat = 72

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
            ]
            let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
            let pillWidth = titleWidth + 36

            if point.x >= x && point.x < x + pillWidth {
                if point.x > x + pillWidth - 20 {
                    delegate?.workspaceBar(self, didCloseAt: i)
                } else {
                    delegate?.workspaceBar(self, didSelectAt: i)
                }
                return
            }
            x += pillWidth + 6
        }
    }
}
