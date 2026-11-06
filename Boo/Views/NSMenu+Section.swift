import Cocoa

extension NSMenu {
    /// Adds `items` after a separator; nothing when there are none.
    func addSection(_ items: [NSMenuItem]) {
        guard !items.isEmpty else { return }
        addItem(.separator())
        items.forEach(addItem)
    }
}
