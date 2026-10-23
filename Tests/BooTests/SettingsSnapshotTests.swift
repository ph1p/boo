import SwiftUI
import XCTest

@testable import Boo

/// Renders every settings page to PNG for eyeballing. Skipped unless
/// `BOO_SNAPSHOT_DIR` is set.
@MainActor final class SettingsSnapshotTests: XCTestCase {
    func testRenderEveryPage() throws {
        guard let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set BOO_SNAPSHOT_DIR to render settings pages")
        }
        let theme = AppSettings.shared.theme
        let tokens = Tokens(theme: theme)
        let pages: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsView())),
            ("theme", AnyView(ThemeSettingsView())),
            ("appearance", AnyView(AppearanceSettingsView())),
            ("statusbar", AnyView(StatusBarSettingsView())),
            ("layout", AnyView(LayoutSettingsView())),
            ("profiles", AnyView(ProfilesSettingsView())),
            ("rules", AnyView(RulesSettingsView())),
            ("recordings", AnyView(RecordingsSettingsView())),
            ("editor", AnyView(EditorSettingsView())),
            ("browser", AnyView(BrowserSettingsView())),
            ("notifications", AnyView(NotificationsSettingsView())),
            ("plugins", AnyView(PluginSettingsView())),
            ("shortcuts", AnyView(ShortcutsSettingsView()))
        ]
        let size = NSSize(
            width: 566, height: Double(ProcessInfo.processInfo.environment["BOO_SNAPSHOT_H"] ?? "") ?? 1400)
        for (name, page) in pages {
            let root = page.frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(tokens.bg)
                .environment(\.tokens, tokens)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(name).png"))
        }
    }
}
