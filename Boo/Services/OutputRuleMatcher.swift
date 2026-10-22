import Foundation

/// An output rule matched a line in a tab.
struct OutputMatch: Sendable, Equatable {
    var ruleID: String
    /// `$0` (the whole match) through `$9`; missing groups are empty.
    var captures: [String]
    var line: String
}

/// Watches one surface's output for the enabled output rules. The io thread
/// only copies bytes into a bounded buffer; splitting and regex matching run
/// on a utility queue, and matches are delivered on the main queue.
final class OutputRuleMatcher: OutputTapSubscriber, @unchecked Sendable {
    static let queueLimit = 256 * 1024
    /// An unfinished line (a `[y/N]` prompt) is matched once output has been
    /// quiet this long, so rules don't fire on half-written lines.
    static let partialLineDelay: TimeInterval = 0.15

    struct CompiledRule {
        let rule: Rule
        let regex: NSRegularExpression
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var pending: [UInt8] = []
    private var dropping = false
    private var discardPartial = false
    private var scheduled = false
    private var droppedBytesTotal = 0
    private var rulesInbox: [CompiledRule]?
    private var contextValue = RuleContext.empty

    // Owned by `queue`.
    private let queue = DispatchQueue(label: "boo.output-rules", qos: .utility)
    private var splitter = OutputLineSplitter()
    private var rules: [CompiledRule] = []
    /// Rules that already fired on the line being written (via the partial
    /// check), so finishing the line doesn't fire them again.
    private var firedOnLine = Set<String>()
    private var firedGeneration = 0

    private let onMatch: @MainActor @Sendable (OutputMatch) -> Void

    init(rules: [Rule], context: RuleContext, onMatch: @escaping @MainActor @Sendable (OutputMatch) -> Void) {
        self.onMatch = onMatch
        self.contextValue = context
        self.rules = Self.compile(rules)
    }

    var droppedBytes: Int { lock.withLock { droppedBytesTotal } }

    static func compile(_ rules: [Rule]) -> [CompiledRule] {
        rules.compactMap { rule in
            guard let pattern = rule.when.output, let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return CompiledRule(rule: rule, regex: regex)
        }
    }

    func update(rules: [Rule]) {
        let compiled = Self.compile(rules)
        lock.withLock { rulesInbox = compiled }
    }

    func update(context: RuleContext) {
        lock.withLock { contextValue = context }
    }

    // MARK: OutputTapSubscriber (io thread)

    func tapOutput(_ bytes: UnsafeBufferPointer<UInt8>) {
        let schedule: Bool = lock.withLock {
            var start = 0
            if dropping || pending.count + bytes.count > Self.queueLimit {
                // Over budget: drop through the next newline so matching
                // resumes on a whole line.
                guard let nl = bytes.firstIndex(of: 0x0A) else {
                    droppedBytesTotal += bytes.count
                    dropping = true
                    discardPartial = true
                    return false
                }
                droppedBytesTotal += nl + 1
                start = nl + 1
                dropping = false
                discardPartial = true
                if pending.count + (bytes.count - start) > Self.queueLimit {
                    droppedBytesTotal += bytes.count - start
                    dropping = true
                    return false
                }
            }
            if start < bytes.count {
                pending.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start...]))
            }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    func tapResized(columns: Int, rows: Int) {}

    // MARK: Matching (queue)

    private func drain() {
        while true {
            let (chunk, discard, newRules, context): ([UInt8], Bool, [CompiledRule]?, RuleContext) = lock.withLock {
                let chunk = pending
                pending = []
                let discard = discardPartial
                discardPartial = false
                let newRules = rulesInbox
                rulesInbox = nil
                if chunk.isEmpty { scheduled = false }
                return (chunk, discard, newRules, contextValue)
            }
            if let newRules {
                rules = newRules
                firedOnLine.removeAll()
            }
            if discard { splitter.discardLine() }
            guard !chunk.isEmpty else { break }
            process(chunk, context: context)
        }
        schedulePartialCheck()
    }

    private func process(_ chunk: [UInt8], context: RuleContext) {
        var events: [OutputLineSplitter.Event] = []
        let generationBefore = splitter.lineGeneration
        splitter.feed(chunk, into: &events)
        for (index, event) in events.enumerated() {
            guard case .line(let line, let alt) = event else { continue }
            // Only the first finished line can be the one a partial check saw.
            let skip = index == 0 && firedGeneration == generationBefore ? firedOnLine : []
            match(line, altScreen: alt, context: context, skipping: skip)
        }
        if splitter.lineGeneration != firedGeneration {
            firedOnLine.removeAll()
            firedGeneration = splitter.lineGeneration
        }
    }

    private func schedulePartialCheck() {
        guard splitter.partialLine != nil, !rules.isEmpty else { return }
        let generation = splitter.lineGeneration
        let length = splitter.current.count
        queue.asyncAfter(deadline: .now() + Self.partialLineDelay) { [self] in
            guard splitter.lineGeneration == generation, splitter.current.count == length,
                lock.withLock({ pending.isEmpty }),
                let partial = splitter.partialLine
            else { return }
            let context = lock.withLock { contextValue }
            let fired = match(partial, altScreen: splitter.altScreen, context: context, skipping: firedOnLine)
            firedGeneration = generation
            firedOnLine.formUnion(fired)
        }
    }

    @discardableResult
    private func match(_ line: String, altScreen: Bool, context: RuleContext, skipping: Set<String>) -> [String] {
        var fired: [String] = []
        let range = NSRange(line.startIndex..., in: line)
        for compiled in rules {
            let rule = compiled.rule
            if altScreen && !rule.altScreen { continue }
            if skipping.contains(rule.id) { continue }
            guard RuleMatcher.contextMatches(rule.when, context),
                let result = compiled.regex.firstMatch(in: line, range: range)
            else { continue }
            let captures = (0...9).map { i -> String in
                guard i < result.numberOfRanges, let r = Range(result.range(at: i), in: line) else { return "" }
                return String(line[r])
            }
            fired.append(rule.id)
            let match = OutputMatch(ruleID: rule.id, captures: captures, line: line)
            let onMatch = onMatch
            DispatchQueue.main.async { MainActor.assumeIsolated { onMatch(match) } }
        }
        return fired
    }

    /// Test hook: waits until queued output has been matched.
    func waitUntilIdle() {
        queue.sync {}
    }
}

/// `$0`…`$9` substitution for action templates.
enum CaptureTemplate {
    static func expand(_ template: String, captures: [String]) -> String {
        var out = ""
        var chars = template.makeIterator()
        var pendingDollar = false
        while let c = chars.next() {
            if pendingDollar {
                pendingDollar = false
                if let digit = c.wholeNumberValue, c.isASCII {
                    out += digit < captures.count ? captures[digit] : ""
                    continue
                }
                if c == "$" {
                    out.append("$")
                    continue
                }
                out.append("$")
            }
            if c == "$" {
                pendingDollar = true
            } else {
                out.append(c)
            }
        }
        if pendingDollar { out.append("$") }
        return out
    }
}
