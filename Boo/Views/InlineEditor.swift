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
/// live; the popover closes on Return. Drawn in the theme's chrome colors.
struct InlineEditorView: View {
    @State var name: String
    @State var color: WorkspaceColor
    @State var hasCustomColor: Bool
    let placeholder: String
    /// Secondary line under the name, e.g. the workspace's folder.
    var subtitle: String?
    /// Whether "no color" is offered — workspaces may be uncolored, groups not.
    var allowsNone = false
    let onRename: (String) -> Void
    let onColor: (WorkspaceColor) -> Void
    /// When set, a trailing swatch opens the system color panel.
    var onCustomColor: (() -> Void)?
    let actions: [InlineEditorAction]
    let onDone: () -> Void

    @Environment(\.tokens) private var t
    @FocusState private var nameFocused: Bool

    private var palette: [WorkspaceColor] {
        allowsNone ? WorkspaceColor.allCases : WorkspaceColor.allCases.filter { $0 != .none }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: $name)
                    .themedTextField()
                    .focused($nameFocused)
                    .onChange(of: name) { _, value in onRename(value) }
                    .onSubmit(onDone)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(t.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 2)
                        .help(subtitle)
                }
            }
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                ForEach(Array(palette.enumerated()), id: \.element) { i, swatch in
                    if i > 0 { Spacer(minLength: 2) }
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
                    Spacer(minLength: 2)
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
                Rectangle().fill(t.separator).frame(height: 1).padding(.vertical, 8).padding(.horizontal, -2)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(actions) { item in
                        EditorRow(item: item)
                    }
                }
                .padding(.horizontal, -4)
            }
        }
        .padding(10)
        .frame(width: 236)
        .onAppear { nameFocused = true }
    }

    private func swatchButton(
        selected: Bool, help: String, fill: AnyShapeStyle, isNone: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if isNone {
                    Circle().strokeBorder(t.textTertiary, lineWidth: 1)
                    Rectangle()
                        .fill(t.textTertiary)
                        .frame(width: 1, height: 12)
                        .rotationEffect(.degrees(45))
                } else {
                    Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                }
            }
            .frame(width: 14, height: 14)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? t.text : .clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A menu-like row: icon, title, theme hover highlight.
private struct EditorRow: View {
    let item: InlineEditorAction
    @Environment(\.tokens) private var t
    @State private var hovered = false

    var body: some View {
        let tint = item.isDestructive ? t.color(\.error) : t.text
        Button(action: item.action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(item.isDestructive ? tint : t.textSecondary)
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: IslandMetrics.controlRadius, style: .continuous)
                    .fill(hovered ? (item.isDestructive ? t.color(\.error).opacity(0.12) : t.hoverFill) : .clear)
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
    let theme = AppSettings.shared.theme
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    // Match the theme, not the system: a light popover over a dark theme glares.
    popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    let controller = NSHostingController(rootView: view.environment(\.tokens, Tokens(theme: theme)))
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
