import SwiftUI

// MARK: - Custom Theme Editor

struct CustomThemeEditorView: View {
    @State var data: CustomThemeData
    let onSave: (CustomThemeData) -> Void
    let onCancel: () -> Void

    private var preview: TerminalTheme { data.toTheme() }
    private let ansiLabels = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    var body: some View {
        let t = Tokens.current
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 12) {
                TextField("Theme name", text: $data.name)
                    .font(.system(size: 14, weight: .semibold))
                    .textFieldStyle(.plain)
                    .foregroundStyle(t.text)
                Spacer()
                HStack(spacing: 0) {
                    Rectangle().fill(tc(preview.background)).frame(width: 18)
                    ForEach(0..<8, id: \.self) { i in Rectangle().fill(tc(preview.ansiColors[i])) }
                    ForEach(8..<16, id: \.self) { i in Rectangle().fill(tc(preview.ansiColors[i])) }
                }
                .frame(width: 136, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.muted.opacity(0.15), lineWidth: 0.5))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().opacity(0.25)

            // ── Body ─────────────────────────────────────────────────────────
            ScrollView {
                HStack(alignment: .top, spacing: 0) {

                    VStack(alignment: .leading, spacing: 20) {
                        EditorSection(title: "Terminal") {
                            SwatchRow(label: "Foreground", hex: hexBinding(\.foreground))
                            SwatchRow(label: "Background", hex: hexBinding(\.background))
                            SwatchRow(label: "Cursor", hex: hexBinding(\.cursor))
                            SwatchRow(label: "Selection", hex: $data.selectionHex)
                        }

                        EditorSection(title: "ANSI — Normal") {
                            ForEach(0..<8, id: \.self) { i in
                                SwatchRow(label: ansiLabels[i], hex: ansiBinding(i))
                            }
                        }

                        EditorSection(title: "ANSI — Bright") {
                            ForEach(0..<8, id: \.self) { i in
                                SwatchRow(label: ansiLabels[i], hex: ansiBinding(i + 8))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)

                    Rectangle()
                        .fill(t.muted.opacity(0.15))
                        .frame(width: 0.5)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 20) {
                        EditorSection(title: "UI Chrome") {
                            SwatchRow(label: "Toolbar BG", hex: $data.chromeBgHex)
                            SwatchRow(label: "Toolbar Text", hex: $data.chromeTextHex)
                            SwatchRow(label: "Muted Text", hex: $data.chromeMutedHex)
                            SwatchRow(label: "Sidebar BG", hex: $data.sidebarBgHex)
                            SwatchRow(label: "Accent", hex: $data.accentHex)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                }
                .padding(20)
            }

            Divider().opacity(0.25)

            // ── Footer ───────────────────────────────────────────────────────
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    while data.ansiColors.count < 16 {
                        data.ansiColors.append(TerminalColor(r: 128, g: 128, b: 128))
                    }
                    onSave(data)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(data.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 540)
        .background(t.bg)
    }

    // MARK: Bindings

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

    private func tc(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

// MARK: - Editor building blocks

struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(t.muted)
                .tracking(0.6)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 4) { content() }
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

/// One row: color well + label + editable hex field.
struct SwatchRow: View {
    let label: String
    @Binding var hex: String

    @State private var draft: String = ""
    @State private var isEditing = false

    private var fieldState: HexFieldState { hexFieldState(for: draft) }
    private var isInvalid: Bool { fieldState == .invalid }

    var body: some View {
        let t = Tokens.current
        HStack(spacing: 8) {
            ColorWell(hex: $hex)
                .frame(width: 26, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.muted.opacity(0.15), lineWidth: 0.5))

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                .frame(width: 88, alignment: .leading)

            TextField("", text: $draft)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(hexFieldTextColor(fieldState, tokens: t))
                .frame(width: 64)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hexFieldBg(fieldState, isEditing: isEditing, tokens: t))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    isInvalid
                                        ? Color.red.opacity(0.5)
                                        : (isEditing && fieldState == .incomplete
                                            ? t.accent.opacity(0.4) : Color.clear),
                                    lineWidth: 1
                                )
                        )
                )
                .onAppear { draft = hex.uppercased() }
                .onChange(of: hex) { _, newHex in
                    if !isEditing { draft = newHex.uppercased() }
                }
                .onSubmit { commitDraft() }
                .onTapGesture { isEditing = true }
                .onExitCommand {
                    isEditing = false
                    draft = hex.uppercased()
                }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { commitDraft() }
        }
    }

    private func commitDraft() {
        if let c = TerminalColor(hex: draft) {
            hex = c.hexString.uppercased()
        } else {
            draft = hex.uppercased()
        }
        isEditing = false
    }
}

private func hexFieldBg(_ state: HexFieldState, isEditing: Bool, tokens t: Tokens) -> Color {
    switch state {
    case .valid(let c):
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    case .incomplete:
        return isEditing ? t.muted.opacity(0.08) : Color.clear
    case .invalid:
        return Color.clear
    }
}

private func hexFieldTextColor(_ state: HexFieldState, tokens t: Tokens) -> Color {
    switch state {
    case .valid(let c):
        return c.luminance > 0.5 ? Color.black.opacity(0.75) : Color.white.opacity(0.9)
    case .incomplete:
        return t.muted.opacity(0.75)
    case .invalid:
        return Color.red.opacity(0.8)
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
        if let c = NSColor(hex: hex), c.usingColorSpace(.sRGB) != well.color.usingColorSpace(.sRGB) {
            well.color = c
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    @MainActor final class Coordinator: NSObject {
        var hex: Binding<String>
        init(hex: Binding<String>) { self.hex = hex }
        @objc func colorChanged(_ sender: NSColorWell) {
            guard let c = sender.color.usingColorSpace(.sRGB) else { return }
            hex.wrappedValue = String(
                format: "#%02X%02X%02X",
                Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)
            )
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
