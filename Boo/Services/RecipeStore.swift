import Foundation

/// Reads and writes recipe files in `~/.boo/recipes/`.
enum RecipeStore {
    struct Entry: Equatable {
        /// The file name without `.json`, used to run it by name.
        let name: String
        let path: String
    }

    static func list(in directory: String = BooPaths.recipesDir) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Entry(name: String($0.dropLast(5)), path: (directory as NSString).appendingPathComponent($0)) }
    }

    static func entry(named name: String, in directory: String = BooPaths.recipesDir) throws -> Entry {
        let all = list(in: directory)
        guard
            let entry = all.first(where: { $0.name == name })
                ?? all.first(where: { $0.name.lowercased() == name.lowercased() })
        else { throw RecipeError.notFound(name, available: all.map(\.name)) }
        return entry
    }

    static func load(_ path: String) throws -> Recipe {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw RecipeError.invalid(path: path, reason: "cannot be read")
        }
        do {
            return try JSONDecoder().decode(Recipe.self, from: data)
        } catch let error as DecodingError {
            throw RecipeError.invalid(path: path, reason: describe(error))
        } catch {
            throw RecipeError.invalid(path: path, reason: "not JSON")
        }
    }

    /// Writes `recipe` as `<name>.json`, replacing a file of that name.
    @discardableResult
    static func save(_ recipe: Recipe, as name: String, in directory: String = BooPaths.recipesDir) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent(fileName(for: name))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(recipe).write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    /// A file name safe on disk: path separators and leading dots removed.
    static func fileName(for name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        return (base.isEmpty ? "recipe" : base) + ".json"
    }

    /// "layout.b.split: split must be …" rather than Foundation's dump.
    static func describe(_ error: DecodingError) -> String {
        func at(_ path: [CodingKey]) -> String {
            let joined = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
            return joined.isEmpty ? "" : "\(joined): "
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(at(context.codingPath))missing \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            return "\(at(context.codingPath))expected \(type)"
        case .valueNotFound(let type, let context):
            return "\(at(context.codingPath))expected \(type)"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not JSON" : "\(at(context.codingPath))\(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
