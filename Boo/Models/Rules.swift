import Foundation

/// One entry of `~/.boo/rules.json`: when a tab's context (and optionally its
/// output) matches, switch its profile or fire trigger actions.
struct Rule: Equatable, Sendable {
    var id: String
    var when: RuleCondition
    var then: RuleConsequence
    /// Minimum seconds between two firings of an output rule in one tab.
    var cooldown: TimeInterval?
    /// Output rules also match on the alternate screen (TUIs). Off by default:
    /// cursor-addressed redraws make line matching unreliable there.
    var altScreen: Bool
    var enabled: Bool

    var isOutputRule: Bool { when.output != nil }

    /// Stable across reloads as long as the rule's text is unchanged; used to
    /// remember a confirmed `sendText` rule.
    var fingerprint: String
}

/// All set fields must match (AND). Globs: `*` and `?`; in `cwd`, `*` stops at
/// `/` and `**` crosses it, and a leading `~` is the home directory.
struct RuleCondition: Equatable, Sendable {
    var host: String?
    var cwd: String?
    var container: String?
    var kubeContext: String?
    var process: String?
    /// Regular expression matched against each line of output.
    var output: String?

    var isEmpty: Bool {
        host == nil && cwd == nil && container == nil && kubeContext == nil && process == nil && output == nil
    }
}

enum RuleConsequence: Equatable, Sendable {
    case profile(String)
    case actions([TriggerAction])
}

enum TriggerAction: Equatable, Sendable {
    case notify(title: String?, body: String?)
    case markTab
    case run(String)
    case sendText(String)
    case openLink(String)
}

/// The context a tab is in, as the rules see it.
struct RuleContext: Equatable, Sendable {
    var host: String?
    /// The ssh config alias the host was reached through, if any.
    var hostAlias: String?
    var cwd: String
    var container: String?
    var kubeContext: String?
    var process: String

    init(
        host: String?, hostAlias: String? = nil, cwd: String, container: String?, kubeContext: String?,
        process: String
    ) {
        self.host = host
        self.hostAlias = hostAlias
        self.cwd = cwd
        self.container = container
        self.kubeContext = kubeContext
        self.process = process
    }

    static let empty = RuleContext(host: nil, cwd: "", container: nil, kubeContext: nil, process: "")
}

// MARK: - Parsing

struct RuleSet: Equatable, Sendable {
    var rules: [Rule]

    static let empty = RuleSet(rules: [])

    var contextRules: [Rule] { rules.filter { $0.enabled && !$0.isOutputRule } }
    var outputRules: [Rule] { rules.filter { $0.enabled && $0.isOutputRule } }
    var usesKubeContext: Bool { rules.contains { $0.enabled && $0.when.kubeContext != nil } }

    struct ParseError: Error, Equatable {
        var message: String
    }

    /// Parses `{"rules": [...]}` (or a bare array). Bad rules are skipped and
    /// reported; a file that isn't JSON throws.
    static func parse(_ data: Data) throws -> (set: RuleSet, problems: [String]) {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError(message: "the file is not valid JSON")
        }
        let list: [Any]
        if let dict = json as? [String: Any] {
            guard let rules = dict["rules"] as? [Any] else {
                throw ParseError(message: "expected a \"rules\" array")
            }
            list = rules
        } else if let array = json as? [Any] {
            list = array
        } else {
            throw ParseError(message: "expected a JSON object with a \"rules\" array")
        }

        var rules: [Rule] = []
        var problems: [String] = []
        var seen = Set<String>()
        for (index, item) in list.enumerated() {
            do {
                var rule = try parseRule(item, index: index)
                if seen.contains(rule.id) {
                    problems.append("rule \"\(rule.id)\": duplicate id, renamed to \"\(rule.id)#\(index)\"")
                    rule.id += "#\(index)"
                }
                seen.insert(rule.id)
                rules.append(rule)
            } catch let error as ParseError {
                problems.append(error.message)
            }
        }
        return (RuleSet(rules: rules), problems)
    }

    private static func parseRule(_ item: Any, index: Int) throws -> Rule {
        guard let dict = item as? [String: Any] else {
            throw ParseError(message: "rule #\(index + 1): not an object")
        }
        let id = (dict["id"] as? String) ?? "rule-\(index + 1)"
        func fail(_ message: String) -> ParseError { ParseError(message: "rule \"\(id)\": \(message)") }

        guard let whenDict = dict["when"] as? [String: Any] else { throw fail("missing \"when\" object") }
        func string(_ key: String) throws -> String? {
            guard let value = whenDict[key] else { return nil }
            guard let s = value as? String, !s.isEmpty else { throw fail("\"when.\(key)\" must be a non-empty string") }
            return s
        }
        let when = RuleCondition(
            host: try string("host"), cwd: try string("cwd"), container: try string("container"),
            kubeContext: try string("kubeContext"), process: try string("process"), output: try string("output"))
        guard !when.isEmpty else { throw fail("\"when\" has no conditions") }
        if let output = when.output {
            do { _ = try NSRegularExpression(pattern: output) } catch {
                throw fail("\"when.output\" is not a valid regular expression")
            }
        }

        let then: RuleConsequence
        if let thenDict = dict["then"] as? [String: Any], let profile = thenDict["profile"] as? String {
            guard when.output == nil else { throw fail("output rules can't switch profiles") }
            then = .profile(profile)
        } else if let list = dict["then"] as? [Any] {
            then = .actions(try list.map { try parseAction($0, fail: fail) })
        } else if let single = dict["then"] as? [String: Any] {
            then = .actions([try parseAction(single, fail: fail)])
        } else {
            throw fail("missing \"then\" (a {\"profile\": …} object or a list of actions)")
        }
        if case .actions(let actions) = then, actions.isEmpty { throw fail("\"then\" has no actions") }

        let cooldown = (dict["cooldown"] as? NSNumber)?.doubleValue
        if let cooldown, cooldown < 0 { throw fail("\"cooldown\" must not be negative") }

        let fingerprintSource =
            (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? id
        return Rule(
            id: id, when: when, then: then, cooldown: cooldown,
            altScreen: dict["altScreen"] as? Bool ?? false,
            enabled: dict["enabled"] as? Bool ?? true,
            fingerprint: Self.hash(fingerprintSource))
    }

    private static func parseAction(_ item: Any, fail: (String) -> ParseError) throws -> TriggerAction {
        guard let dict = item as? [String: Any], dict.count == 1, let (key, value) = dict.first else {
            throw fail("each action must be an object with exactly one key")
        }
        switch key {
        case "notify":
            if let s = value as? String { return .notify(title: nil, body: s) }
            let d = value as? [String: Any] ?? [:]
            return .notify(title: d["title"] as? String, body: d["body"] as? String)
        case "markTab":
            return .markTab
        case "run":
            guard let s = value as? String, !s.isEmpty else { throw fail("\"run\" needs a command string") }
            return .run(s)
        case "sendText":
            guard let s = value as? String, !s.isEmpty else { throw fail("\"sendText\" needs a string") }
            return .sendText(s)
        case "openLink":
            guard let s = value as? String, !s.isEmpty else { throw fail("\"openLink\" needs a string") }
            return .openLink(s)
        default:
            throw fail("unknown action \"\(key)\"")
        }
    }

    /// FNV-1a, hex. Only needs to be stable, not secure.
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

// MARK: - Matching

enum RuleMatcher {
    /// Whether the context fields of `condition` match `context`. The output
    /// regex is not checked here.
    static func contextMatches(_ condition: RuleCondition, _ context: RuleContext) -> Bool {
        if let host = condition.host {
            // Either the real host or the ssh alias it was reached through.
            let candidates = [context.host, context.hostAlias].compactMap { $0 }
            guard candidates.contains(where: { Glob.matches(host, $0) }) else { return false }
        }
        if let container = condition.container {
            guard let value = context.container, Glob.matches(container, value) else { return false }
        }
        if let kube = condition.kubeContext {
            guard let value = context.kubeContext, Glob.matches(kube, value) else { return false }
        }
        if let process = condition.process {
            guard !context.process.isEmpty, Glob.matches(process, context.process) else { return false }
        }
        if let cwd = condition.cwd {
            guard !context.cwd.isEmpty, Glob.matches(cwd, context.cwd, path: true) else { return false }
        }
        return true
    }

    /// The profile name of the first enabled context rule that matches.
    static func profile(for context: RuleContext, in set: RuleSet) -> String? {
        for rule in set.contextRules {
            guard case .profile(let name) = rule.then else { continue }
            if contextMatches(rule.when, context) { return name }
        }
        return nil
    }

    /// Context rules with actions that match `context`.
    static func matchingActionRules(for context: RuleContext, in set: RuleSet) -> [Rule] {
        set.contextRules.filter { rule in
            if case .actions = rule.then { return contextMatches(rule.when, context) }
            return false
        }
    }
}

/// Shell-style glob matching.
enum Glob {
    static func matches(_ pattern: String, _ value: String, path: Bool = false) -> Bool {
        regex(for: pattern, path: path)?.firstMatch(
            in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    static func regex(for pattern: String, path: Bool) -> NSRegularExpression? {
        let key = (path ? "p:" : "s:") + pattern
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }
        var p = pattern
        if path, p.hasPrefix("~") { p = NSHomeDirectory() + p.dropFirst() }
        var out = "^"
        var chars = Array(p)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if path, i + 1 < chars.count, chars[i + 1] == "*" {
                    out += ".*"
                    i += 1
                } else {
                    out += path ? "[^/]*" : ".*"
                }
            case "?":
                out += path ? "[^/]" : "."
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        // A directory pattern also matches everything below it.
        if path {
            if out.hasSuffix("/") { out.removeLast() }
            out += "(/.*)?"
        }
        out += "$"
        chars.removeAll()
        let regex = try? NSRegularExpression(pattern: out, options: path ? [] : [.caseInsensitive])
        if let regex { cache[key] = regex }
        return regex
    }
}
