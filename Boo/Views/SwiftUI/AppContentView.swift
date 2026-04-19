import AppKit
import SwiftUI

/// Placeholder — will host NavigationSplitView with plugin sidebar once main window migration resumes.
@MainActor
struct AppContentView: View {
    let splitContainer: SplitContainerView

    @Environment(AppState.self) private var appState
    @Environment(WindowStateCoordinator.self) private var coordinator

    var body: some View {
        PaneSplitRepresentable(splitContainer: splitContainer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
