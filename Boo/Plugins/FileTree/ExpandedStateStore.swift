import Foundation

/// Remembers which folders are open in a file tree, keyed by the same key the
/// plugin caches its root nodes under (a local path, or `"host:path"` for remote).
///
/// Keyed by root, not by terminal: root nodes are cached per root and shared by every
/// tab showing that directory, so per-terminal keys would fight the shared nodes
/// (switching tabs in the same directory would collapse folders the other tab opened).
/// Root keys also mean navigating away and back — or a root evicted from the node
/// cache — restores the same open folders.
///
/// Both file-tree plugins own one of these; the mechanics (snapshot the roots we're
/// leaving, prune keys that carry no information, restore only on a real context
/// switch) are identical whether the tree is local or remote.
struct ExpandedStateStore {
    private var expanded: [String: Set<String>] = [:]

    /// Previously open folders for a root, or nil if that root has never had any.
    func paths(for key: String) -> Set<String>? { expanded[key] }

    /// Snapshot the live expansion of every root except `keptKey`, whose on-screen
    /// state is still authoritative and must not be frozen.
    ///
    /// A root with nothing open carries no information, so its key is dropped rather
    /// than kept — otherwise collapsed directories accumulate entries for the lifetime
    /// of the process.
    mutating func snapshot<Node>(
        roots: [String: Node], except keptKey: String? = nil, expandedPaths: (Node) -> Set<String>
    ) {
        for (key, root) in roots where key != keptKey {
            let paths = expandedPaths(root)
            if paths.isEmpty {
                expanded.removeValue(forKey: key)
            } else {
                expanded[key] = paths
            }
        }
    }
}
