import AppKit

/// Accessibility stand-in for a control that is drawn rather than backed by
/// an NSView (tab pills, workspace pills, drawn plus buttons). VoiceOver's
/// "press" runs `onPress`, so the item is operable, not just announced.
final class AccessibleElement: NSAccessibilityElement {
    private let onPress: (() -> Void)?

    init(
        parent: NSView, role: NSAccessibility.Role, label: String, localRect: NSRect,
        selected: Bool? = nil, onPress: (() -> Void)? = nil
    ) {
        self.onPress = onPress
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        if let selected {
            setAccessibilityValue((selected ? 1 : 0) as NSNumber)
            setAccessibilitySelected(selected)
        }
        if let window = parent.window {
            setAccessibilityFrame(window.convertToScreen(parent.convert(localRect, to: nil)))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
