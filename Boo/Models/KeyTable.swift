import Cocoa

/// A key plus the modifiers that matter for it. Printable keys are matched by
/// the character they type ("V" is shift+v, "|" is shift+\), so shift is part
/// of `key` there; named keys ("escape", "left"…) keep shift in `modifiers`.
struct KeyChord: Hashable {
    let key: String
    let modifiers: UInt

    static let namedKeys: [String: UInt16] = [
        "escape": 53, "tab": 48, "return": 36, "space": 49, "backspace": 51,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
    private static let aliases = ["esc": "escape", "enter": "return", "delete": "backspace"]
    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "ctrl": .control, "control": .control, "opt": .option, "option": .option, "alt": .option,
        "cmd": .command, "command": .command, "shift": .shift
    ]

    init(key: String, modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers.intersection([.control, .option, .command, .shift]).rawValue
    }

    /// Parses "ctrl+a", "V", "shift+tab", "+"; nil for anything else.
    init?(spec: String) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec == "+" || spec.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }  // "ctrl++"
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            guard let flag = Self.modifierNames[part.lowercased()] else { return nil }
            flags.insert(flag)
        }
        let lower = last.lowercased()
        let named = Self.aliases[lower] ?? lower
        if Self.namedKeys[named] != nil {
            self.init(key: named, modifiers: flags)
        } else if last.count == 1 {
            // shift+v means "V"; shift+1 can't be known without the layout.
            var key = last
            if flags.contains(.shift) {
                guard last.lowercased() != last.uppercased() else { return nil }
                key = last.uppercased()
                flags.remove(.shift)
            }
            self.init(key: key, modifiers: flags)
        } else {
            return nil
        }
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        if let name = Self.namedKeys.first(where: { $0.value == event.keyCode })?.key {
            self.init(key: name, modifiers: flags)
        } else if event.keyCode == 76 {  // keypad enter
            self.init(key: "return", modifiers: flags)
        } else {
            self.init(key: event.charactersIgnoringModifiers ?? "", modifiers: flags.subtracting(.shift))
        }
    }

    /// "⌃A", "⇧⇥".
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let symbols = [
            "escape": "⎋", "tab": "⇥", "return": "⏎", "space": "␣", "backspace": "⌫",
            "left": "←", "right": "→", "down": "↓", "up": "↑"
        ]
        if let symbol = symbols[key] { return ActionRegistry.display(key: "", modifiers: flags) + symbol }
        return ActionRegistry.display(key: key, modifiers: flags)
    }
}

/// What a key in a table does.
enum KeyBinding: Equatable {
    /// An `ActionRegistry` id, the menu path ("Terminal/Split Right").
    case action(String)
    /// Text typed into the focused terminal.
    case send(String)
    /// Switches to another table and waits for the next key.
    case table(String)
}

/// `~/.boo/keytables.json`: a leader key and named tables of bindings,
/// starting at "root".
struct KeyTableConfig: Equatable {
    static let rootTable = "root"
    static let defaultLeader = KeyChord(key: "a", modifiers: .control)

    let leader: KeyChord
    /// Seconds without a key before the mode ends.
    let timeout: TimeInterval
    let tables: [String: [KeyChord: KeyBinding]]

    /// Parses `data`, collecting what is wrong with single entries instead of
    /// giving up on the file. Throws only when it is not a JSON object.
    static func parse(_ data: Data) throws -> (config: KeyTableConfig, problems: [String]) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw KeyTableError.notJSON
        }
        var problems: [String] = []
        var leader = defaultLeader
        if let spec = json["leader"] {
            if let string = spec as? String, let chord = KeyChord(spec: string) {
                leader = chord
            } else {
                problems.append("leader: \"\(spec)\" is not a key like \"ctrl+a\"")
            }
        }
        let timeout = (json["timeout"] as? Double).map { min(max($0, 0.5), 30) } ?? 2
        var tables: [String: [KeyChord: KeyBinding]] = [:]
        for (name, value) in (json["tables"] as? [String: Any]) ?? [:] {
            guard let entries = value as? [String: Any] else {
                problems.append("\(name): expected an object of key bindings")
                continue
            }
            var table: [KeyChord: KeyBinding] = [:]
            for (spec, raw) in entries.sorted(by: { $0.key < $1.key }) {
                guard let chord = KeyChord(spec: spec) else {
                    problems.append("\(name) › \(spec): not a key like \"v\", \"V\" or \"ctrl+w\"")
                    continue
                }
                if let string = raw as? String {
                    table[chord] = string.hasPrefix("send:") ? .send(String(string.dropFirst(5))) : .action(string)
                } else if let object = raw as? [String: Any], let next = object["table"] as? String {
                    table[chord] = .table(next)
                } else {
                    problems.append("\(name) › \(spec): expected an action id, \"send:…\" or {\"table\": …}")
                }
            }
            tables[name] = table
        }
        if tables[rootTable] == nil { problems.append("tables: missing the \"root\" table") }
        return (KeyTableConfig(leader: leader, timeout: timeout, tables: tables), problems)
    }

    /// Bindings that point nowhere: unknown action ids or tables.
    func problems(knownActionIDs: Set<String>) -> [String] {
        var result: [String] = []
        for (name, table) in tables.sorted(by: { $0.key < $1.key }) {
            for (chord, binding) in table.sorted(by: { $0.key.key < $1.key.key }) {
                switch binding {
                case .action(let id) where !knownActionIDs.contains(id):
                    result.append("\(name) › \(chord.display): no menu command \"\(id)\"")
                case .table(let next) where tables[next] == nil:
                    result.append("\(name) › \(chord.display): no table \"\(next)\"")
                default:
                    break
                }
            }
        }
        return result
    }
}

enum KeyTableError: Error, Equatable {
    case notJSON
}

/// The modal part: which table, if any, the next key is looked up in.
struct KeyTableMachine {
    enum Outcome: Equatable {
        /// Not ours: the key goes to the terminal as usual.
        case passThrough
        /// Swallowed: the mode started, changed table, or ended without a binding.
        case consumed
        /// The mode ended on this binding.
        case run(KeyBinding)
    }

    let config: KeyTableConfig
    private(set) var table: String?

    init(config: KeyTableConfig) {
        self.config = config
    }

    var isActive: Bool { table != nil }

    mutating func handle(_ chord: KeyChord) -> Outcome {
        guard let current = table else {
            guard chord == config.leader else { return .passThrough }
            table = KeyTableConfig.rootTable
            return .consumed
        }
        table = nil
        if chord.key == "escape", chord.modifiers == 0 { return .consumed }
        switch config.tables[current]?[chord] {
        case .table(let next):
            table = next
            return .consumed
        case .some(let binding):
            return .run(binding)
        case nil:
            // Leader twice types the leader itself, as in tmux.
            return current == KeyTableConfig.rootTable && chord == config.leader ? .passThrough : .consumed
        }
    }

    mutating func reset() {
        table = nil
    }
}
