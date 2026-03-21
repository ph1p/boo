import SwiftUI

/// Renders DSLElement trees into native SwiftUI views with automatic theming and accessibility.
/// ADR-6: Plugin authors describe structure; the renderer enforces a11y.
struct DSLRenderer: View {
    let elements: [DSLElement]
    let theme: TerminalTheme
    let density: SidebarDensity
    var onAction: ((DSLAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: density == .comfortable ? 8 : 4) {
            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                self.renderElement(element)
            }
        }
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
                HStack(spacing: density == .comfortable ? 8 : 4) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        self.renderElement(child)
                    }
                })

        case .label(let text, let style, let tint):
            return AnyView(renderLabel(text: text, style: style, tint: tint))

        case .list(let items):
            return AnyView(renderList(items: items))

        case .button(let label, let action, let style):
            return AnyView(renderButton(label: label, action: action, style: style))

        case .badge(let text, let tint, let a11yLabel):
            return AnyView(renderBadge(text: text, tint: tint, accessibilityLabel: a11yLabel))

        case .divider:
            return AnyView(Divider().accessibilityHidden(true))

        case .spacer:
            return AnyView(Spacer().accessibilityHidden(true))
        }
    }

    // MARK: - Label

    @ViewBuilder
    private func renderLabel(text: String, style: DSLTextStyle?, tint: DSLTint?) -> some View {
        let font: Font = {
            switch style {
            case .bold: return .system(size: fontSize, weight: .semibold)
            case .mono: return .system(size: fontSize, design: .monospaced)
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
            .foregroundColor(color)
            .accessibilityLabel(text)
    }

    // MARK: - List

    @ViewBuilder
    private func renderList(items: [DSLListItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                renderListItem(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(items.count) items")
    }

    @ViewBuilder
    private func renderListItem(_ item: DSLListItem) -> some View {
        let itemHeight: CGFloat = density == .comfortable ? 28 : 22
        let content = HStack(spacing: 6) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: density == .comfortable ? 13 : 11))
                    .foregroundColor(item.tint.map { tintColor($0) } ?? Color(nsColor: theme.chromeMuted))
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: fontSize))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: fontSize - 2))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .frame(height: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .contentShape(Rectangle())

        if let action = item.action {
            Button(action: { onAction?(action) }) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.accessibilityLabel ?? item.label)
            .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityLabel(item.accessibilityLabel ?? item.label)
        }
    }

    // MARK: - Button

    @ViewBuilder
    private func renderButton(label: String, action: DSLAction, style: DSLButtonStyle?) -> some View {
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
                .foregroundColor(color)
                .padding(.horizontal, density == .comfortable ? 12 : 8)
                .padding(.vertical, density == .comfortable ? 6 : 4)
                .background(color.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Badge

    @ViewBuilder
    private func renderBadge(text: String, tint: DSLTint?, accessibilityLabel: String?) -> some View {
        let color = tint.map { tintColor($0) } ?? Color(nsColor: theme.accentColor)
        Text(text)
            .font(.system(size: density == .comfortable ? 10 : 9, weight: .bold))
            .foregroundColor(.white)
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
        case .success: return Color(nsColor: NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.31, alpha: 1.0))
        case .error: return .red
        case .warning: return Color(nsColor: NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0))
        case .accent: return Color(nsColor: theme.accentColor)
        case .muted: return Color(nsColor: theme.chromeMuted)
        }
    }
}
