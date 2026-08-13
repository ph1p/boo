import Cocoa
import SwiftUI

/// Protocol for views that can be hosted in a tab.
/// Each content type (terminal, browser, etc.) implements this protocol.
protocol ContentViewProtocol: NSView {
    /// The type of content this view displays.
    var contentType: ContentType { get }

    /// Called when the view becomes the active tab.
    func activate()

    /// Called when the view is no longer the active tab (but may be restored later).
    func deactivate()

    /// Called when the view is being permanently removed.
    func cleanup()

    /// Save the current state for persistence.
    func saveState() -> ContentState

    /// Restore state from a previous session.
    func restoreState(_ state: ContentState)

    // MARK: - Callbacks

    /// Called when the view's title changes.
    var onTitleChanged: ((String) -> Void)? { get set }

    /// Called when the view gains focus.
    var onFocused: (() -> Void)? { get set }

    /// Called when the content requests to close (e.g., process exit).
    var onCloseRequested: (() -> Void)? { get set }

    /// Save the content to disk if applicable.
    func save(completion: ((Bool) -> Void)?)
}

extension ContentViewProtocol {
    func save(completion: ((Bool) -> Void)?) {
        completion?(true)
    }
}

/// Key for `ContentViewProtocol.tabID`'s associated-object storage.
private nonisolated(unsafe) var contentViewTabIDKey: UInt8 = 0

extension ContentViewProtocol {
    /// The tab this view belongs to, stamped when the view is adopted by a pane.
    ///
    /// Mirrors `GhosttyView.tabID` so both view kinds are self-identifying: a pane can cache
    /// or retire a displayed view without a side table saying which tab owns it.
    ///
    /// `pane.activeTab` is NOT a safe substitute. A cross-pane drop inserts the incoming tab
    /// (shifting activeTabIndex) *before* `forceActivateTab` re-displays, so in that window
    /// the displayed view belongs to the previous tab while `pane.activeTab` already names the
    /// incoming one — caching under that id overwrote the just-transferred view and the
    /// dragged tab's content was lost.
    ///
    /// Backed by an associated object rather than a protocol requirement so conformers need
    /// no stored property (and no initializer changes).
    var tabID: UUID? {
        get { objc_getAssociatedObject(self, &contentViewTabIDKey) as? UUID }
        set {
            objc_setAssociatedObject(self, &contentViewTabIDKey, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

/// Factory for creating content views based on content type.
@MainActor
enum ContentViewFactory {
    /// Create a content view for the given state.
    static func createView(for state: ContentState) -> ContentViewProtocol {
        switch state {
        case .terminal(let terminalState):
            return TerminalContentView(workingDirectory: terminalState.workingDirectory)
        case .browser(let browserState):
            return BrowserContentView(url: browserState.url)
        case .editor(let editorState):
            return EditorContentView(filePath: editorState.filePath)
        case .imageViewer(let imageState):
            return ImageViewerContentView(filePath: imageState.filePath)
        case .markdownPreview(let markdownState):
            return MarkdownPreviewContentView(filePath: markdownState.filePath)
        case .pluginView(let pluginState):
            // Plugin views are ephemeral; restore shows a placeholder.
            return PluginTabContentView(
                view: AnyView(PluginViewPlaceholder()),
                title: pluginState.title,
                icon: pluginState.iconSymbol
            )
        }
    }

    /// Create a default content view for a content type.
    static func createDefaultView(for type: ContentType, workingDirectory: String = "~") -> ContentViewProtocol {
        switch type {
        case .terminal:
            return TerminalContentView(workingDirectory: workingDirectory)
        case .browser:
            return BrowserContentView(url: ContentType.newTabURL)
        case .editor:
            return EditorContentView(filePath: nil)
        case .imageViewer:
            return ImageViewerContentView(filePath: nil)
        case .markdownPreview:
            return MarkdownPreviewContentView(filePath: nil)
        case .pluginView:
            return PluginTabContentView(view: AnyView(PluginViewPlaceholder()), title: "Panel")
        }
    }
}

// MARK: - Placeholder

private struct PluginViewPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Panel unavailable")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
