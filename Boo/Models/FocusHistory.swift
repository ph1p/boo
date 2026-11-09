import Foundation

/// One place the user focused: a tab in a pane in a workspace.
struct FocusLocation: Equatable {
    let workspaceID: UUID
    let paneID: UUID
    let tabID: UUID?
}

/// Back/forward list of focused places, like a browser's: recording a new
/// place drops everything after the current one. Per window, in memory only.
struct FocusHistory {
    static let limit = 50

    private(set) var entries: [FocusLocation] = []
    /// Index of the current place in `entries`; -1 while empty.
    private(set) var index = -1
    /// Set while back/forward focus a place, so that move is not recorded.
    var isNavigating = false

    var current: FocusLocation? { entries.indices.contains(index) ? entries[index] : nil }

    mutating func record(_ location: FocusLocation) {
        guard !isNavigating, location != current else { return }
        entries = Array(entries.prefix(index + 1)) + [location]
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// The nearest earlier (step -1) or later (step 1) place that still
    /// exists, made current; nil when there is none.
    mutating func move(by step: Int, isValid: (FocusLocation) -> Bool) -> FocusLocation? {
        var candidate = index + step
        while entries.indices.contains(candidate) {
            if isValid(entries[candidate]) {
                index = candidate
                return entries[candidate]
            }
            candidate += step
        }
        return nil
    }
}
