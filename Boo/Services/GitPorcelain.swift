import Foundation

/// `git status --porcelain=v1 -z` output.
enum GitPorcelain {
    struct Record: Equatable {
        /// Index and work-tree status columns.
        var x: Character
        var y: Character
        /// Relative to the repository root, as git prints it.
        var path: String
    }

    nonisolated static func records(_ output: String) -> [Record] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true)
        var records: [Record] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            guard field.count >= 4 else { continue }
            let x = field[field.startIndex]
            // Renames/copies carry the original path in the next NUL field.
            if x == "R" || x == "C" { i += 1 }
            records.append(
                Record(x: x, y: field[field.index(after: field.startIndex)], path: String(field.dropFirst(3))))
        }
        return records
    }
}
