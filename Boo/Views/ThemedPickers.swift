import AppKit
import SwiftUI

// Theme-tinted replacements for the native segmented control, pop-up button,
// switch and stepper. The stock ones paint with the system accent and grey
// bezels whatever the terminal theme; these read `\.tokens` like the rest of
// ThemedControls.

// MARK: - Segmented Picker

/// A row of mutually exclusive choices on one track; the chosen one is raised.
/// Use for 2–4 short options. Longer lists belong in `ThemedMenuPicker`.
struct ThemedSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Environment(\.tokens) private var t
    @Namespace private var thumb
    @State private var hovered: Value?

    init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        _selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(BooStyle.Font.control)
                        .lineLimit(1)
                        .foregroundStyle(selected ? t.text : hovered == option ? t.text : t.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: BooStyle.Height.control - 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: BooStyle.Radius.control - 2, style: .continuous)
                                    .fill(t.cardBg)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            } else if hovered == option {
                                RoundedRectangle(cornerRadius: BooStyle.Radius.control - 2, style: .continuous)
                                    .fill(t.subtleFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: BooStyle.Radius.control, style: .continuous).fill(t.hoverFill)
        )
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

extension ThemedSegmentedPicker where Value: CaseIterable, Value.AllCases: RandomAccessCollection {
    /// Every case, in declaration order.
    init(selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.init(selection: selection, options: Array(Value.allCases), title: title)
    }
}

// MARK: - Menu Picker

/// A pop-up button in theme colours: the current choice and a chevron on a
/// control fill. Opens a native `NSMenu` (keyboard, type-select and checkmark
/// for free), positioned so the current item sits over the button. A current
/// value missing from `options` is listed first, so it never shows blank.
struct ThemedMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    /// Optional per-item font in the menu (a font chooser shows each face).
    let itemFont: ((Value) -> NSFont?)?
    /// Fixed width; nil sizes to the current title.
    let width: CGFloat?
    @Environment(\.tokens) private var t
    @Environment(\.isEnabled) private var isEnabled
    @State private var anchor = ViewAnchor.Box()
    @State private var hovered = false

    init(
        selection: Binding<Value>, options: [Value], width: CGFloat? = nil,
        itemFont: ((Value) -> NSFont?)? = nil, title: @escaping (Value) -> String
    ) {
        _selection = selection
        self.options = options
        self.width = width
        self.itemFont = itemFont
        self.title = title
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BooStyle.Radius.control, style: .continuous)
        let label = title(selection)
        Button(action: open) {
            HStack(spacing: 6) {
                Text(label)
                    .font(BooStyle.Font.control)
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(t.textSecondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(width: width)
            .frame(minHeight: BooStyle.Height.control)
            .background(shape.fill(hovered ? t.controlFill : t.hoverFill))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background(ViewAnchor(box: anchor))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 && isEnabled }
        .accessibilityValue(label)
    }

    private func open() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = view.bounds.width
        menu.font = .systemFont(ofSize: 12)
        let listed = options.contains(selection) ? options : [selection] + options
        var current: NSMenuItem?
        for option in listed {
            let name = title(option)
            let item = ClosureMenuItem(title: name) { selection = option }
            if let font = itemFont?(option) {
                item.attributedTitle = NSAttributedString(string: name, attributes: [.font: font])
            }
            if option == selection {
                item.state = .on
                current = item
            }
            menu.addItem(item)
        }
        menu.appearance = NSAppearance(named: t.theme.isDark ? .darkAqua : .aqua)
        let origin = NSPoint(x: 0, y: view.isFlipped ? 0 : view.bounds.height)
        menu.popUp(positioning: current, at: origin, in: view)
    }
}

extension ThemedMenuPicker where Value: CaseIterable, Value.AllCases: RandomAccessCollection {
    /// Every case, in declaration order.
    init(selection: Binding<Value>, width: CGFloat? = nil, title: @escaping (Value) -> String) {
        self.init(selection: selection, options: Array(Value.allCases), width: width, title: title)
    }
}

/// Hands the SwiftUI control's backing NSView to AppKit (menus, popovers).
struct ViewAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

// MARK: - Switch

/// On/off switch: accent track with a light knob when on, control fill when off.
/// Apply with `.toggleStyle(.themedSwitch)`.
struct ThemedSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledSwitch(configuration: configuration)
    }

    private struct StyledSwitch: View {
        let configuration: Configuration
        @Environment(\.tokens) private var t
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 6) {
                configuration.label
                Button {
                    configuration.isOn.toggle()
                } label: {
                    Capsule()
                        .fill(on ? t.accent : t.controlFill)
                        .overlay(Capsule().strokeBorder(on ? .clear : t.separator, lineWidth: 0.5))
                        .overlay(alignment: on ? .trailing : .leading) {
                            Circle()
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                                .padding(2)
                        }
                        .frame(width: 28, height: 16)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: on)
                .accessibilityValue(on ? "on" : "off")
            }
        }
    }
}

// MARK: - Stepper

/// Value with − / + buttons on one control fill. `format` renders the value.
struct ThemedStepper<V: Strideable>: View {
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let format: (V) -> String
    @Environment(\.tokens) private var t

    init(value: Binding<V>, in range: ClosedRange<V>, step: V.Stride, format: @escaping (V) -> String) {
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value.advanced(by: -step))
            }
            Text(format(value))
                .font(BooStyle.Font.control.monospacedDigit())
                .foregroundStyle(t.text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minWidth: 44)
            button("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value.advanced(by: step))
            }
        }
        .frame(height: BooStyle.Height.control)
        .background(
            RoundedRectangle(cornerRadius: BooStyle.Radius.control, style: .continuous).fill(t.hoverFill))
    }

    private func button(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(t.textSecondary)
                .frame(width: 22, height: BooStyle.Height.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

extension ToggleStyle where Self == ThemedSwitchStyle {
    static var themedSwitch: ThemedSwitchStyle { ThemedSwitchStyle() }
}
