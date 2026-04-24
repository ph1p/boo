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

        SettingsPage(title: "Editor") {
            Section(title: "Font") {
                SettingRow(label: "Family") {
                    FontChooser(selectedFont: $fontName, fonts: monoFonts)
                        .frame(maxWidth: 220, alignment: .leading)
                        .onChange(of: fontName) { _, v in AppSettings.shared.editorFontName = v }
                }
                SettingRow(label: "Size") {
                    FontSizePicker(
                        value: Binding(get: { Double(fontSize) }, set: { fontSize = CGFloat($0) }),
                        range: 9...24
                    )
                    .frame(maxWidth: 120, alignment: .leading)
                    .onChange(of: fontSize) { _, v in AppSettings.shared.editorFontSize = v }
                }
            }

            Section(title: "Editing") {
                SettingRow(label: "Tab size") {
                    Picker("", selection: $tabSize) {
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 72, alignment: .leading)
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
                SettingRow(
                    label: "Ruler column",
                    help: "Column where the vertical ruler is drawn. 0 disables the ruler."
                ) {
                    SettingNumberField(
                        value: $rulerColumn,
                        width: 64,
                        alignment: .leading,
                        onCommit: { v in AppSettings.shared.editorRulerColumn = max(0, v) }
                    )
                }
            }

            Section(title: "Formatting") {
                ToggleRow(
                    label: "Format on save",
                    help: "Uses Monaco's built-in formatters (JSON, TypeScript, CSS, HTML).",
                    isOn: $formatOnSave
                )
                .onChange(of: formatOnSave) { _, v in AppSettings.shared.editorFormatOnSave = v }
            }
        }
    }
}
