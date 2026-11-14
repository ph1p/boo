import Foundation

/// `rules.json` as loose JSON, for the form editor in Settings → Rules.
///
/// The form works on the JSON objects instead of the parsed `Rule` values, so
/// keys it doesn't know and entries it can't read survive an edit. A rule the
/// form didn't touch is written back with the same keys and values, which
/// keeps its `Rule.fingerprint` and with it an approved `sendText`.
struct RulesDocument {
    /// The root object of a `{"rules": [...]}` file; nil for a bare array.
    private var root: [String: Any]?
    /// Every entry of the rules array, as written.
    private(set) var items: [Any]

    /// Nil when the text is not JSON or not a rules file. Empty text is an
    /// empty document.
    init?(text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = [:]
            items = []
            return
        }
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        if let dict = json as? [String: Any] {
            if let rules = dict["rules"] {
                guard let list = rules as? [Any] else { return nil }
                items = list
            } else {
                items = []
            }
            root = dict
        } else if let list = json as? [Any] {
            root = nil
            items = list
        } else {
            return nil
        }
    }

    /// The rule at `index`; nil when the entry is not an object.
    func rule(at index: Int) -> [String: Any]? {
        items.indices.contains(index) ? items[index] as? [String: Any] : nil
    }

    /// The ids of all rules except the one at `index`.
    func ids(except index: Int?) -> Set<String> {
        var ids = Set<String>()
        for (i, item) in items.enumerated() where i != index {
            if let id = (item as? [String: Any])?["id"] as? String { ids.insert(id) }
        }
        return ids
    }

    mutating func replace(at index: Int, with rule: [String: Any]) {
        guard items.indices.contains(index) else { return }
        items[index] = rule
    }

    mutating func append(_ rule: [String: Any]) {
        items.append(rule)
    }

    mutating func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }

    /// Moves the entry at `index` one place up (`-1`) or down (`1`).
    mutating func move(at index: Int, by offset: Int) {
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    mutating func setEnabled(_ enabled: Bool, at index: Int) {
        guard var rule = rule(at: index) else { return }
        rule["enabled"] = enabled
        items[index] = rule
    }

    /// The file text: the same root shape as the source, two-space indent.
    func text() -> String {
        let value: Any
        if var root {
            root["rules"] = items
            value = root
        } else {
            value = items
        }
        return Self.render(value, indent: "") + "\n"
    }

    // MARK: - Writer

    /// Keys written first, in this order, wherever they occur. `JSONSerialization`
    /// can only sort keys, which would put `altScreen` before `id`.
    private static let keyOrder: [String] =
        ["rules", "id", "enabled", "when", "then", "cooldown", "altScreen"] + RuleCondition.orderedKeys
        + ["profile", "title", "body"]
    private static let keyRank: [String: Int] = Dictionary(
        uniqueKeysWithValues: keyOrder.enumerated().map { ($0.element, $0.offset) })

    private static func render(_ value: Any, indent: String) -> String {
        let inner = indent + "  "
        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            let keys = dict.keys.sorted { a, b in
                switch (keyRank[a], keyRank[b]) {
                case (let x?, let y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a < b
                }
            }
            let lines = keys.map { key in
                "\(inner)\(scalar(key)): \(render(dict[key] ?? NSNull(), indent: inner))"
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
        }
        if let list = value as? [Any] {
            if list.isEmpty { return "[]" }
            let lines = list.map { inner + render($0, indent: inner) }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(indent)]"
        }
        return scalar(value)
    }

    private static func scalar(_ value: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

/// One rule as the form shows it. Built from a rule's JSON object and applied
/// back onto it, so everything the form has no field for stays as written.
struct RuleDraft: Equatable {
    enum Kind: String, CaseIterable {
        case profile, actions

        var title: String { self == .profile ? "Use a profile" : "Run actions" }
    }

    struct Action: Identifiable {
        enum Kind: String, CaseIterable {
            case notify, markTab, run, sendText, openLink
        }

        let id = UUID()
        /// Nil for an action the form has no fields for; `raw` is written back.
        var kind: Kind?
        /// The notification body, command, text to type, or link text.
        var text = ""
        /// `notify` only.
        var title = ""
        var raw: Any?

        init(kind: Kind) {
            self.kind = kind
        }

        init(json: Any) {
            raw = json
            guard let dict = json as? [String: Any], dict.count == 1, let (key, value) = dict.first,
                let kind = Kind(rawValue: key)
            else { return }
            switch kind {
            case .notify:
                if let body = value as? String {
                    text = body
                } else if let fields = value as? [String: Any],
                    fields.keys.allSatisfy({ $0 == "title" || $0 == "body" })
                {
                    title = fields["title"] as? String ?? ""
                    text = fields["body"] as? String ?? ""
                } else {
                    return
                }
            case .markTab:
                break
            case .run, .sendText, .openLink:
                guard let string = value as? String else { return }
                text = string
            }
            self.kind = kind
        }

        var json: Any {
            guard let kind else { return raw ?? [String: Any]() }
            switch kind {
            case .notify:
                if title.isEmpty { return text.isEmpty ? ["notify": [String: Any]()] : ["notify": text] }
                var fields = ["title": title]
                if !text.isEmpty { fields["body"] = text }
                return ["notify": fields]
            case .markTab:
                return ["markTab": [String: Any]()]
            case .run, .sendText, .openLink:
                return [kind.rawValue: text]
            }
        }
    }

    var id = ""
    var enabled = true
    /// The `when` values by key; an empty string means "not set".
    var conditions: [String: String] = [:]
    var kind: Kind = .profile
    var profile = ""
    var actions: [Action] = []
    /// Seconds, as typed; empty uses the default.
    var cooldown = ""
    var altScreen = false

    init() {}

    init(_ rule: [String: Any]) {
        id = rule["id"] as? String ?? ""
        enabled = rule["enabled"] as? Bool ?? true
        let when = rule["when"] as? [String: Any] ?? [:]
        for key in RuleCondition.orderedKeys {
            if let value = when[key] as? String { conditions[key] = value }
        }
        if let then = rule["then"] as? [String: Any], let name = then["profile"] as? String {
            kind = .profile
            profile = name
        } else if let list = rule["then"] as? [Any] {
            kind = .actions
            actions = list.map(Action.init(json:))
        } else if let single = rule["then"] as? [String: Any] {
            kind = .actions
            actions = [Action(json: single)]
        }
        if let seconds = rule["cooldown"] as? NSNumber { cooldown = seconds.stringValue }
        altScreen = rule["altScreen"] as? Bool ?? false
    }

    var hasOutput: Bool { !(conditions["output"] ?? "").isEmpty }

    /// What stops this draft from being written; nil when it can be.
    var problem: String? {
        let seconds = cooldown.trimmingCharacters(in: .whitespaces)
        if !seconds.isEmpty, Double(seconds) == nil { return "Cooldown must be a number of seconds." }
        if kind == .profile, profile.isEmpty { return "Choose a profile." }
        return nil
    }

    /// `rule` with the form's fields written over it. Keys the form doesn't
    /// know stay, and a default is only written where the key was already there.
    func applied(to rule: [String: Any]) -> [String: Any] {
        var out = rule
        let name = id.trimmingCharacters(in: .whitespaces)
        out["id"] = name.isEmpty ? nil : name
        if !enabled || rule["enabled"] != nil { out["enabled"] = enabled }

        var when = rule["when"] as? [String: Any] ?? [:]
        for key in RuleCondition.orderedKeys {
            let value = (conditions[key] ?? "").trimmingCharacters(in: .whitespaces)
            when[key] = value.isEmpty ? nil : value
        }
        out["when"] = when

        switch kind {
        case .profile:
            var then = rule["then"] as? [String: Any] ?? [:]
            if then["profile"] == nil { then = [:] }
            then["profile"] = profile
            out["then"] = then
        case .actions:
            let list = actions.map(\.json)
            let wasSingle = (rule["then"] as? [String: Any]).map { $0["profile"] == nil } ?? false
            out["then"] = wasSingle && list.count == 1 ? list[0] : list
        }

        let seconds = cooldown.trimmingCharacters(in: .whitespaces)
        if let value = Double(seconds) {
            out["cooldown"] = value == value.rounded() && abs(value) < 1e9 ? Int(value) as Any : value as Any
        } else {
            out["cooldown"] = nil
        }
        if altScreen || rule["altScreen"] != nil { out["altScreen"] = altScreen }
        return out
    }

    /// Why the parser would skip this rule; nil when it loads.
    static func parseProblem(in rule: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [rule]),
            let parsed = try? RuleSet.parse(data)
        else { return "The rule can't be written as JSON." }
        return parsed.set.rules.isEmpty ? parsed.problems.first ?? "The rule is not valid." : nil
    }

    /// One line for the rule list, for example `host *.prod → profile Production`.
    static func summary(of rule: [String: Any]) -> String {
        let draft = RuleDraft(rule)
        let when = RuleCondition.orderedKeys.compactMap { key in
            draft.conditions[key].map { "\(key) \($0)" }
        }
        let then: String
        switch draft.kind {
        case .profile:
            then = draft.profile.isEmpty ? "nothing" : "profile \(draft.profile)"
        case .actions:
            then = draft.actions.map { $0.kind?.rawValue ?? "custom action" }.joined(separator: ", ")
        }
        return (when.isEmpty ? "no condition" : when.joined(separator: ", ")) + " → " + then
    }
}

extension RuleDraft.Action: Equatable {
    /// Ignores `id`, so two drafts of the same rule compare equal.
    static func == (a: RuleDraft.Action, b: RuleDraft.Action) -> Bool {
        guard a.kind == b.kind else { return false }
        if a.kind == nil { return (a.json as? NSObject)?.isEqual(b.json) ?? false }
        return a.text == b.text && a.title == b.title
    }
}
