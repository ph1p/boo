import SwiftUI

// Theme-tinted stand-ins for the stock SwiftUI controls, which otherwise paint
// with the system accent and grey bezels regardless of the terminal theme.
// They read `\.tokens`, so they repaint with the host's theme switches.

/// Compact bezel button: a control-fill capsule that brightens on hover.
/// `prominent` marks the primary action with the theme accent.
struct ThemedButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.tokens) private var t
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? t.accent : t.text)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.separator, lineWidth: 0.5)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovered = $0 && isEnabled }
        }

        private var fill: Color {
            if prominent {
                // Deliberate raw alpha: accent fill stepping through the hover band.
                return t.accent.opacity(configuration.isPressed ? 0.3 : hovered ? 0.22 : 0.15)
            }
            return configuration.isPressed ? t.controlFill : hovered ? t.hoverFill : t.subtleFill
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
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(configuration.isOn ? t.accent : t.subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
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
            .font(.system(size: 12))
            .foregroundStyle(t.text)
            .focused($focused)
            .themedFieldChrome(focused: focused)
    }
}

/// The field look on its own, for composite fields (icon + text field +
/// clear button) that track focus themselves.
struct ThemedFieldChrome: ViewModifier {
    @Environment(\.tokens) private var t
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.subtleFill))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? t.focusRing : t.separator, lineWidth: focused ? 1 : 0.5)
            )
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static var themed: ThemedButtonStyle { ThemedButtonStyle() }
    static var themedProminent: ThemedButtonStyle { ThemedButtonStyle(prominent: true) }
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
