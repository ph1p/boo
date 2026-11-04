import SwiftUI

// Theme-tinted stand-ins for the stock SwiftUI controls, which otherwise paint
// with the system accent and grey bezels regardless of the terminal theme.
// They read `\.tokens`, so they repaint with the host's theme switches.

/// Boo's button: one look for every action, tinted by the theme.
/// - `primary`: accent text on an accent wash, the main action ("New Agent", "Start", "Merge").
/// - `secondary`: a quiet bezel for the rest ("Cancel", "Refresh").
/// - `subtle`: no fill until hovered, for icon and row actions.
/// - `destructive`: the error tint, for actions that throw work away.
/// `small` fits inline rows and forms, `large` is a full call to action.
/// A label's own font wins, so a sidebar can keep its scaled font.
struct ThemedButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, subtle, destructive }
    enum Size { case small, large }

    var variant: Variant = .secondary
    var size: Size = .small
    /// Stretch to the available width, label centred.
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let variant: Variant
        let size: Size
        let fullWidth: Bool
        @Environment(\.tokens) private var t
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size == .large ? BooStyle.Radius.large : BooStyle.Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: size == .large ? 12 : 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, size == .large ? 12 : 9)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(minHeight: size == .large ? BooStyle.Height.large : BooStyle.Height.control)
                // Fill only, no stroke: a translucent hairline over a translucent
                // fill read as a dark ring around the button on most themes.
                .background(shape.fill(fill))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovered = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }

        private var foreground: Color {
            switch variant {
            case .primary: return t.accent
            case .destructive: return t.error
            case .secondary: return t.text
            case .subtle: return hovered ? t.text : t.textSecondary
            }
        }

        private var fill: Color {
            let pressed = configuration.isPressed
            switch variant {
            // Deliberate raw alpha: a tinted wash stepping through the hover band.
            case .primary: return t.accent.opacity(pressed ? 0.3 : hovered ? 0.22 : 0.14)
            case .destructive: return t.error.opacity(pressed ? 0.3 : hovered ? 0.22 : 0.12)
            case .secondary: return pressed ? t.separator : hovered ? t.controlFill : t.hoverFill
            case .subtle: return pressed ? t.controlFill : hovered ? t.hoverFill : .clear
            }
        }
    }
}

/// Inline text link in the theme accent, underlined on hover.
struct ThemedLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLink(configuration: configuration)
    }

    private struct StyledLink: View {
        let configuration: Configuration
        @Environment(\.tokens) private var t
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(configuration.isPressed ? t.accentEmphasis : t.accent)
                .underline(hovered)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// Checkbox drawn in theme colours: accent fill with a check when on.
struct ThemedCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledCheckbox(configuration: configuration)
    }

    private struct StyledCheckbox: View {
        let configuration: Configuration
        @Environment(\.tokens) private var t

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: BooStyle.Radius.tiny, style: .continuous)
                        .fill(configuration.isOn ? t.accent : t.subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: BooStyle.Radius.tiny, style: .continuous)
                                .strokeBorder(configuration.isOn ? .clear : t.textTertiary, lineWidth: 0.5)
                        )
                        .overlay {
                            if configuration.isOn {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(t.chromeBg)
                            }
                        }
                        .frame(width: 13, height: 13)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Plain text field on a subtle fill with a hairline edge that turns accent
/// while editing. Apply to a `TextField` with `.themedTextField()`.
struct ThemedTextFieldModifier: ViewModifier {
    @Environment(\.tokens) private var t
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(BooStyle.Font.body)
            .foregroundStyle(t.text)
            .focused($focused)
            .themedFieldChrome(focused: focused)
    }
}

/// The field look on its own, for composite fields (icon + text field +
/// clear button) that track focus themselves.
struct ThemedFieldChrome: ViewModifier {
    @Environment(\.tokens) private var t
    @Environment(\.displayScale) private var scale
    @State private var hovered = false
    let focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: BooStyle.Radius.control, style: .continuous)
        content
            .padding(.horizontal, 8)
            .frame(minHeight: BooStyle.Height.control)
            .background(shape.fill(t.subtleFill))
            .overlay(
                shape.strokeBorder(
                    focused ? t.focusRing : hovered ? t.textTertiary.opacity(0.6) : t.separator,
                    lineWidth: focused ? 1 : 1 / scale)
            )
            // Soft halo outside the edge while editing, like the system focus ring.
            .overlay(
                RoundedRectangle(cornerRadius: BooStyle.Radius.control + 2, style: .continuous)
                    .strokeBorder(t.accent.opacity(focused ? 0.22 : 0), lineWidth: 3)
                    .padding(-3)
                    .allowsHitTesting(false)
            )
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static var themed: ThemedButtonStyle { ThemedButtonStyle() }
    static var themedProminent: ThemedButtonStyle { ThemedButtonStyle(variant: .primary) }
    static func themed(
        _ variant: ThemedButtonStyle.Variant, size: ThemedButtonStyle.Size = .small, fullWidth: Bool = false
    ) -> ThemedButtonStyle {
        ThemedButtonStyle(variant: variant, size: size, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == ThemedLinkButtonStyle {
    static var themedLink: ThemedLinkButtonStyle { ThemedLinkButtonStyle() }
}

extension ToggleStyle where Self == ThemedCheckboxStyle {
    static var themedCheckbox: ThemedCheckboxStyle { ThemedCheckboxStyle() }
}

extension View {
    func themedTextField() -> some View { modifier(ThemedTextFieldModifier()) }
    func themedFieldChrome(focused: Bool) -> some View { modifier(ThemedFieldChrome(focused: focused)) }
}
