import Cocoa
import SwiftUI

/// ContentViewProtocol implementation that hosts a plugin-provided SwiftUI view in a tab.
/// The view is ephemeral — state is not persisted across app restarts.
final class PluginTabContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .pluginView

    private let hostingView: NSHostingView<AnyView>
    private let tabTitle: String
    private let iconSymbol: String

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    // MARK: - Init

    init(view: AnyView, title: String, icon: String = "puzzlepiece") {
        self.tabTitle = title
        self.iconSymbol = icon
        self.hostingView = NSHostingView(rootView: AnyView(PluginTabThemeHost(content: view)))
        super.init(frame: .zero)
        wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(self)
        onFocused?()
    }

    func deactivate() {}

    func cleanup() {
        hostingView.removeFromSuperview()
    }

    func saveState() -> ContentState {
        .pluginView(PluginViewContentState(title: tabTitle, iconSymbol: iconSymbol))
    }

    func restoreState(_ state: ContentState) {
        // Plugin views are ephemeral — nothing to restore.
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
}

/// Hands plugin tab views the current theme as `\.tokens` and repaints them
/// on theme switches, which they would otherwise miss (tabs outlive them).
private struct PluginTabThemeHost: View {
    let content: AnyView
    @StateObject private var settings = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = settings.revision
        content.environment(\.tokens, .current)
    }
}
