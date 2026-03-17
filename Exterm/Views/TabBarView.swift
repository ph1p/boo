import Cocoa

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int)
    func tabBarDidRequestNewTab(_ tabBar: TabBarView)
}

class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    struct Tab {
        let title: String
        let path: String
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex: Int = -1

    private let tabHeight: CGFloat = 36
    private let tabMinWidth: CGFloat = 100
    private let tabMaxWidth: CGFloat = 200

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: tabHeight)
    }

    func setTabs(_ tabs: [Tab], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Tab bar gutter — darkest
        ctx.setFillColor(CGColor(red: 13/255, green: 13/255, blue: 15/255, alpha: 1))
        ctx.fill(bounds)

        let tabWidth = calculateTabWidth()

        for (i, tab) in tabs.enumerated() {
            let x = CGFloat(i) * tabWidth
            let isSelected = i == selectedIndex

            if isSelected {
                // Active tab — rounded top corners, matches terminal bg
                let r: CGFloat = 8
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: tabHeight))
                path.addLine(to: CGPoint(x: x, y: r))
                path.addArc(tangent1End: CGPoint(x: x, y: 0),
                             tangent2End: CGPoint(x: x + r, y: 0), radius: r)
                path.addLine(to: CGPoint(x: x + tabWidth - r, y: 0))
                path.addArc(tangent1End: CGPoint(x: x + tabWidth, y: 0),
                             tangent2End: CGPoint(x: x + tabWidth, y: r), radius: r)
                path.addLine(to: CGPoint(x: x + tabWidth, y: tabHeight))
                path.closeSubpath()

                ctx.addPath(path)
                ctx.setFillColor(CGColor(red: 21/255, green: 21/255, blue: 23/255, alpha: 1))
                ctx.fillPath()

                // Accent indicator — 2px blue line at top
                ctx.setFillColor(CGColor(red: 77/255, green: 143/255, blue: 232/255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: CGRect(x: x + r, y: 0, width: tabWidth - r * 2, height: 2),
                                   cornerWidth: 1, cornerHeight: 1, transform: nil))
                ctx.fillPath()
            } else {
                // Separator between inactive tabs
                if i > 0 && i - 1 != selectedIndex {
                    ctx.setFillColor(CGColor(red: 42/255, green: 42/255, blue: 47/255, alpha: 1))
                    ctx.fill(CGRect(x: x, y: 8, width: 1, height: tabHeight - 16))
                }
            }

            // Title
            let title = tab.title as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
                .foregroundColor: isSelected
                    ? NSColor(red: 228/255, green: 228/255, blue: 232/255, alpha: 1)
                    : NSColor(red: 142/255, green: 142/255, blue: 150/255, alpha: 1)
            ]
            let titleSize = title.size(withAttributes: attrs)
            let titleRect = CGRect(
                x: x + 14,
                y: (tabHeight - titleSize.height) / 2,
                width: min(titleSize.width, tabWidth - 40),
                height: titleSize.height
            )
            title.draw(in: titleRect, withAttributes: attrs)

            // Close button
            let closeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(red: 86/255, green: 86/255, blue: 94/255, alpha: 1)
            ]
            let closeStr = "\u{2715}" as NSString
            let closeSize = closeStr.size(withAttributes: closeAttrs)
            closeStr.draw(
                at: CGPoint(x: x + tabWidth - closeSize.width - 10,
                            y: (tabHeight - closeSize.height) / 2),
                withAttributes: closeAttrs
            )
        }

        // Plus button
        let plusX = CGFloat(tabs.count) * tabWidth + 12
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor(red: 86/255, green: 86/255, blue: 94/255, alpha: 1)
        ]
        ("+" as NSString).draw(at: CGPoint(x: plusX, y: 7), withAttributes: plusAttrs)
    }

    private func calculateTabWidth() -> CGFloat {
        guard !tabs.isEmpty else { return tabMinWidth }
        let available = bounds.width - 30
        let width = available / CGFloat(tabs.count)
        return min(tabMaxWidth, max(tabMinWidth, width))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let tabWidth = calculateTabWidth()

        let tabIndex = Int(point.x / tabWidth)
        guard tabIndex >= 0, tabIndex < tabs.count else {
            let plusX = CGFloat(tabs.count) * tabWidth
            if point.x >= plusX && point.x <= plusX + 30 {
                delegate?.tabBarDidRequestNewTab(self)
            }
            return
        }

        let tabRight = CGFloat(tabIndex + 1) * tabWidth
        if point.x > tabRight - 24 {
            delegate?.tabBar(self, didCloseTabAt: tabIndex)
        } else {
            delegate?.tabBar(self, didSelectTabAt: tabIndex)
        }
    }
}
