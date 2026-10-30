import Darwin
import Foundation

/// `AF_UNIX` setup shared by Boo's socket servers and clients.
enum UnixSocket {
    /// `path` as a socket address, or nil when it doesn't fit `sun_path`.
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                _ = sunPath.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, ptr, capacity) }
            }
        }
        return addr
    }

    /// A non-blocking socket listening at `path`, readable only by this user.
    /// Replaces any stale socket file there.
    static func listen(path: String, backlog: Int32, label: String) -> Int32? {
        guard var addr = address(path) else {
            booLog(.error, .socket, "[\(label)] socket path too long: \(path)")
            return nil
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            booLog(.error, .socket, "[\(label)] socket failed: \(errno)")
            return nil
        }
        // Non-blocking so accept never hangs.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else {
            booLog(.error, .socket, "[\(label)] bind failed: \(errno)")
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, backlog) == 0 else {
            booLog(.error, .socket, "[\(label)] listen failed: \(errno)")
            close(fd)
            return nil
        }
        return fd
    }

    /// A blocking socket connected to `path`.
    static func connect(path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The peer on `fd` runs as this user.
    static func peerIsSameUser(fd: Int32) -> Bool {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0 else { return false }
        return cred.cr_uid == getuid()
    }
}
