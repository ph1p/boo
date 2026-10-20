import Cocoa
import SwiftUI

/// One action row at the bottom of an `InlineEditorView`.
struct InlineEditorAction: Identifiable {
    let title: String
    let symbol: String
    var isDestructive = false
    let action: () -> Void

    var id: String { title }
}

/// Popover body for editing something with a name and a color in place — a tab
/// group or a workspace — plus a short list of related actions. Changes apply
/// live; the popover closes on Return.
struct InlineEditorView: View {
    @State var name: String
    @State var color: WorkspaceColor
    @State var hasCustomColor: Bool
    let placeholder: String
    /// Whether "no color" is offered — workspaces may be uncolored, groups not.
    var allowsNone = false
    let onRename: (String) -> Void
    let onColor: (WorkspaceColor) -> Void
    /// When set, a trailing swatch opens the system color panel.
    var onCustomColor: (() -> Void)?
    let actions: [InlineEditorAction]
    let onDone: () -> Void

    @FocusState private var nameFocused: Bool

    private var palette: [WorkspaceColor] {
        allowsNone ? WorkspaceColor.allCases : WorkspaceColor.allCases.filter { $0 != .none }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onChange(of: name) { _, value in onRename(value) }
                .onSubmit(onDone)

            HStack(spacing: 5) {
                ForEach(palette, id: \.self) { swatch in
                    swatchButton(
                        selected: !hasCustomColor && color == swatch, help: swatch.label,
                        fill: AnyShapeStyle(Color(nsColor: swatch.nsColor ?? .clear)),
                        isNone: swatch == .none
                    ) {
                        color = swatch
                        hasCustomColor = false
                        onColor(swatch)
                    }
                }
                if let onCustomColor {
                    swatchButton(
                        selected: hasCustomColor, help: "Custom Color…",
                        fill: AnyShapeStyle(
                            AngularGradient(
                                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center)),
                        isNone: false
                    ) {
                        onCustomColor()
                    }
                }
            }

            if !actions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(actions) { item in
                        EditorRow(item: item)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { nameFocused = true }
    }

    private func swatchButton(
        selected: Bool, help: String, fill: AnyShapeStyle, isNone: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if isNone {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.8))
                        .frame(width: 1.2, height: 14)
                        .rotationEffect(.degrees(45))
                }
            }
            .frame(width: 16, height: 16)
            .padding(3)
            .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A menu-like row: icon, title, hover highlight.
private struct EditorRow: View {
    let item: InlineEditorAction
    @State private var hovered = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .frame(width: 14)
                    .foregroundStyle(item.isDestructive ? Color.red : .secondary)
                Text(item.title)
                    .foregroundStyle(item.isDestructive ? Color.red : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Builds a transient popover hosting `view`. `tag` lands on the content
/// controller's `representedObject` so callers can tell which item it edits.
@MainActor
func makeInlineEditorPopover<V: View>(_ view: V, tag: Any? = nil) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    let controller = NSHostingController(rootView: view)
    controller.representedObject = tag
    controller.sizingOptions = [.preferredContentSize]
    popover.contentViewController = controller
    return popover
}

/// Routes the shared `NSColorPanel` to a closure. One relay app-wide, so a new
/// edit simply retargets the panel.
@MainActor
final class ColorPanelRelay: NSObject {
    static let shared = ColorPanelRelay()
    private var onChange: ((NSColor) -> Void)?

    func begin(initial: NSColor?, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        if let initial { panel.color = initial }
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
