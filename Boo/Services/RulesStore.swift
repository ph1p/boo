import Foundation

extension Notification.Name {
    /// `~/.boo/rules.json` was (re)loaded, or a rule was suspended or resumed.
    static let rulesChanged = Notification.Name("BooRulesChanged")
}

/// Rules from `~/.boo/rules.json`, reloaded when the file changes. A file
/// that fails to parse keeps the last good rules.
@MainActor
final class RulesStore {
    static let shared = RulesStore(path: BooPaths.rulesFile)

    let path: String
    /// Everything the file defines, including suspended rules.
    private(set) var all: RuleSet = .empty
    /// Why the file (or some of its rules) couldn't be used; empty when fine.
    private(set) var problems: [String] = []
    /// Rules the loop guard switched off until resumed or the file changes.
    private(set) var suspended: Set<String> = []
    private let file: WatchedFile
    private var started = false

    init(path: String) {
        self.path = path
        self.file = WatchedFile(path: path)
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
        file.start { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The rules in effect: enabled and not suspended.
    var active: RuleSet {
        suspended.isEmpty ? all : RuleSet(rules: all.rules.filter { !suspended.contains($0.id) })
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: path) else {
            update(all: .empty, problems: [])
            return
        }
        do {
            let parsed = try RuleSet.parse(data)
            update(all: parsed.set, problems: parsed.problems)
        } catch let error as RuleSet.ParseError {
            update(all: all, problems: [error.message])
        } catch {
            update(all: all, problems: [error.localizedDescription])
        }
    }

    /// The file's text, or a starter example when there is none.
    func text() -> String {
        if let data = FileManager.default.contents(atPath: path), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return Self.example
    }

    /// Validates and writes `text`. Throws (and writes nothing) when it is not
    /// a rules file at all; individual bad rules are reported in `problems`.
    func save(text: String) throws {
        let data = Data(text.utf8)
        _ = try RuleSet.parse(data)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        file.noteOwnWrite()
        reload()
    }

    func suspend(_ id: String) {
        guard suspended.insert(id).inserted else { return }
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func resume(_ id: String) {
        guard suspended.remove(id) != nil else { return }
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    private func update(all: RuleSet, problems: [String]) {
        let changed = all != self.all || problems != self.problems || !suspended.isEmpty
        self.all = all
        self.problems = problems
        // Editing the file is the way to fix a runaway rule; start fresh.
        suspended.removeAll()
        if !problems.isEmpty { booLog(.warning, .app, "[Rules] \(problems.joined(separator: "; "))") }
        if changed { NotificationCenter.default.post(name: .rulesChanged, object: nil) }
    }

    static let example = """
        {
          "rules": [
            {
              "id": "prod-ssh",
              "when": { "host": "*.prod.example.com" },
              "then": { "profile": "Production" }
            },
            {
              "id": "tests-failed",
              "when": { "output": "(\\\\d+) tests? failed" },
              "then": [{ "notify": { "title": "Tests failed", "body": "$1 failing" } }, { "markTab": {} }],
              "enabled": false
            }
          ]
        }

        """
}
