import Foundation

/// Turns a raw pty byte stream into plain-text lines: drops escape sequences,
/// applies carriage-return overwrite and backspace, and tracks whether the
/// alternate screen is active. Not thread-safe; owned by one queue.
struct OutputLineSplitter {
    static let maxLineBytes = 4096

    enum Event: Equatable {
        /// A finished line (LF, or a cursor jump that leaves the line).
        case line(String, altScreen: Bool)
    }

    private(set) var altScreen = false
    /// Bytes of the line being written.
    private(set) var current: [UInt8] = []
    /// Bumped whenever `current` is cleared or emitted, so a consumer can tell
    /// a new line from a grown one.
    private(set) var lineGeneration = 0

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
        case oscEscape
        /// DCS, SOS, PM, APC: skipped up to ST.
        case string
        case stringEscape
    }

    private var state = State.ground
    private var csiParams: [UInt8] = []
    private var pendingCR = false

    /// The unfinished line, for prompts that wait without a newline.
    var partialLine: String? {
        current.isEmpty ? nil : String(decoding: current, as: UTF8.self)
    }

    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, into events: inout [Event]) {
        for b in bytes { step(b, &events) }
    }

    mutating func feed(_ bytes: [UInt8], into events: inout [Event]) {
        bytes.withUnsafeBufferPointer { feed($0, into: &events) }
    }

    /// Forgets the unfinished line (bytes were dropped mid-line).
    mutating func discardLine() {
        clearLine()
        state = .ground
    }

    private mutating func step(_ b: UInt8, _ events: inout [Event]) {
        switch state {
        case .ground:
            ground(b, &events)
        case .escape:
            switch b {
            case 0x5B:  // [
                state = .csi
                csiParams.removeAll(keepingCapacity: true)
            case 0x5D:  // ]
                state = .osc
            case 0x50, 0x58, 0x5E, 0x5F:  // P X ^ _
                state = .string
            case 0x20...0x2F:
                state = .escapeIntermediate
            case 0x1B:
                state = .escape
            default:
                state = .ground
            }
        case .escapeIntermediate:
            if !(0x20...0x2F).contains(b) { state = .ground }
        case .csi:
            switch b {
            case 0x20...0x3F:
                if csiParams.count < 64 { csiParams.append(b) }
            case 0x40...0x7E:
                state = .ground
                finishCSI(final: b, &events)
            case 0x1B:
                state = .escape
            default:
                // C0 controls inside CSI execute normally.
                ground(b, &events)
            }
        case .osc:
            if b == 0x07 {
                state = .ground
            } else if b == 0x1B {
                state = .oscEscape
            }
        case .oscEscape:
            state = b == 0x5C ? .ground : .osc
        case .string:
            if b == 0x1B { state = .stringEscape }
        case .stringEscape:
            state = b == 0x5C ? .ground : .string
        }
    }

    private mutating func ground(_ b: UInt8, _ events: inout [Event]) {
        switch b {
        case 0x1B:
            state = .escape
        case 0x0A, 0x0B, 0x0C:
            pendingCR = false
            emitLine(&events)
        case 0x0D:
            pendingCR = true
        case 0x08:
            removeLastScalar()
        case 0x09:
            append(0x20)
        case 0x00...0x1F, 0x7F:
            break
        default:
            append(b)
        }
    }

    private mutating func append(_ b: UInt8) {
        // A CR not followed by LF means the line is being redrawn (progress
        // bars, spinners): the new text replaces the old.
        if pendingCR {
            pendingCR = false
            clearLine()
        }
        if current.count < Self.maxLineBytes { current.append(b) }
    }

    private mutating func removeLastScalar() {
        guard !current.isEmpty else { return }
        // Drop UTF-8 continuation bytes along with their lead byte.
        while let last = current.popLast(), last & 0xC0 == 0x80, !current.isEmpty {}
    }

    private mutating func finishCSI(final: UInt8, _ events: inout [Event]) {
        switch final {
        case 0x68, 0x6C:  // h, l
            guard csiParams.first == 0x3F else { return }  // ?
            let modes = String(decoding: csiParams.dropFirst(), as: UTF8.self).split(separator: ";")
            if modes.contains(where: { $0 == "1049" || $0 == "1047" || $0 == "47" }) {
                emitLine(&events)
                altScreen = final == 0x68
            }
        case 0x48, 0x66, 0x64, 0x41, 0x42, 0x45, 0x46:  // H f d A B E F: cursor leaves the row
            emitLine(&events)
        case 0x43:  // C: cursor forward reads as a gap
            append(0x20)
        case 0x4A:  // J: erase display
            if csiParams.first == 0x32 || csiParams.first == 0x33 { clearLine() }
        default:
            break
        }
    }

    private mutating func emitLine(_ events: inout [Event]) {
        guard !current.isEmpty else {
            lineGeneration &+= 1
            return
        }
        events.append(.line(String(decoding: current, as: UTF8.self), altScreen: altScreen))
        clearLine()
    }

    private mutating func clearLine() {
        current.removeAll(keepingCapacity: true)
        lineGeneration &+= 1
    }
}
