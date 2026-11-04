import Foundation
import SystemConfiguration

extension TerminalBridge {
    private static func normalizedHostVariants(_ host: String) -> Set<String> {
        let trimmed =
            host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .controlCharacters)
            .lowercased()
        guard !trimmed.isEmpty else { return [] }

        var variants: Set<String> = [trimmed]
        if let short = trimmed.split(separator: ".").first, !short.isEmpty {
            variants.insert(String(short))
        }
        return variants
    }

    /// All known local hostnames (lowercased), collected once at launch.
    /// Covers: ProcessInfo.hostName, gethostname(2), SCDynamicStore LocalHostName,
    /// and the always-local aliases "localhost" / "127.0.0.1" / "::1".
    static let localHostnames: Set<String> = {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

        // ProcessInfo.hostName  e.g. "pwork-mac.local"
        let piHost = ProcessInfo.processInfo.hostName
        for variant in normalizedHostVariants(piHost) {
            names.insert(variant)
        }

        // gethostname(2)
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0,
            let hn = String(validating: buf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self),
            !hn.isEmpty
        {
            for variant in normalizedHostVariants(hn) {
                names.insert(variant)
            }
        }

        // SCDynamicStore LocalHostName  e.g. "pwork-mac"
        if let scName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            for variant in normalizedHostVariants(scName) {
                names.insert(variant)
            }
        }

        // SCDynamicStore ComputerName
        if let compName = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            for variant in normalizedHostVariants(compName) {
                names.insert(variant)
            }
        }

        return names
    }()

    /// True when `host` matches any known local hostname.
    static func isLocalHost(_ host: String) -> Bool {
        let variants = normalizedHostVariants(host)
        return variants.contains { localHostnames.contains($0) }
    }

}
