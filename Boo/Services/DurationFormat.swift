import Foundation

enum DurationFormat {
    /// "42s", "2m 5s", "1h 2m": whole seconds, rounded.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
