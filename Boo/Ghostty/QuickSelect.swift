import Cocoa

/// Quick select: labels every URL, path, hash, IP and UUID on screen so one
/// can be copied (or typed into the prompt) with a couple of keystrokes,
/// without reaching for the mouse.
enum QuickSelect {
    struct Match: Equatable {
        var row: Int
        /// First cell column and width in cells.
        var column: Int
        var width: Int
        var text: String
        var label = ""
    }

    /// Ordered by precedence: an earlier pattern wins an overlap, so a URL
    /// is never also offered as a path or hash.
    nonisolated(unsafe) static let patterns: [NSRegularExpression] = [
        #"\b(?:https?|ftp|file|ssh)://[^\s<>"'`]+[^\s<>"'`.,;:!?)\]}]"#,
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
        #"(?:~|\.{1,2})?(?:/[\w.@+-]+)+/?|\b[\w.@+-]+(?:/[\w.@+-]+)+/?"#,
        #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#,
        #"\b0x[0-9a-fA-F]{4,}\b"#,
        #"\b[0-9a-f]{7,40}\b"#
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Home-row first, so most selections are one easy key.
    static let alphabet = Array("asdfjklghqwertyuiopzxcvbnm")

    /// Matches in the given viewport lines, labelled. Identical text shares
    /// a label; matches nearest the bottom (the latest output) get labels first.
    static func matches(in lines: [String]) -> [Match] {
        var found: [Match] = []
        for (row, line) in lines.enumerated() {
            let ns = line as NSString
            var taken: [NSRange] = []
            for regex in patterns {
                for result in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let range = result.range
                    guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                    let text = ns.substring(with: range)
                    guard isWorthOffering(text) else { continue }
                    taken.append(range)
                    let column = cellWidth(of: ns.substring(to: range.location))
                    found.append(Match(row: row, column: column, width: cellWidth(of: text), text: text))
                }
            }
        }
        found.sort { ($0.row, $0.column) > ($1.row, $1.column) }

        var distinct: [String] = []
        for match in found where !distinct.contains(match.text) { distinct.append(match.text) }
        let labelList = labels(count: distinct.count)
        let byText = Dictionary(uniqueKeysWithValues: zip(distinct, labelList))
        return found.compactMap { match in
            guard let label = byText[match.text] else { return nil }
            var labelled = match
            labelled.label = label
            return labelled
        }
    }

    /// Prefix-free labels: single letters while they last, then pairs.
    static func labels(count: Int) -> [String] {
        let singles = alphabet.map(String.init)
        if count <= singles.count { return Array(singles.prefix(count)) }
        var pairs: [String] = []
        for a in alphabet {
            for b in alphabet { pairs.append(String([a, b])) }
        }
        return Array(pairs.prefix(count))
    }

    /// Filters regex hits that are technically matches but useless: a bare
    /// `/`, a word with a slash in prose, a hash that is all digits.
    private static func isWorthOffering(_ text: String) -> Bool {
        guard text.count >= 3 else { return false }
        if text.allSatisfy(\.isNumber) { return false }
        if text.allSatisfy({ $0 == "/" || $0 == "." || $0 == "~" }) { return false }
        return true
    }

    /// Terminal cell width: wide (East Asian, emoji) characters take two cells.
    static func cellWidth(of text: String) -> Int {
        text.reduce(0) { $0 + (LinkResolver.isWide($1) ? 2 : 1) }
    }
}

/// The label layer over a terminal while quick select is active. Keys reach
/// it through `GhosttyView.keyDown`; a lowercase label copies the match, the
/// uppercase label types it into the prompt, Escape cancels.
final class QuickSelectOverlay: NSView {
    private let matches: [QuickSelect.Match]
    private let cellSize: CGSize
    private var typed = ""
    private let onPick: (String, _ insert: Bool) -> Void
    private let onCancel: () -> Void

    init(
        frame: NSRect, matches: [QuickSelect.Match], cellSize: CGSize,
        onPick: @escaping (String, Bool) -> Void, onCancel: @escaping () -> Void
    ) {
        self.matches = matches
        self.cellSize = cellSize
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quick select, \(matches.count) matches. Type a label to copy, Escape to cancel.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { onCancel() }

    /// Every key goes here while active; keys that are not labels are swallowed.
    func handle(_ event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancel()
            return
        }
        if event.keyCode == 51 {  // Delete
            if typed.isEmpty { onCancel() } else { typed.removeLast() }
            needsDisplay = true
            return
        }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
            let char = chars.first, char.isLetter
        else { return }
        let insert = event.modifierFlags.contains(.shift)
        typed += chars.lowercased()
        let candidates = matches.filter { $0.label.hasPrefix(typed) }
        if let exact = candidates.first(where: { $0.label == typed }) {
            onPick(exact.text, insert)
        } else if candidates.isEmpty {
            NSSound.beep()
            typed = ""
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppSettings.shared.theme
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        let pad = GhosttyView.gridPadding
        let font = NSFont.monospacedSystemFont(ofSize: max(9, cellSize.height * 0.62), weight: .bold)
        for match in matches {
            let dimmed = !typed.isEmpty && !match.label.hasPrefix(typed)
            let y = pad + CGFloat(match.row) * cellSize.height
            let span = CGRect(
                x: pad + CGFloat(match.column) * cellSize.width, y: y,
                width: CGFloat(match.width) * cellSize.width, height: cellSize.height)
            theme.accentColor.withAlphaComponent(dimmed ? 0.08 : 0.22).setFill()
            NSBezierPath(roundedRect: span, xRadius: 2, yRadius: 2).fill()
            guard !dimmed else { continue }

            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.background.nsColor]
            let label = match.label.uppercased() as NSString
            let size = label.size(withAttributes: attrs)
            let pill = CGRect(
                x: span.minX, y: y, width: size.width + 6, height: cellSize.height
            ).insetBy(dx: 0, dy: 1)
            theme.accentColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            label.draw(at: CGPoint(x: pill.minX + 3, y: y + (cellSize.height - size.height) / 2), withAttributes: attrs)
        }
    }
}
