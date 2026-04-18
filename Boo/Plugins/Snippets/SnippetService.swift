import Foundation

/// Manages terminal command snippets, persisted to ~/.boo/snippets.json.
final class SnippetService {
    nonisolated(unsafe) static let shared = SnippetService()

    struct Snippet: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        var command: String
        var description: String

        init(name: String, command: String, description: String = "") {
            self.id = UUID()
            self.name = name
            self.command = command
            self.description = description
        }
    }

    private(set) var snippets: [Snippet] = []

    private var filePath: String {
        (BooPaths.configDir as NSString).appendingPathComponent("snippets.json")
    }

    private init() {
        load()
    }

    func add(name: String, command: String, description: String = "") {
        let snippet = Snippet(name: name, command: command, description: description)
        snippets.append(snippet)
        save()
    }

    func update(id: UUID, name: String, command: String, description: String) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[idx].name = name
        snippets[idx].command = command
        snippets[idx].description = description
        save()
    }

    func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func move(from: Int, to: Int) {
        guard from >= 0, from < snippets.count, to >= 0, to < snippets.count else { return }
        let item = snippets.remove(at: from)
        snippets.insert(item, at: to)
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snippets)
            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            debugLog("[Snippets] Failed to save: \(error)")
            DispatchQueue.main.async {
                BooAlert.showTransient("Snippets could not be saved")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
            let saved = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = saved
    }
}
