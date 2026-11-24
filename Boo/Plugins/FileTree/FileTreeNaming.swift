import Foundation

/// Validation for names typed into the file tree (create and rename).
enum FileTreeNaming {
    struct Target: Equatable {
        /// Path relative to the folder the name was typed in, components joined by "/".
        let path: String
        /// The input ended in "/": create a folder even from "New File".
        let forcesDirectory: Bool
    }

    /// Clean a typed name. Surrounding whitespace and empty components ("a//b", a leading
    /// "/") are dropped. With `allowNesting`, "a/b/c.txt" is a path whose missing folders
    /// get created; without it any "/" is rejected. Nil for empty input and for "." or ".."
    /// components, so a name can never leave its folder.
    static func target(_ input: String, allowNesting: Bool) -> Target? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !allowNesting && trimmed.contains("/") { return nil }
        let components = trimmed.split(separator: "/").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else { return nil }
        return Target(path: components.joined(separator: "/"), forcesDirectory: trimmed.hasSuffix("/"))
    }
}
