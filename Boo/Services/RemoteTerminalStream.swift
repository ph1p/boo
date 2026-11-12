import Foundation

/// One browser's live view of one pane: the pane's pty output, pushed down a
/// held-open HTTP response from `RemoteControlServer`.
///
/// The body is a sequence of frames, `[type u8][length u32 LE][payload]`:
/// - `output` carries raw pty bytes, to feed straight into a VT parser;
/// - `resize` carries the grid size as `cols u16 LE, rows u16 LE`.
///
/// Subscribed with a snapshot, the first frames are the grid size and the
/// current screen as VT, so the browser needs no other starting state.
///
/// Tap callbacks run on Ghostty's io thread with the terminal lock held, so
/// they only append to `pending` and leave the socket write to the server's
/// queue, coalescing whatever arrives in between.
final class RemoteTerminalStream: OutputTapSubscriber, @unchecked Sendable {
    enum FrameType: UInt8 {
        case output = 1
        case resize = 2
    }

    /// Output a slow peer may leave unread before the stream is dropped. The
    /// browser reconnects and starts again from a fresh snapshot.
    static let maxPendingBytes = 4 << 20

    let fd: Int32
    let paneID: UUID
    private weak var server: RemoteControlServer?

    private let lock = NSLock()
    private var pending = Data()
    private var flushScheduled = false
    private var overflowed = false
    private var closed = false

    /// Response headers are out; set and read only on the server's queue.
    var isOpen = false

    /// Unsubscribes from the pane's tap. Set and called on the main thread.
    var onClose: (() -> Void)?

    init(fd: Int32, paneID: UUID, server: RemoteControlServer?) {
        self.fd = fd
        self.paneID = paneID
        self.server = server
    }

    static func frame(_ type: FrameType, _ payload: UnsafeRawBufferPointer) -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }

    static func resizeFrame(columns: Int, rows: Int) -> Data {
        let size = [UInt16(clamping: columns).littleEndian, UInt16(clamping: rows).littleEndian]
        return size.withUnsafeBytes { frame(.resize, $0) }
    }

    // MARK: - OutputTapSubscriber

    func tapOutput(_ bytes: UnsafeBufferPointer<UInt8>) {
        enqueue(Self.frame(.output, UnsafeRawBufferPointer(bytes)))
    }

    func tapResized(columns: Int, rows: Int) {
        enqueue(Self.resizeFrame(columns: columns, rows: rows))
    }

    func tapDetached() {
        server?.endStream(self)
    }

    // MARK: - Buffer

    /// Queue a frame and ask the server to flush, unless a flush is already due.
    func enqueue(_ frame: Data) {
        let schedule: Bool = lock.withLock {
            guard !closed, !overflowed else { return false }
            pending.append(frame)
            if pending.count > Self.maxPendingBytes {
                overflowed = true
                pending = Data()
            }
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
        if schedule { server?.flushStream(self) }
    }

    /// Everything queued since the last call. `overflowed` means the peer fell
    /// too far behind and the stream must end.
    func takePending() -> (data: Data, overflowed: Bool) {
        lock.withLock {
            flushScheduled = false
            let data = pending
            pending = Data()
            return (data, overflowed)
        }
    }

    /// Stop buffering; called once the connection is gone.
    func markClosed() {
        lock.withLock {
            closed = true
            pending = Data()
        }
    }
}
