import Foundation
import SwiftUI

/// Type-safe payload for tab creation via plugin API.
enum TabPayload {
    /// Open a terminal tab with the given working directory.
    case terminal(workingDirectory: String)

    /// Open a terminal tab and run a command.
    case terminalWithCommand(workingDirectory: String, command: String)

    /// Open a browser tab with the given URL.
    case browser(url: URL)

    /// Open a file in the appropriate viewer (markdown, image, etc.).
    /// Routing respects user settings (e.g., markdownOpenMode).
    case file(path: String)

    /// Open a custom SwiftUI view in a new tab.
    /// The view is ephemeral — it is not persisted across app restarts.
    case customView(title: String, icon: String, view: AnyView)
}
