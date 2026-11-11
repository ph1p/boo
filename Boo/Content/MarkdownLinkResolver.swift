import Foundation

/// Resolves local link targets in a markdown preview the way docs sites do:
/// `guide` finds `guide.md`/`guide.mdx`, a directory finds its README or
/// index page, and a site-absolute `/agents` is looked up against each
/// ancestor of the current file up to the repository root.
enum MarkdownLinkResolver {
    /// Pages that open in place in the preview. MDX counts here (docs sites
    /// link between `.mdx` pages) without changing how Boo routes `.mdx` files.
    static let pageExtensions = ContentType.markdownExtensions.union(["mdx"])

    static func isPage(_ path: String) -> Bool {
        pageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The file a link points to, or nil when nothing matches. A directory
    /// without a README or index page resolves to nil.
    static func resolve(_ path: String, from currentFile: String) -> String? {
        if let hit = match(path) { return hit }
        guard path.hasPrefix("/") else { return nil }
        var dir = (currentFile as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if let hit = match(dir + path) { return hit }
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The README or index page of a directory.
    static func indexPage(in directory: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for stem in ["readme", "index"] {
            if let name = names.sorted().first(where: {
                ($0 as NSString).deletingPathExtension.lowercased() == stem && isPage($0)
            }) {
                return (directory as NSString).appendingPathComponent(name)
            }
        }
        return nil
    }

    private static func match(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? indexPage(in: path) : path
        }
        let stem = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard (stem as NSString).pathExtension.isEmpty else { return nil }
        return ["md", "mdx", "markdown"].lazy.map { "\(stem).\($0)" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}
