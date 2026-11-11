import Cocoa

/// Content that searches its own page from the pane's find bar (⌘F).
/// `onFindMatches` reports `(selected, total)`: selected is 0-based or -1,
/// total is -1 for an empty query and 0 when nothing matched.
@MainActor
protocol PageFindable: AnyObject {
    var onFindMatches: ((Int, Int) -> Void)? { get set }
    func find(_ needle: String)
    func findNext(_ forward: Bool)
    func endFind()
}

extension BrowserContentView: PageFindable {}
