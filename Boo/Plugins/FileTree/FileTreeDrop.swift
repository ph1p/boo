import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag State

/// Drag & drop state — tracks drop target position and auto-expand timer.
final class FileTreeDragState: ObservableObject {
    enum DropPosition: Equatable {
        case onFolder(String)
        case abovePath(String)
    }

    @Published var dropPosition: DropPosition?
    @Published var draggedPath: String?
    /// The row dragged most recently. Unlike `draggedPath` it survives the drop, so a
    /// drop can tell a row moved inside the tree from text dragged in from elsewhere.
    private(set) var lastDraggedPath: String?
    var expandTimer: DispatchWorkItem?
    var exitTimer: DispatchWorkItem?
    /// Set after performDrop — suppresses all further state changes until the
    /// next drag starts, preventing stale indicators from late delegate calls.
    private var dropped = false

    func clear() {
        dropped = true
        dropPosition = nil
        draggedPath = nil
        expandTimer?.cancel()
        expandTimer = nil
        exitTimer?.cancel()
        exitTimer = nil
    }

    func entered() {
        guard !dropped else { return }
        exitTimer?.cancel()
        exitTimer = nil
    }

    func exited() {
        guard !dropped else { return }
        expandTimer?.cancel()
        expandTimer = nil
        exitTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dropPosition = nil
            self?.draggedPath = nil
        }
        exitTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func setPosition(_ pos: DropPosition?) {
        guard !dropped else { return }
        if dropPosition != pos { dropPosition = pos }
    }

    func beginDrag(path: String) {
        dropped = false
        draggedPath = path
        lastDraggedPath = path
    }
}

// MARK: - Drop Delegates

private let rowHeight: CGFloat = 22

/// Types the tree accepts: file URLs (Finder, local rows) and the plain-text path a
/// remote row drags.
let fileTreeDropTypes: [UTType] = [.fileURL, .plainText]

@MainActor private final class DropUploadBatch {
    var paths: [String] = []
}

/// Move dropped rows into the target directory. Files from Finder are uploaded when the
/// tree supports it (remote), and moved otherwise.
private func executeDrop(info: DropInfo, target: String, dragState: FileTreeDragState, actions: FileTreeActions) {
    let internalPath = dragState.lastDraggedPath
    dragState.clear()
    // Uploads are collected so a multi-file drop is one transfer, not one per file.
    let group = DispatchGroup()
    let uploads = DropUploadBatch()
    for provider in info.itemProviders(for: [.fileURL]) {
        group.enter()
        provider.loadObject(ofClass: NSURL.self) { item, _ in
            let path = (item as? URL)?.path
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { group.leave() }
                    guard let path else { return }
                    if actions.onUpload != nil {
                        uploads.paths.append(path)
                    } else {
                        actions.onMove?(path, target)
                    }
                }
            }
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated {
            guard !uploads.paths.isEmpty else { return }
            actions.onUpload?(uploads.paths, target)
        }
    }
    // Text only counts as a move when it is the row this tree just dragged; anything
    // else dropped as text is ignored.
    for provider in info.itemProviders(for: [.plainText])
    where !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let path = item as? String else { return }
            DispatchQueue.main.async {
                guard path == internalPath else { return }
                actions.onMove?(path, target)
            }
        }
    }
}

/// Copy for a Finder drop into an uploading tree, move for everything else.
private func dropProposal(_ info: DropInfo, actions: FileTreeActions) -> DropProposal {
    let uploading = actions.onUpload != nil && info.hasItemsConforming(to: [.fileURL])
    return DropProposal(operation: uploading ? .copy : .move)
}

/// Returns false if `path` is the dragged item or a descendant of it.
private func isValidDropTarget(_ path: String, dragState: FileTreeDragState) -> Bool {
    guard dragState.draggedPath != path else { return false }
    if let d = dragState.draggedPath, path.hasPrefix(d + "/") { return false }
    return true
}

/// Per-row drop delegate. Folders: top quarter = line above, rest = into folder.
/// Files: always line above (into parent dir).
struct RowDropDelegate: DropDelegate {
    let node: FileTreeNode
    let parentPath: String
    let dragState: FileTreeDragState
    let actions: FileTreeActions
    let rootPath: String

    func validateDrop(info: DropInfo) -> Bool {
        isValidDropTarget(node.path, dragState: dragState)
    }

    func dropEntered(info: DropInfo) {
        dragState.entered()
        update(info)
        if node.isDirectory && !node.isExpanded {
            dragState.expandTimer?.cancel()
            let path = node.path
            let timer = DispatchWorkItem { [weak node] in
                guard let node, !node.isExpanded, dragState.dropPosition == .onFolder(path) else { return }
                node.expand()
            }
            dragState.expandTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timer)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return dropProposal(info, actions: actions)
    }

    func dropExited(info: DropInfo) { dragState.exited() }

    func performDrop(info: DropInfo) -> Bool {
        let target: String
        switch dragState.dropPosition {
        case .onFolder(let p): target = p
        case .abovePath: target = parentPath
        case .none: target = rootPath
        }
        executeDrop(info: info, target: target, dragState: dragState, actions: actions)
        return true
    }

    private func update(_ info: DropInfo) {
        guard isValidDropTarget(node.path, dragState: dragState) else {
            dragState.setPosition(nil)
            return
        }
        let fraction = max(0, min(1, info.location.y / rowHeight))
        if node.isDirectory && fraction >= 0.25 {
            dragState.setPosition(.onFolder(node.path))
        } else {
            dragState.setPosition(.abovePath(node.path))
        }
    }
}

/// Root-level drop delegate for the background / empty space — drops into root dir.
struct RootDropDelegate: DropDelegate {
    let dragState: FileTreeDragState
    let actions: FileTreeActions
    let rootPath: String

    func dropEntered(info: DropInfo) { dragState.entered() }
    func dropUpdated(info: DropInfo) -> DropProposal? { dropProposal(info, actions: actions) }
    func dropExited(info: DropInfo) { dragState.exited() }

    func performDrop(info: DropInfo) -> Bool {
        executeDrop(info: info, target: rootPath, dragState: dragState, actions: actions)
        return true
    }
}
