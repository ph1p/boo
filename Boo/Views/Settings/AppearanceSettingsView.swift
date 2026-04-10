import SwiftUI

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @State private var cursorStyle = AppSettings.shared.cursorStyle
    @State private var termFontSize = Double(AppSettings.shared.fontSize)
    @State private var termSelectedFont = AppSettings.shared.fontName
    @State private var sidebarFontSize = Double(AppSettings.shared.sidebarFontSize)
    @State private var sidebarSelectedFont =
        AppSettings.shared.sidebarFontName.isEmpty ? "System Default" : AppSettings.shared.sidebarFontName
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .terminal, .sidebarFont])

    private let monoFonts = AppSettings.availableMonospaceFonts
    private let systemFonts = AppSettings.availableSystemFonts

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Appearance") {
            Section(title: "Cursor") {
                Picker("", selection: $cursorStyle) {
                    ForEach(CursorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: cursorStyle) { v in AppSettings.shared.cursorStyle = v }
            }

            Section(title: "Terminal Font") {
                FontChooser(selectedFont: $termSelectedFont, fonts: monoFonts)
                    .onChange(of: termSelectedFont) { v in AppSettings.shared.fontName = v }
                FontSizePicker(value: $termFontSize, range: 10...28)
                    .onChange(of: termFontSize) { v in AppSettings.shared.fontSize = CGFloat(v) }
                Text("$ echo \"Hello, Boo\"")
                    .font(.custom(termSelectedFont, size: CGFloat(termFontSize)))
                    .foregroundColor(t.fg)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.termBg))
            }

            Section(title: "Sidebar Font") {
                FontChooser(selectedFont: $sidebarSelectedFont, fonts: systemFonts)
                    .onChange(of: sidebarSelectedFont) { v in
                        AppSettings.shared.sidebarFontName = v == "System Default" ? "" : v
                    }
                FontSizePicker(value: $sidebarFontSize, range: 10...20)
                    .onChange(of: sidebarFontSize) { v in AppSettings.shared.sidebarFontSize = CGFloat(v) }
                Text("Applied to file trees and content only — not to section headers.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Section Header")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(t.muted)
                    let previewFont: Font = {
                        let name = sidebarSelectedFont == "System Default" ? "" : sidebarSelectedFont
                        if name.isEmpty { return .system(size: CGFloat(sidebarFontSize)) }
                        return .custom(name, size: CGFloat(sidebarFontSize))
                    }()
                    Text("  Documents")
                        .font(previewFont)
                        .foregroundColor(t.text)
                    Text("  Projects")
                        .font(previewFont)
                        .foregroundColor(t.text)
                    Text("  README.md")
                        .font(previewFont)
                        .foregroundColor(t.muted)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.chromeBg))
            }
        }
        .foregroundColor(t.text)
    }
}
