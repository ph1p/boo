import SwiftUI

struct EditorSettingsView: View {
    @State private var fontSize = AppSettings.shared.editorFontSize
    @State private var fontName = AppSettings.shared.editorFontName
    @ObservedObject private var observer = SettingsObserver(topics: [.editor])

    private let monoFonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Editor") {
            Section(title: "Font") {
                HStack(spacing: 8) {
                    Text("Family")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .frame(width: 80, alignment: .leading)
                    FontChooser(selectedFont: $fontName, fonts: monoFonts)
                        .frame(maxWidth: 200)
                        .onChange(of: fontName) { _, v in
                            AppSettings.shared.editorFontName = v
                        }
                }

                HStack(spacing: 8) {
                    Text("Size")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .frame(width: 80, alignment: .leading)
                    FontSizePicker(
                        value: Binding(
                            get: { Double(fontSize) },
                            set: { fontSize = CGFloat($0) }
                        ), range: 9...24
                    )
                    .frame(maxWidth: 200)
                    .onChange(of: fontSize) { _, v in
                        AppSettings.shared.editorFontSize = v
                    }
                }
            }
        }
    }
}
