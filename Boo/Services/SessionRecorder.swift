import Foundation

/// Encodes an asciicast v2 recording: one JSON header line, then one
/// `[time, code, data]` line per event. Pure, so tests can check the format.
struct AsciicastWriter {
    let width: Int
    let height: Int
    let startDate: Date
    let title: String?
    let env: [String: String]

    func header() -> String {
        var obj: [String: Any] = [
            "version": 2,
            "width": width,
            "height": height,
            "timestamp": Int(startDate.timeIntervalSince1970)
        ]
        if let title, !title.isEmpty { obj["title"] = title }
        if !env.isEmpty { obj["env"] = env }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func outputEvent(time: TimeInterval, text: String) -> String {
        event(time: time, code: "o", data: text)
    }

    static func resizeEvent(time: TimeInterval, columns: Int, rows: Int) -> String {
        event(time: time, code: "r", data: "\(columns)x\(rows)")
    }

    private static func event(time: TimeInterval, code: String, data: String) -> String {
        "[\(String(format: "%.6f", max(0, time))), \"\(code)\", \(jsonString(data))]\n"
    }

    /// JSON string literal; control characters become `\uXXXX`.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// Splits a byte stream into UTF-8 text, holding back a multibyte sequence cut
/// at a chunk boundary until the next chunk. Invalid bytes become U+FFFD.
struct UTF8Carry {
    private var pending: [UInt8] = []

    mutating func decode(_ bytes: [UInt8]) -> String {
        var buf = pending + bytes
        pending = []
        // A lead byte in the last three positions whose sequence is incomplete.
        let tail = Self.incompleteTailLength(buf)
        if tail > 0 {
            pending = Array(buf.suffix(tail))
            buf.removeLast(tail)
        }
        return String(decoding: buf, as: UTF8.self)
    }

    /// Flushes held-back bytes (as U+FFFD) at the end of a recording.
    mutating func flush() -> String {
        defer { pending = [] }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    static func incompleteTailLength(_ buf: [UInt8]) -> Int {
        let n = buf.count
        for back in 1...3 {
            guard back <= n else { break }
            let b = buf[n - back]
            if b & 0xC0 == 0x80 { continue }  // continuation byte; keep looking for the lead
            let need: Int
            if b & 0xE0 == 0xC0 {
                need = 2
            } else if b & 0xF0 == 0xE0 {
                need = 3
            } else if b & 0xF8 == 0xF0 {
                need = 4
            } else {
                return 0
            }
            return back < need ? back : 0
        }
        return 0
    }
}

/// Writes one terminal's pty output to an asciicast file. Output arrives on
/// Ghostty's read thread; everything after `append` runs on a serial queue.
final class SessionRecorder: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "boo.session-recorder")
    private let handle: FileHandle
    private let startNanos: UInt64
    private var carry = UTF8Carry()
    private var closed = false

    init(url: URL, columns: Int, rows: Int, title: String?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        self.url = url
        startNanos = DispatchTime.now().uptimeNanoseconds
        let env = ProcessInfo.processInfo.environment
        let header = AsciicastWriter(
            width: columns, height: rows, startDate: Date(), title: title,
            env: ["TERM": "xterm-256color", "SHELL": env["SHELL"] ?? "/bin/zsh"]
        ).header()
        handle.write(Data(header.utf8))
    }

    private func elapsed(_ nanos: UInt64) -> TimeInterval {
        TimeInterval(nanos &- startNanos) / 1_000_000_000
    }

    /// Called from Ghostty's read thread with the terminal locked: copy and return.
    func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
        let copy = Array(UnsafeBufferPointer(start: bytes, count: count))
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            guard !closed else { return }
            let text = carry.decode(copy)
            guard !text.isEmpty else { return }
            write(AsciicastWriter.outputEvent(time: elapsed(now), text: text))
        }
    }

    func resized(columns: Int, rows: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            guard !closed else { return }
            write(AsciicastWriter.resizeEvent(time: elapsed(now), columns: columns, rows: rows))
        }
    }

    /// Flushes and closes the file. Call after the output tap is removed.
    func finish(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            let rest = carry.flush()
            if !rest.isEmpty {
                write(AsciicastWriter.outputEvent(time: elapsed(DispatchTime.now().uptimeNanoseconds), text: rest))
            }
            closed = true
            try? handle.close()
            completion?()
        }
    }

    private func write(_ line: String) {
        handle.write(Data(line.utf8))
    }

    /// `~/.boo/recordings/<date>-<title>.cast`
    static func defaultURL(title: String, date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(
            title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let name = fmt.string(from: date) + (cleaned.isEmpty ? "" : "-" + String(cleaned.prefix(40)))
        return recordingsDirectory.appendingPathComponent(name + ".cast")
    }

    static var recordingsDirectory: URL {
        URL(fileURLWithPath: BooPaths.recordingsDir, isDirectory: true)
    }
}
