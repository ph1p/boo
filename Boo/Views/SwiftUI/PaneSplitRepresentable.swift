import AppKit
import SwiftUI

/// Bridges an existing AppKit SplitContainerView into SwiftUI layout.
/// The view is created/owned by MainWindowController; this representable just hosts it.
@MainActor
struct PaneSplitRepresentable: NSViewRepresentable {
    let splitContainer: SplitContainerView

    func makeNSView(context: Context) -> SplitContainerView { splitContainer }
    func updateNSView(_ nsView: SplitContainerView, context: Context) {}
}
