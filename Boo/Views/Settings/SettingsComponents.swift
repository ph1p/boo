import Cocoa
import SwiftUI

// MARK: - Settings Page Shell

extension View {
    /// Render this view as an island: the chrome fill, clipped to the shared corner
    /// radius, with the same hairline every island in the main window carries.
    func island(_ t: Tokens) -> some View {
        self
            .background(t.bg)
            .clipShape(RoundedRectangle(cornerRadius: IslandMetrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: IslandMetrics.radius, style: .continuous)
                    .strokeBorder(t.islandBorder, lineWidth: IslandMetrics.borderWidth))
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }
}

/// A titled card. Its direct children are rows, separated by hairlines.
/// `footer` is muted text under the card for notes about the whole section.
struct Section<Content: View>: View {
    let title: String
    var footer: String? = nil
    var dividers: Bool = true
    @ViewBuilder let content: () -> Content
    @Environment(\.tokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.muted)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: dividers ? 0 : Tokens.rowSpacing) {
                Group(subviews: content()) { rows in
                    ForEach(rows) { row in
                        if dividers && row.id != rows.first?.id { SettingsRowDivider() }
                        row.padding(.vertical, dividers ? Tokens.rowSpacing - 2 : 0)
                    }
                }
            }
            .padding(.horizontal, Tokens.sectionPadding)
            .padding(.vertical, dividers ? 2 : Tokens.sectionPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tokens.separator, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Hairline between rows of a list or card.
struct SettingsRowDivider: View {
    @Environment(\.tokens) private var tokens

    var body: some View {
        Rectangle().fill(tokens.separator).frame(height: 0.5)
    }
}

// MARK: - Reusable Controls

/// Point-size menu over a whole-number range.
struct FontSizePicker: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 90

    var body: some View {
        ThemedMenuPicker(
            selection: $value,
            options: Array(stride(from: range.lowerBound, through: range.upperBound, by: 1)),
            width: width
        ) { "\(Int($0)) pt" }
    }
}

/// Font-family menu; each item is drawn in its own face.
struct FontChooser: View {
    @Binding var selectedFont: String
    let fonts: [String]
    var width: CGFloat = 220

    var body: some View {
        ThemedMenuPicker(
            selection: $selectedFont, options: fonts, width: width,
            itemFont: { NSFont(name: $0, size: 13) }
        ) { $0 }
    }
}

/// Label on the left, switch on the right.
struct ToggleRow: View {
    let label: String
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label: label, help: help, alignment: .center) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.themedSwitch)
        }
    }
}

// MARK: - Unified Settings Row

/// Label on the left, control trailing, optional help underneath. Primary
/// building block for settings pages; a control that wants the full width
/// (a text field) fills the space after the label.
struct SettingRow<Control: View>: View {
    @Environment(\.tokens) private var tokens
    let label: String
    var help: String? = nil
    var alignment: VerticalAlignment = .center
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: alignment, spacing: 12) {
                SettingLabel(text: label)
                    .frame(minWidth: Tokens.labelWidth, alignment: .leading)
                    .layoutPriority(1)
                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let help { DescriptionLabel(text: help) }
        }
    }
}

/// The 12pt row label shared by every row type.
struct SettingLabel: View {
    @Environment(\.tokens) private var tokens
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tokens.text)
    }
}

/// Standalone 11pt muted description line.
struct DescriptionLabel: View {
    @Environment(\.tokens) private var tokens
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tokens.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row for wide controls (segmented pickers): label and control side by
/// side like `SettingRow` when the control fits, label above it when not.
struct SettingStack<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SettingLabel(text: label)
                        .frame(minWidth: Tokens.labelWidth, alignment: .leading)
                        .fixedSize()
                    Spacer(minLength: 0)
                    control().fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel(text: label)
                    control()
                }
            }
            if let help { DescriptionLabel(text: help) }
        }
    }
}

/// A folder (or file) setting: label with the current path under it, actions
/// trailing. An empty `path` shows `placeholder` instead.
struct PathRow<Actions: View>: View {
    @Environment(\.tokens) private var tokens
    let label: String
    let path: String
    var placeholder: String = "None"
    var help: String? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingLabel(text: label)
                    Text(path.isEmpty ? placeholder : (path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: path.isEmpty ? .default : .monospaced))
                        .foregroundStyle(tokens.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) { actions() }
                    .buttonStyle(.themed)
                    .fixedSize()
            }
            if let help { DescriptionLabel(text: help) }
        }
    }
}

// MARK: - Text Field

/// Themed text field matching the settings visual language.
struct SettingTextField: View {
    @Environment(\.tokens) private var tokens
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var width: CGFloat? = nil
    var icon: String? = nil
    var trailingClear: Bool = false
    var onCommit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        let t = tokens
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(t.text)
                .focused($focused)
                .onSubmit { onCommit?() }
            if trailingClear && !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .themedFieldChrome(focused: focused)
        .frame(width: width)
    }
}

struct SettingNumberField: View {
    @Environment(\.tokens) private var tokens
    @Binding var value: Int
    var width: CGFloat = 70
    var alignment: TextAlignment = .trailing
    var onCommit: ((Int) -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .multilineTextAlignment(alignment)
            .foregroundStyle(tokens.text)
            .focused($focused)
            .themedFieldChrome(focused: focused)
            .frame(width: width)
            .onChange(of: value) { _, v in onCommit?(v) }
    }
}

// MARK: - Icon Button

/// Small icon button used for inline row actions (delete, edit).
struct IconButton: View {
    @Environment(\.tokens) private var tokens
    let systemName: String
    var tint: Color? = nil
    var size: CGFloat = 11
    var frame: CGFloat = 22
    var fillOpacity: Double = 0.12
    var help: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let t = tokens
        let color = tint ?? t.muted
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .frame(width: frame, height: frame)
                .foregroundStyle(hovered ? t.text : color)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(hovered ? fillOpacity * 2 : fillOpacity))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        if let help {
            button.help(help)
        } else {
            button
        }
    }
}

// MARK: - Shortcut Pill

struct ShortcutPill: View {
    @Environment(\.tokens) private var tokens
    let text: String

    var body: some View {
        let t = tokens
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(t.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(t.accent.opacity(0.1))
            )
    }
}

/// A row with an Inherit switch over an optional value. Turning it off seeds
/// the value with `fallback`, so the control starts from what applies today.
struct InheritableField<Value, Control: View>: View {
    let label: String
    var help: String? = nil
    @Binding var value: Value?
    let fallback: Value
    @ViewBuilder let control: (Binding<Value>) -> Control
    @Environment(\.tokens) private var tokens

    init(
        label: String, help: String? = nil, value: Binding<Value?>, fallback: Value,
        @ViewBuilder control: @escaping (Binding<Value>) -> Control
    ) {
        self.label = label
        self.help = help
        _value = value
        self.fallback = fallback
        self.control = control
    }

    var body: some View {
        SettingRow(label: label, help: help) {
            HStack(spacing: 10) {
                if value != nil {
                    control(Binding(get: { value ?? fallback }, set: { value = $0 }))
                }
                Toggle("Inherit", isOn: Binding(get: { value == nil }, set: { value = $0 ? nil : fallback }))
                    .toggleStyle(.themedCheckbox)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.muted)
            }
        }
    }
}
