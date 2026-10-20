import Foundation

/// A parsed asciicast v2 file with an idle-capped timeline. Pure: the player
/// view only asks it which events fall due.
struct CastPlayback {
    enum Event: Equatable {
        case output(String)
        case resize(columns: Int, rows: Int)
    }

    struct TimedEvent: Equatable {
        /// Seconds on the playback timeline (after idle capping).
        let time: TimeInterval
        let event: Event
    }

    /// A chapter marker (asciicast `m` event) on the playback timeline.
    struct Marker: Equatable {
        let time: TimeInterval
        let label: String
    }

    let width: Int
    let height: Int
    let title: String?
    let events: [TimedEvent]
    let markers: [Marker]
    /// Recording start, from the header's `timestamp`.
    let startDate: Date?

    var duration: TimeInterval { max(events.last?.time ?? 0, markers.last?.time ?? 0) }

    static let defaultIdleLimit: TimeInterval = 2

    enum ParseError: Error, Equatable {
        case badHeader
        case unsupportedVersion(Int)
    }

    /// Parses `text`; pauses shrink to `idleLimit`, else the header's
    /// `idle_time_limit`, else `fallbackIdleLimit` (0 keeps them). Malformed
    /// event lines are skipped.
    init(text: String, idleLimit: TimeInterval? = nil, fallbackIdleLimit: TimeInterval = defaultIdleLimit) throws {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let first = lines.next(),
            let header = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        else { throw ParseError.badHeader }
        let version = header["version"] as? Int ?? 0
        guard version == 2 else { throw ParseError.unsupportedVersion(version) }
        width = max(1, header["width"] as? Int ?? 80)
        height = max(1, header["height"] as? Int ?? 24)
        title = header["title"] as? String
        startDate = (header["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let limit =
            idleLimit ?? (header["idle_time_limit"] as? NSNumber)?.doubleValue ?? fallbackIdleLimit

        var out: [TimedEvent] = []
        var marks: [Marker] = []
        var lastRaw: TimeInterval = 0
        var clock: TimeInterval = 0
        while let line = lines.next() {
            guard let arr = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any], arr.count >= 3,
                let raw = (arr[0] as? NSNumber)?.doubleValue, let code = arr[1] as? String,
                let data = arr[2] as? String
            else { continue }
            let event: Event?
            switch code {
            case "o":
                event = .output(data)
            case "r":
                let parts = data.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { continue }
                event = .resize(columns: parts[0], rows: parts[1])
            case "m":
                event = nil
            default:
                continue  // input doesn't replay
            }
            clock += min(max(0, raw - lastRaw), limit > 0 ? limit : .infinity)
            lastRaw = max(lastRaw, raw)
            if let event {
                out.append(TimedEvent(time: clock, event: event))
            } else {
                marks.append(Marker(time: clock, label: data))
            }
        }
        events = out
        markers = marks
    }

    /// The marker before `time` (with a little slack, so a second press while
    /// playing skips past the one just passed), or nil.
    func marker(before time: TimeInterval) -> Marker? {
        markers.last { $0.time < time - 1 }
    }

    func marker(after time: TimeInterval) -> Marker? {
        markers.first { $0.time > time + 0.05 }
    }

    /// Index of the first event after `time`; events before it are due.
    func dueIndex(at time: TimeInterval, from start: Int = 0) -> Int {
        var i = max(0, start)
        while i < events.count, events[i].time <= time { i += 1 }
        return i
    }

    /// Grid size in effect at `index` (header size until the first resize).
    func grid(before index: Int) -> (columns: Int, rows: Int) {
        var size = (columns: width, rows: height)
        for e in events.prefix(index) {
            if case .resize(let c, let r) = e.event { size = (c, r) }
        }
        return size
    }

    /// "m:ss", or "h:mm:ss" past an hour.
    static func formatTime(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
