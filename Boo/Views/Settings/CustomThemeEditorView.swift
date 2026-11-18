import SwiftUI

// MARK: - Custom Theme Editor

struct CustomThemeEditorView: View {
    @Environment(\.tokens) private var tokens
    @State var data: CustomThemeData
    let onSave: (CustomThemeData) -> Void
    let onCancel: () -> Void

    /// Debounces live-preview pushes: color-panel drags fire per tick, and each
    /// preview change restyles the whole app (chrome + every terminal surface).
    @State private var previewWork: DispatchWorkItem?

    private var preview: TerminalTheme { data.toTheme() }
    private let ansiLabels = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    private var nameIsEmpty: Bool { data.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let t = tokens
        VStack(spacing: 0) {
            header
            SettingsRowDivider()

            ScrollView {
                HStack(alignment: .top, spacing: BooStyle.Space.xl) {
                    VStack(alignment: .leading, spacing: BooStyle.Space.xl) {
                        EditorSection(title: "Interface") {
                            Toggle("Pick accent from palette", isOn: autoAccent)
                                .toggleStyle(.themedCheckbox)
                                .font(BooStyle.Font.body)
                                .foregroundStyle(t.text)
                            if data.accentHex != nil {
                                SwatchRow(label: "Accent", hex: accentBinding)
                            }
                            Text("Sidebar, toolbar, text and borders are generated from the terminal colors.")
                                .font(BooStyle.Font.caption)
                                .foregroundStyle(t.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        EditorSection(title: "Terminal") {
                            SwatchRow(label: "Background", hex: hexBinding(\.background))
                            SwatchRow(label: "Foreground", hex: hexBinding(\.foreground))
                            SwatchRow(label: "Cursor", hex: hexBinding(\.cursor))
                            SwatchRow(label: "Selection", hex: $data.selectionHex)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    EditorSection(title: "ANSI Colors") { ansiGrid }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }

            SettingsRowDivider()
            footer
        }
        .frame(width: 700, height: 620)
        .background(t.bg)
        .onChange(of: data) { _, newData in schedulePreview(newData) }
        .onDisappear {
            // Save and cancel both land here: drop the transient preview and any
            // pending push, and close the color panel so it doesn't keep a
            // detached NSColorWell (and this whole view tree) alive.
            previewWork?.cancel()
            previewWork = nil
            AppSettings.shared.previewTheme = nil
            if NSColorPanel.sharedColorPanelExists {
                NSColorPanel.shared.close()
            }
        }
    }

    // MARK: Parts

    /// Live miniature of the edited theme beside the name and its 60-30-10 split.
    private var header: some View {
        let t = tokens
        let theme = preview
        return HStack(alignment: .top, spacing: 20) {
            ThemePreview(theme: theme)
                .frame(width: 230, height: 120)

            VStack(alignment: .leading, spacing: BooStyle.Space.md) {
                Text("Name").font(BooStyle.Font.sectionTitle).foregroundStyle(t.textSecondary)
                TextField("Theme name", text: $data.name).themedTextField()

                HStack(spacing: BooStyle.Space.xs) {
                    Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(theme.isDark ? "Dark theme" : "Light theme")
                }
                .font(BooStyle.Font.caption)
                .foregroundStyle(t.textSecondary)
                .padding(.top, BooStyle.Space.xs)

                ColorSplitBar(theme: theme)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    /// One row per ANSI hue: the normal and bright variant side by side.
    private var ansiGrid: some View {
        let t = tokens
        return Grid(alignment: .leading, horizontalSpacing: BooStyle.Space.md, verticalSpacing: BooStyle.Space.sm) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("Normal")
                Text("Bright")
            }
            .font(BooStyle.Font.caption)
            .foregroundStyle(t.textTertiary)
            ForEach(0..<8, id: \.self) { i in
                GridRow {
                    Text(ansiLabels[i]).font(BooStyle.Font.body).foregroundStyle(t.text)
                    SwatchField(hex: ansiBinding(i))
                    SwatchField(hex: ansiBinding(i + 8))
                }
            }
        }
    }

    private var footer: some View {
        let t = tokens
        return HStack(spacing: BooStyle.Space.md) {
            Text("Changes preview live in the app.")
                .font(BooStyle.Font.caption)
                .foregroundStyle(t.textTertiary)
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.themed(.secondary, size: .large))
                .keyboardShortcut(.cancelAction)
            Button("Save Theme") {
                while data.ansiColors.count < 16 {
                    data.ansiColors.append(TerminalColor(r: 128, g: 128, b: 128))
                }
                onSave(data)
            }
            .buttonStyle(.themed(.primary, size: .large))
            .keyboardShortcut(.defaultAction)
            .disabled(nameIsEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, BooStyle.Space.lg)
    }

    /// Push the edited colors as the app-wide preview theme, debounced.
    private func schedulePreview(_ newData: CustomThemeData) {
        previewWork?.cancel()
        let work = DispatchWorkItem { AppSettings.shared.previewTheme = newData.toTheme() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: Bindings

    /// On: the accent is picked from the palette (`accentHex` nil). Off: an
    /// explicit accent, seeded with the one the palette would pick.
    private var autoAccent: Binding<Bool> {
        Binding(
            get: { data.accentHex == nil },
            set: { auto in
                var seed = data
                seed.accentHex = nil
                data.accentHex = auto ? nil : seed.toTheme().accent.hexString
            }
        )
    }

    private var accentBinding: Binding<String> {
        Binding(
            get: { data.accentHex ?? preview.accent.hexString },
            set: { data.accentHex = $0 }
        )
    }

    private func hexBinding(_ kp: WritableKeyPath<CustomThemeData, TerminalColor>) -> Binding<String> {
        Binding(
            get: { data[keyPath: kp].hexString },
            set: { if let c = TerminalColor(hex: $0) { data[keyPath: kp] = c } }
        )
    }

    private func ansiBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < data.ansiColors.count ? data.ansiColors[index].hexString : "#808080" },
            set: { hex in
                guard let c = TerminalColor(hex: hex) else { return }
                while data.ansiColors.count <= index { data.ansiColors.append(TerminalColor(r: 128, g: 128, b: 128)) }
                data.ansiColors[index] = c
            }
        )
    }
}

// MARK: - Editor building blocks

/// The 60-30-10 split of a theme as one proportional bar: terminal background,
/// chrome surface, accent.
struct ColorSplitBar: View {
    @Environment(\.tokens) private var tokens
    let theme: TerminalTheme

    var body: some View {
        let t = tokens
        let p = Tokens(theme: theme)
        VStack(alignment: .leading, spacing: BooStyle.Space.xs) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    p.termBg.frame(width: geo.size.width * 0.6)
                    p.bg.frame(width: geo.size.width * 0.3)
                    p.accent
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(t.separator, lineWidth: 0.5))
            HStack(spacing: BooStyle.Space.lg) {
                legend(p.termBg, "Background 60")
                legend(p.bg, "Interface 30")
                legend(p.accent, "Accent 10")
            }
            .font(.system(size: 10))
            .foregroundStyle(t.textTertiary)
            .lineLimit(1)
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: BooStyle.Space.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(tokens.separator, lineWidth: 0.5))
            Text(label)
        }
    }
}

/// A titled card of swatch rows, matching the settings `Section` look.
struct EditorSection<Content: View>: View {
    @Environment(\.tokens) private var tokens
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let t = tokens
        VStack(alignment: .leading, spacing: BooStyle.Space.sm) {
            Text(title)
                .font(BooStyle.Font.sectionTitle)
                .foregroundStyle(t.muted)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.leading, BooStyle.Space.xxs)
            VStack(alignment: .leading, spacing: BooStyle.Space.sm) { content() }
                .padding(BooStyle.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(t.raised, in: RoundedRectangle(cornerRadius: BooStyle.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BooStyle.Radius.card, style: .continuous)
                        .strokeBorder(t.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Hex field color derivation (internal for testing)

/// Outcome of evaluating a hex draft string for the color swatch text field.
enum HexFieldState: Equatable {
    /// Fewer than 6 hex digits entered — no styling yet.
    case incomplete
    /// Exactly 6 valid hex digits — show this color as background.
    case valid(TerminalColor)
    /// 6+ chars but not a valid hex color — show error styling.
    case invalid
}

/// Pure function: derive display state from a raw draft string.
/// - A bare `#` or partial input (< 6 hex chars after `#`) → `.incomplete`
/// - A full 6-char valid hex → `.valid`
/// - Anything else of sufficient length → `.invalid`
func hexFieldState(for draft: String) -> HexFieldState {
    var s = draft.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s = String(s.dropFirst()) }
    if s.count < 6 { return .incomplete }
    if let c = TerminalColor(hex: draft) { return .valid(c) }
    return .invalid
}

/// One labelled row: name on the left, color well and hex field on the right.
struct SwatchRow: View {
    @Environment(\.tokens) private var tokens
    let label: String
    @Binding var hex: String

    var body: some View {
        HStack(spacing: BooStyle.Space.md) {
            Text(label)
                .font(BooStyle.Font.body)
                .foregroundStyle(tokens.text)
                .lineLimit(1)
            Spacer(minLength: BooStyle.Space.md)
            SwatchField(hex: $hex)
        }
    }
}

/// Color well plus an editable hex field. The draft commits on Return or when
/// focus leaves; Escape restores the stored value.
struct SwatchField: View {
    @Environment(\.tokens) private var tokens
    @Binding var hex: String

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var fieldState: HexFieldState { hexFieldState(for: draft) }

    var body: some View {
        let t = tokens
        let shape = RoundedRectangle(cornerRadius: BooStyle.Radius.control, style: .continuous)
        HStack(spacing: BooStyle.Space.sm) {
            ColorWell(hex: $hex)
                .frame(width: BooStyle.Height.control, height: BooStyle.Height.control)
                .clipShape(shape)
                .overlay(shape.strokeBorder(t.separator, lineWidth: 1))

            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(hexFieldTextColor(fieldState, tokens: t))
                .focused($focused)
                .frame(width: 60)
                .themedFieldChrome(focused: focused)
                .overlay(shape.strokeBorder(fieldState == .invalid ? t.error : .clear, lineWidth: 1))
                .onAppear { draft = hex.uppercased() }
                .onChange(of: hex) { _, newHex in
                    if !focused { draft = newHex.uppercased() }
                }
                .onSubmit { commitDraft() }
                .onExitCommand {
                    draft = hex.uppercased()
                    focused = false
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitDraft() }
                }
        }
    }

    private func commitDraft() {
        if let c = TerminalColor(hex: draft) {
            hex = c.hexString.uppercased()
        } else {
            draft = hex.uppercased()
        }
    }
}

private func hexFieldTextColor(_ state: HexFieldState, tokens t: Tokens) -> Color {
    switch state {
    case .valid:
        return t.text
    case .incomplete:
        return t.textSecondary
    case .invalid:
        return t.error
    }
}

/// NSColorWell bridge that binds to a hex string.
struct ColorWell: NSViewRepresentable {
    @Binding var hex: String

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.color = NSColor(hex: hex) ?? .gray
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        // Compare in hex space: NSColor equality after a hex roundtrip is
        // almost never exact, and writing back into an active well re-fires
        // the action and drifts the color.
        if let c = NSColor(hex: hex), Self.hexString(of: well.color) != hex.uppercased() {
            well.color = c
        }
    }

    static func hexString(of color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            lround(c.redComponent * 255), lround(c.greenComponent * 255), lround(c.blueComponent * 255)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    @MainActor final class Coordinator: NSObject {
        var hex: Binding<String>
        init(hex: Binding<String>) { self.hex = hex }
        @objc func colorChanged(_ sender: NSColorWell) {
            guard let value = ColorWell.hexString(of: sender.color) else { return }
            hex.wrappedValue = value
        }
    }
}

// MARK: - Helpers

extension CustomThemeData {
    func withName(_ newName: String) -> CustomThemeData {
        var copy = self
        copy.name = newName
        return copy
    }
}
