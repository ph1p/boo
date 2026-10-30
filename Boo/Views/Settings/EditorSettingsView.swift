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
    @State private var linkTarget = AppSettings.shared.defaultLinkTarget
    @State private var editorPreset = AppSettings.shared.externalEditorPreset
    @State private var editorTemplate = AppSettings.shared.externalEditorTemplate
    @State private var detectIndentation = AppSettings.shared.editorDetectIndentation
    @State private var renderWhitespace = AppSettings.shared.editorRenderWhitespace
    @State private var bracketPairColors = AppSettings.shared.editorBracketPairColors
    @State private var stickyScroll = AppSettings.shared.editorStickyScroll
    @State private var fontLigatures = AppSettings.shared.editorFontLigatures
    @State private var showStatusStrip = AppSettings.shared.editorShowStatusStrip
    @State private var cursorStyle = AppSettings.shared.editorCursorStyle
    @State private var cursorBlinking = AppSettings.shared.editorCursorBlinking
    @State private var autosave = AppSettings.shared.editorAutosave
    @State private var trimTrailingWhitespace = AppSettings.shared.editorTrimTrailingWhitespace
    @State private var insertFinalNewline = AppSettings.shared.editorInsertFinalNewline
    @State private var reloadOnExternalChange = AppSettings.shared.editorReloadOnExternalChange

    @ObservedObject private var observer = SettingsObserver(topics: [.editor, .links])

    private let monoFonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let _ = observer.revision

        SettingsPage(title: "Editor") {
            Section(title: "Font") {
                SettingRow(label: "Family") {
                    FontChooser(selectedFont: $fontName, fonts: monoFonts)
                        .frame(width: 220)
                        .onChange(of: fontName) { _, v in AppSettings.shared.editorFontName = v }
                }
                SettingRow(label: "Size") {
                    FontSizePicker(
                        value: Binding(get: { Double(fontSize) }, set: { fontSize = CGFloat($0) }),
                        range: 9...24
                    )
                    .frame(width: 90)
                    .onChange(of: fontSize) { _, v in AppSettings.shared.editorFontSize = v }
                }
                ToggleRow(
                    label: "Ligatures",
                    help: "Joins character pairs like -> and != when the font supports it.",
                    isOn: $fontLigatures
                )
                .onChange(of: fontLigatures) { _, v in AppSettings.shared.editorFontLigatures = v }
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
                    .fixedSize()
                    .onChange(of: tabSize) { _, v in AppSettings.shared.editorTabSize = v }
                }
                ToggleRow(label: "Insert spaces", isOn: $insertSpaces)
                    .onChange(of: insertSpaces) { _, v in AppSettings.shared.editorInsertSpaces = v }
                ToggleRow(
                    label: "Detect indentation",
                    help: "Follows the file's own tabs or spaces and width instead of the two settings above.",
                    isOn: $detectIndentation
                )
                .onChange(of: detectIndentation) { _, v in AppSettings.shared.editorDetectIndentation = v }
                ToggleRow(label: "Word wrap", isOn: $wordWrap)
                    .onChange(of: wordWrap) { _, v in AppSettings.shared.editorWordWrap = v }
            }

            Section(title: "Display") {
                ToggleRow(label: "Line numbers", isOn: $lineNumbers)
                    .onChange(of: lineNumbers) { _, v in AppSettings.shared.editorLineNumbers = v }
                ToggleRow(label: "Minimap", isOn: $minimap)
                    .onChange(of: minimap) { _, v in AppSettings.shared.editorMinimap = v }
                SettingRow(label: "Show whitespace") {
                    menuPicker($renderWhitespace, \.displayName)
                        .onChange(of: renderWhitespace) { _, v in AppSettings.shared.editorRenderWhitespace = v }
                }
                ToggleRow(label: "Colored bracket pairs", isOn: $bracketPairColors)
                    .onChange(of: bracketPairColors) { _, v in AppSettings.shared.editorBracketPairColors = v }
                ToggleRow(
                    label: "Sticky scroll",
                    help: "Keeps the enclosing function or block headers at the top while scrolling.",
                    isOn: $stickyScroll
                )
                .onChange(of: stickyScroll) { _, v in AppSettings.shared.editorStickyScroll = v }
                ToggleRow(
                    label: "Status bar",
                    help: "Cursor position, indentation, encoding, line endings and language below the editor.",
                    isOn: $showStatusStrip
                )
                .onChange(of: showStatusStrip) { _, v in AppSettings.shared.editorShowStatusStrip = v }
                SettingRow(
                    label: "Ruler column",
                    help: "Column where the vertical ruler is drawn. 0 disables the ruler."
                ) {
                    SettingNumberField(
                        value: $rulerColumn,
                        width: 64,
                        onCommit: { v in AppSettings.shared.editorRulerColumn = max(0, v) }
                    )
                }
            }

            Section(title: "Cursor") {
                SettingRow(label: "Style") {
                    menuPicker($cursorStyle, \.displayName)
                        .onChange(of: cursorStyle) { _, v in AppSettings.shared.editorCursorStyle = v }
                }
                ToggleRow(label: "Blink", isOn: $cursorBlinking)
                    .onChange(of: cursorBlinking) { _, v in AppSettings.shared.editorCursorBlinking = v }
            }

            Section(title: "Terminal Links") {
                SettingRow(
                    label: "⌘-click opens",
                    help: "file:line links in terminal output. ⌘⌥-click opens the other one. "
                        + "Remote panes always use the built-in editor."
                ) {
                    Picker("", selection: $linkTarget) {
                        ForEach(LinkTarget.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: linkTarget) { _, v in AppSettings.shared.defaultLinkTarget = v }
                }
                SettingRow(label: "External editor") {
                    Picker("", selection: $editorPreset) {
                        ForEach(ExternalEditorPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: editorPreset) { _, v in AppSettings.shared.externalEditorPreset = v }
                }
                if editorPreset == .custom {
                    SettingRow(
                        label: "Command",
                        help: "A URL or shell command. {path}, {line} and {col} are filled in; "
                            + "paths are quoted for you."
                    ) {
                        SettingTextField(
                            placeholder: "nvim +{line} {path}", text: $editorTemplate, monospaced: true
                        )
                        .onChange(of: editorTemplate) { _, v in AppSettings.shared.externalEditorTemplate = v }
                    }
                }
            }

            Section(
                title: "Saving",
                footer: "Autosave after a delay leaves the text alone; the edits below run on the next "
                    + "explicit save or focus change."
            ) {
                SettingRow(label: "Autosave") {
                    menuPicker($autosave, \.displayName)
                        .onChange(of: autosave) { _, v in AppSettings.shared.editorAutosave = v }
                }
                ToggleRow(
                    label: "Format on save",
                    help: "Uses Monaco's built-in formatters (JSON, JavaScript, TypeScript, CSS, HTML). "
                        + "Other languages are saved as they are.",
                    isOn: $formatOnSave
                )
                .onChange(of: formatOnSave) { _, v in AppSettings.shared.editorFormatOnSave = v }
                ToggleRow(
                    label: "Trim trailing whitespace",
                    help: "Skips Markdown, where two trailing spaces are a line break.",
                    isOn: $trimTrailingWhitespace
                )
                .onChange(of: trimTrailingWhitespace) { _, v in AppSettings.shared.editorTrimTrailingWhitespace = v }
                ToggleRow(label: "Insert final newline", isOn: $insertFinalNewline)
                    .onChange(of: insertFinalNewline) { _, v in AppSettings.shared.editorInsertFinalNewline = v }
                ToggleRow(
                    label: "Reload when changed on disk",
                    help: "Unedited files reload in place. With unsaved edits you choose which version to keep.",
                    isOn: $reloadOnExternalChange
                )
                .onChange(of: reloadOnExternalChange) { _, v in
                    AppSettings.shared.editorReloadOnExternalChange = v
                }
            }
        }
    }

    private func menuPicker<Choice: CaseIterable & Hashable>(
        _ selection: Binding<Choice>, _ name: KeyPath<Choice, String>
    ) -> some View where Choice.AllCases: RandomAccessCollection {
        Picker("", selection: selection) {
            ForEach(Array(Choice.allCases), id: \.self) { Text($0[keyPath: name]).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
