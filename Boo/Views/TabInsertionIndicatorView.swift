import Cocoa

/// Thin vertical line showing where a dragged tab will be inserted in the tab bar.
class TabInsertionIndicatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        layer?.cornerRadius = 1.5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
