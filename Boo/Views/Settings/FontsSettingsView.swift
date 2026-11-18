import SwiftUI

// MARK: - Fonts

/// Every font Boo lets you pick, on one page: the terminal, the editor, the
/// sidebar (file trees and plugin content) and the app chrome. Profiles can
/// still override the terminal font per profile.
///
/// Rows bind straight to `AppSettings`; the observer re-renders the page when
/// a font changes, so a value set elsewhere (sync, the one-font toggle) shows here.
struct FontsSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [
        .theme, .terminal, .editor, .sidebarFont, .appFont
    ])

    // Built once: listing installed families is slow, and they rarely change.
    private static let monoFonts = AppSettings.availableMonospaceFonts
    private static let systemFonts = AppSettings.availableSystemFonts

    var body: some View {
        let _ = observer.revision
        let unified = AppSettings.shared.useOneFontEverywhere
        SettingsPage(title: "Fonts") {
            Section(title: "All Fonts") {
                ToggleRow(
                    label: "Use one font everywhere",
                    help: "Editor, sidebar and app use the terminal's family. Sizes stay separate.",
                    isOn: SettingsBindings.binding(\.useOneFontEverywhere)
                )
            }

            Section(title: "Terminal") {
                SettingRow(
                    label: "Family",
                    help: unified ? "Used everywhere. Profiles can override it." : "Profiles can override it."
                ) {
                    FontChooser(selectedFont: SettingsBindings.binding(\.fontName), fonts: Self.monoFonts)
                }
                SettingRow(label: "Size") {
                    FontSizePicker(value: SettingsBindings.size(\.fontSize), range: 10...28)
                }
            }

            Section(title: "Editor") {
                if !unified {
                    SettingRow(label: "Family") {
                        FontChooser(selectedFont: SettingsBindings.binding(\.editorFontName), fonts: Self.monoFonts)
                    }
                }
                SettingRow(label: "Size") {
                    FontSizePicker(value: SettingsBindings.size(\.editorFontSize), range: 9...24)
                }
                ToggleRow(
                    label: "Ligatures",
                    help: "Joins character pairs like -> and != when the font supports it.",
                    isOn: SettingsBindings.binding(\.editorFontLigatures)
                )
            }

            Section(title: "Sidebar") {
                if !unified {
                    SettingRow(label: "Family") {
                        FontChooser(
                            selectedFont: SettingsBindings.systemFont(\.sidebarFontName), fonts: Self.systemFonts)
                    }
                }
                SettingRow(
                    label: "Size",
                    help: "Applied to file trees and content only — not to section headers."
                ) {
                    FontSizePicker(value: SettingsBindings.size(\.sidebarFontSize), range: 10...20)
                }
            }

            if !unified {
                Section(title: "App") {
                    SettingRow(
                        label: "Family",
                        help: "Tab bars, workspace bar, toolbar, status bar, palette and find bar."
                    ) {
                        FontChooser(selectedFont: SettingsBindings.systemFont(\.appFontName), fonts: Self.systemFonts)
                    }
                }
            }
        }
        .foregroundStyle(tokens.text)
    }
}
