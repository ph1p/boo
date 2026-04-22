import SwiftUI

struct EditorSettingsView: View {
    @State private var fontSize = AppSettings.shared.editorFontSize
    @State private var fontName = AppSettings.shared.editorFontName
    @State private var tabSize = AppSettings.shared.editorTabSize
    @State private var insertSpaces = AppSettings.shared.editorInsertSpaces
    @State private var wordWrap = AppSettings.shared.editorWordWrap
    @State private var lineNumbers = AppSettings.shared.editorLineNumbers
    @State private var minimap = AppSettings.shared.editorMinimap
    @State private var formatOnSave = AppSettings.shared.editorFormatOnSave
    @State private var rulerColumn = AppSettings.shared.editorRulerColumn

    @ObservedObject private var observer = SettingsObserver(topics: [.editor])

    private let monoFonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Editor") {
            Section(title: "Font") {
                settingRow("Family", t: t) {
                    FontChooser(selectedFont: $fontName, fonts: monoFonts)
                        .frame(maxWidth: 200)
                        .onChange(of: fontName) { _, v in AppSettings.shared.editorFontName = v }
                }
                settingRow("Size", t: t) {
                    FontSizePicker(
                        value: Binding(get: { Double(fontSize) }, set: { fontSize = CGFloat($0) }),
                        range: 9...24
                    )
                    .frame(maxWidth: 200)
                    .onChange(of: fontSize) { _, v in AppSettings.shared.editorFontSize = v }
                }
            }

            Section(title: "Editing") {
                settingRow("Tab size", t: t) {
                    Picker("", selection: $tabSize) {
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 72)
                    .onChange(of: tabSize) { _, v in AppSettings.shared.editorTabSize = v }
                }
                ToggleRow(label: "Insert spaces", isOn: $insertSpaces)
                    .onChange(of: insertSpaces) { _, v in AppSettings.shared.editorInsertSpaces = v }
                ToggleRow(label: "Word wrap", isOn: $wordWrap)
                    .onChange(of: wordWrap) { _, v in AppSettings.shared.editorWordWrap = v }
            }

            Section(title: "Display") {
                ToggleRow(label: "Line numbers", isOn: $lineNumbers)
                    .onChange(of: lineNumbers) { _, v in AppSettings.shared.editorLineNumbers = v }
                ToggleRow(label: "Minimap", isOn: $minimap)
                    .onChange(of: minimap) { _, v in AppSettings.shared.editorMinimap = v }
                settingRow("Ruler column", t: t) {
                    HStack(spacing: 6) {
                        TextField("", value: $rulerColumn, format: .number)
                            .frame(width: 52)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: rulerColumn) { _, v in
                                AppSettings.shared.editorRulerColumn = max(0, v)
                            }
                        Text("(0 = off)")
                            .font(.system(size: 11))
                            .foregroundStyle(t.muted)
                    }
                }
            }

            Section(title: "Formatting") {
                ToggleRow(label: "Format on save", isOn: $formatOnSave)
                    .onChange(of: formatOnSave) { _, v in AppSettings.shared.editorFormatOnSave = v }
                Text("Uses Monaco's built-in formatters (JSON, TypeScript, CSS, HTML).")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                    .padding(.top, 2)
            }
        }
    }

    private func settingRow<C: View>(_ label: String, t: Tokens, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(t.text)
                .frame(width: 100, alignment: .leading)
            control()
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
