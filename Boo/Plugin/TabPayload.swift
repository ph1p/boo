import Foundation

/// Type-safe payload for tab creation via plugin API.
enum TabPayload {
    /// Open a terminal tab with the given working directory.
    case terminal(workingDirectory: String)

    /// Open a browser tab with the given URL.
    case browser(url: URL)

    /// Open a file in the appropriate viewer (markdown, image, etc.).
    /// Routing respects user settings (e.g., markdownOpenMode).
    case file(path: String)
}
