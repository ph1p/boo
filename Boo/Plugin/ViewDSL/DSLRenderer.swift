import SwiftUI

/// Renders DSLElement trees into native SwiftUI views with automatic theming and accessibility.
/// ADR-6: Plugin authors describe structure; the renderer enforces a11y.
struct DSLRenderer: View {
    let elements: [DSLElement]
    let theme: TerminalTheme
    let density: SidebarDensity
    var onAction: ((DSLAction) -> Void)?

    private var pad: CGFloat { density == .comfortable ? 12 : 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .comfortable ? 6 : 3) {
            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                self.renderElement(element)
            }
        }
        .padding(.horizontal, pad)
        .padding(.vertical, density == .comfortable ? 10 : 6)
    }

    private func renderElement(_ element: DSLElement) -> AnyView {
        switch element {
        case .vstack(let children):
            return AnyView(
                VStack(alignment: .leading, spacing: density == .comfortable ? 6 : 3) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        self.renderElement(child)
                    }
                })

        case .hstack(let children):
            return AnyView(
                HStack(spacing: density == .comfortable ? 6 : 4) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        self.renderElement(child)
                    }
                })

        case .label(let text, let style, let tint):
            return AnyView(renderLabel(text: text, style: style, tint: tint))

        case .list(let items):
            return AnyView(renderList(items: items))

        case .button(let label, let action, let style, let ctxMenu):
            return AnyView(renderButton(label: label, action: action, style: style, contextMenu: ctxMenu))

        case .badge(let text, let tint, let a11yLabel):
            return AnyView(renderBadge(text: text, tint: tint, accessibilityLabel: a11yLabel))

        case .divider:
            return AnyView(
                Divider()
                    .padding(.vertical, density == .comfortable ? 4 : 2)
                    .accessibilityHidden(true)
            )

        case .spacer:
            return AnyView(
                Spacer()
                    .frame(height: density == .comfortable ? 12 : 8)
                    .accessibilityHidden(true)
            )
        }
    }

    // MARK: - Label

    @ViewBuilder
    private func renderLabel(text: String, style: DSLTextStyle?, tint: DSLTint?) -> some View {
        let font: Font = {
            switch style {
            case .bold: return .system(size: fontSize, weight: .semibold)
            case .mono: return .system(size: fontSize - 1, design: .monospaced)
            case .muted, nil: return .system(size: fontSize)
            }
        }()

        let color: Color = {
            if let tint = tint { return tintColor(tint) }
            if style == .muted { return Color(nsColor: theme.chromeMuted) }
            return Color(nsColor: theme.chromeText)
        }()

        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(style == .mono ? 2 : nil)
            .accessibilityLabel(text)
    }

    // MARK: - List

    @ViewBuilder
    private func renderList(items: [DSLListItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                DSLListItemView(
                    item: item, theme: theme, density: density,
                    tintColor: tintColor, fontSize: fontSize, onAction: onAction
                )
            }
        }
        .padding(.horizontal, -pad)  // list items manage their own horizontal padding for full-width hover
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(items.count) items")
    }

    // MARK: - Button

    @ViewBuilder
    private func renderButton(
        label: String, action: DSLAction, style: DSLButtonStyle?, contextMenu: [DSLContextMenuItem]?
    ) -> some View {
        let color: Color = {
            switch style {
            case .primary, nil: return Color(nsColor: theme.accentColor)
            case .secondary: return Color(nsColor: theme.chromeMuted)
            case .destructive: return .red
            }
        }()

        Button(action: { onAction?(action) }) {
            Text(label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, density == .comfortable ? 12 : 8)
                .padding(.vertical, density == .comfortable ? 6 : 4)
                .background(color.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .modifier(DSLContextMenuModifier(items: contextMenu, onAction: onAction))
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Badge

    @ViewBuilder
    private func renderBadge(text: String, tint: DSLTint?, accessibilityLabel: String?) -> some View {
        let color = tint.map { tintColor($0) } ?? Color(nsColor: theme.accentColor)
        Text(text)
            .font(.system(size: density == .comfortable ? 10 : 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(8)
            .accessibilityLabel(accessibilityLabel ?? text)
    }

    // MARK: - Helpers

    private var fontSize: CGFloat {
        density == .comfortable ? 13 : 12
    }

    private func tintColor(_ tint: DSLTint) -> Color {
        switch tint {
        case .success: return Color(nsColor: .booLocal)
        case .error: return .red
        case .warning: return Color(nsColor: .booRemote)
        case .accent: return Color(nsColor: theme.accentColor)
        case .muted: return Color(nsColor: theme.chromeMuted)
        }
    }
}

// MARK: - List Item View (with hover state)

/// Separate view for list items so each can track its own hover state.
private struct DSLListItemView: View {
    let item: DSLListItem
    let theme: TerminalTheme
    let density: SidebarDensity
    let tintColor: (DSLTint) -> Color
    let fontSize: CGFloat
    let onAction: ((DSLAction) -> Void)?

    @State private var isHovered = false

    var body: some View {
        let itemHeight: CGFloat = density == .comfortable ? 28 : 22
        let hPad: CGFloat = density == .comfortable ? 12 : 8
        let content = HStack(spacing: 6) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: density == .comfortable ? 13 : 11))
                    .foregroundStyle(item.tint.map { tintColor($0) } ?? Color(nsColor: theme.chromeMuted))
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color(nsColor: theme.chromeText))
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundStyle(Color(nsColor: theme.chromeMuted))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .frame(height: itemHeight)
        .padding(.horizontal, hPad)
        .background(isHovered ? Color(nsColor: theme.chromeMuted).opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }

        let menuItems = item.contextMenu
        if let action = item.action {
            Button(action: { onAction?(action) }) {
                content
            }
            .buttonStyle(.plain)
            .modifier(DSLContextMenuModifier(items: menuItems, onAction: onAction))
            .accessibilityLabel(item.accessibilityLabel ?? item.label)
            .accessibilityAddTraits(.isButton)
        } else {
            content
                .modifier(DSLContextMenuModifier(items: menuItems, onAction: onAction))
                .accessibilityLabel(item.accessibilityLabel ?? item.label)
        }
    }
}

// MARK: - Context Menu Modifier

/// Applies a DSL context menu to any view. No-op when items is nil or empty.
private struct DSLContextMenuModifier: ViewModifier {
    let items: [DSLContextMenuItem]?
    let onAction: ((DSLAction) -> Void)?

    func body(content: Content) -> some View {
        if let items = items, !items.isEmpty {
            content.contextMenu {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button(action: { onAction?(item.action) }) {
                        if let icon = item.icon {
                            Label(item.label, systemImage: icon)
                        } else {
                            Text(item.label)
                        }
                    }
                    .foregroundStyle(item.style == .destructive ? Color.red : Color.primary)
                }
            }
        } else {
            content
        }
    }
}
