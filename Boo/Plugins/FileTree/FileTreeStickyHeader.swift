import SwiftUI

/// The first tree row in view, for the sticky folder header.
///
/// Kept by `FileTreeView` in `@State` (not observed there) and observed only by the
/// header, so scrolling past a row re-renders the few pinned rows, not the whole tree.
@MainActor
final class FileTreeStickyState: ObservableObject {
    @Published private(set) var topIndex = 0

    func update(topIndex: Int) {
        if topIndex != self.topIndex { self.topIndex = topIndex }
    }
}

enum FileTreeSticky {
    /// Deeper trees pin only their innermost folders, so the header can't eat the list.
    static let maxRows = 5

    /// The open folders to pin above the tree when `topIndex` is the first row in view.
    ///
    /// A header of `k` rows covers the top `k` rows in view, so the row that needs the
    /// context is the one just below it. Take the smallest `k` whose uncovered row needs
    /// at most `k` pinned folders, and pin that row's folders.
    static func pinnedRows(_ rows: [FileTreeView.FlatRow], topIndex: Int) -> [FileTreeView.FlatRow] {
        guard !rows.isEmpty else { return [] }
        for covered in 0...maxRows {
            let index = min(topIndex + covered, rows.count - 1)
            let folders = ancestors(of: index, in: rows).suffix(maxRows)
            if folders.count <= covered { return Array(folders) }
        }
        return []  // Unreachable: at `maxRows` covered rows the capped list always fits.
    }

    /// The top row that shows `rows[index]` just below its pinned folders.
    ///
    /// Scrolling the row itself to the top would hide it under its own folders. Take the
    /// smallest lift `c` whose header (pinned for top row `index - c`) fits in `c` rows.
    static func topIndex(revealing index: Int, in rows: [FileTreeView.FlatRow]) -> Int {
        for lift in 0...min(index, maxRows) where pinnedRows(rows, topIndex: index - lift).count <= lift {
            return index - lift
        }
        return max(0, index - maxRows)
    }

    /// Whether `rows[index]` sits under the header when `topIndex` is the first row in view.
    static func isCovered(_ index: Int, in rows: [FileTreeView.FlatRow], topIndex: Int) -> Bool {
        index < topIndex + pinnedRows(rows, topIndex: topIndex).count
    }

    /// Ancestor folder rows of `rows[index]`, outermost first.
    private static func ancestors(of index: Int, in rows: [FileTreeView.FlatRow]) -> [FileTreeView.FlatRow] {
        var result: [FileTreeView.FlatRow] = []
        var parent = rows[index].parentIndex
        while let i = parent {
            result.append(rows[i])
            parent = rows[i].parentIndex
        }
        return result.reversed()
    }
}

/// Pins the open parent folders of the rows in view to the top of the tree.
struct FileTreeStickyHeader: View {
    @ObservedObject var state: FileTreeStickyState
    let rows: [FileTreeView.FlatRow]
    var style: RowStyle
    var git: FileTreeGitStatus?
    var background: Color
    var separator: Color
    var onSelect: (FileTreeView.FlatRow) -> Void

    var body: some View {
        let pinned = FileTreeSticky.pinnedRows(rows, topIndex: state.topIndex)
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pinned) { row in
                    FileTreeStickyRow(
                        row: row, style: style, gitStatus: git?.status(for: row.node.path, isDirectory: true)
                    ) { onSelect(row) }
                }
            }
            .padding(.bottom, 2)
            .background(background.shadow(.drop(color: .black.opacity(0.12), radius: 3, y: 1)))
            .overlay(alignment: .bottom) {
                Rectangle().fill(separator).frame(height: 1)
            }
        }
    }
}

/// A pinned folder: the tree row's look without its drag, drop and menu machinery.
private struct FileTreeStickyRow: View {
    let row: FileTreeView.FlatRow
    var style: RowStyle
    var gitStatus: FileGitStatus?
    var onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(style.mutedColor)
                .frame(width: 10)
            if style.showIcons {
                FileTreeIcon(name: row.node.name, isDirectory: true, style: style)
            }
            Text(row.node.name)
                .font(style.font)
                .foregroundStyle(style.nameColor(for: gitStatus))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.leading, RowStyle.indent(depth: row.depth))
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(style.rowBackground(selected: false, focused: false, hovered: isHovered))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .help(row.node.path)
    }
}
