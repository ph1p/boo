import Foundation
import SystemConfiguration

extension TerminalBridge {
    /// All known local hostnames (lowercased), collected once at launch.
    /// Covers: ProcessInfo.hostName, gethostname(2), SCDynamicStore LocalHostName,
    /// and the always-local aliases "localhost" / "127.0.0.1".
    static let localHostnames: Set<String> = {
        var names: Set<String> = ["localhost", "127.0.0.1"]

        // ProcessInfo.hostName  e.g. "pwork-mac.local"
        let piHost = ProcessInfo.processInfo.hostName
        names.insert(piHost.lowercased())
        if let short = piHost.split(separator: ".").first {
            names.insert(String(short).lowercased())
        }

        // gethostname(2)  e.g. "phinnoq"
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0, let hn = String(validating: buf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self), !hn.isEmpty {
            names.insert(hn.lowercased())
            if let short = hn.split(separator: ".").first {
                names.insert(String(short).lowercased())
            }
        }

        // SCDynamicStore LocalHostName  e.g. "pwork-mac"
        if let scName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            names.insert(scName.lowercased())
        }

        // SCDynamicStore ComputerName  e.g. "phinnoq"
        if let compName = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            names.insert(compName.lowercased())
        }

        return names
    }()

    /// Current username (lowercased), cached once at launch.
    static let localUsername: String = {
        NSUserName().lowercased()
    }()

    /// True when `host` matches any known local hostname.
    static func isLocalHost(_ host: String) -> Bool {
        localHostnames.contains(host.lowercased())
    }

    /// True when `user@host` looks like the local machine.
    /// Matches if host is any known local hostname, OR if both user and host
    /// match local identity (covers cases where the hostname source differs).
    static func isLocalUserAtHost(user: String, host: String) -> Bool {
        if isLocalHost(host) { return true }
        // user matches local user AND host appears in local names
        // (already covered above, but explicit for clarity)
        return false
    }
}
