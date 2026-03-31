import Cocoa

/// Blue overlay showing where a dragged tab will be dropped.
class TabDropIndicatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.2).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
