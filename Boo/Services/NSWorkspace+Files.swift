import Cocoa

extension NSWorkspace {
    /// Opens the file or folder at `path` in its default app.
    func open(path: String) {
        open(URL(fileURLWithPath: path))
    }

    /// Shows the files at `paths` selected in a Finder window.
    func revealInFinder(_ paths: [String]) {
        activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }
}
