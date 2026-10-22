import Foundation

/// One concrete `Host` alias from an ssh config file.
struct SSHHost: Equatable, Identifiable, Sendable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    /// From a `# boo: group=… tags=a,b` comment.
    var group: String?
    var tags: [String] = []
    /// File and 1-based line of the `Host` line.
    var file: String
    var line: Int

    var id: String { alias }

    /// `user@host:port` as ssh will resolve it, for display.
    var address: String {
        var s = (user.map { "\($0)@" } ?? "") + (hostName ?? alias)
        if let port, port != 22 { s += ":\(port)" }
        return s
    }
}

struct SSHConfig: Equatable, Sendable {
    var hosts: [SSHHost] = []
    /// Every file read, the root first; watch these for changes.
    var files: [String] = []
}

/// Reads `Host` blocks from an ssh config, following `Include`. Only what the
/// Hosts list needs: wildcard and negated patterns are skipped, `Match` blocks
/// are ignored, and the first value of a keyword wins (as in ssh).
enum SSHConfigParser {
    static let maxIncludeDepth = 16

    static func parse(path: String, sshDir: String = ("~/.ssh" as NSString).expandingTildeInPath) -> SSHConfig {
        var config = SSHConfig()
        var seen = Set<String>()
        read(path: path, sshDir: sshDir, depth: 0, into: &config, seen: &seen)
        return config
    }

    private static func read(
        path: String, sshDir: String, depth: Int, into config: inout SSHConfig, seen: inout Set<String>
    ) {
        let path = (path as NSString).standardizingPath
        guard depth <= maxIncludeDepth, seen.insert(path).inserted else { return }
        config.files.append(path)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        // Indices into config.hosts of the block being read.
        var current: [Int] = []
        var pendingMeta: (group: String?, tags: [String])?
        var aliases = Set(config.hosts.map(\.alias))

        func apply(_ meta: (group: String?, tags: [String]), to indices: [Int]) {
            for i in indices {
                if let group = meta.group { config.hosts[i].group = group }
                if !meta.tags.isEmpty { config.hosts[i].tags = meta.tags }
            }
        }

        let lines = text.components(separatedBy: .newlines)
        for (offset, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let meta = booMeta(line) { pendingMeta = meta }
                continue
            }
            guard let (key, value) = keyword(line) else { continue }
            switch key {
            case "host":
                current = []
                for pattern in words(value) where !isPattern(pattern) && aliases.insert(pattern).inserted {
                    config.hosts.append(SSHHost(alias: pattern, file: path, line: offset + 1))
                    current.append(config.hosts.count - 1)
                }
                // A `# boo:` comment right above a Host line belongs to it.
                if let meta = pendingMeta { apply(meta, to: current) }
            case "match":
                current = []
            case "include":
                for target in words(value) {
                    for file in expandInclude(target, sshDir: sshDir) {
                        read(path: file, sshDir: sshDir, depth: depth + 1, into: &config, seen: &seen)
                    }
                }
                aliases = Set(config.hosts.map(\.alias))
            default:
                if let meta = pendingMeta { apply(meta, to: current) }
                let first = words(value).first
                for i in current {
                    switch key {
                    case "hostname" where config.hosts[i].hostName == nil: config.hosts[i].hostName = first
                    case "user" where config.hosts[i].user == nil: config.hosts[i].user = first
                    case "port" where config.hosts[i].port == nil: config.hosts[i].port = first.flatMap { Int($0) }
                    default: break
                    }
                }
            }
            pendingMeta = nil
        }
        if let meta = pendingMeta { apply(meta, to: current) }
    }

    /// `Key value` or `Key=value`, key lowercased; nil for a bare word.
    static func keyword(_ line: String) -> (String, String)? {
        guard let split = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let key = line[..<split].lowercased()
        var rest = line[split...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (key, String(rest))
    }

    /// Whitespace-separated words; double quotes (and single quotes, for shell
    /// command lines) group, trailing comments end.
    static func words(_ value: String, singleQuotes: Bool = false) -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var inWord = false
        for ch in value {
            if ch == quote {
                quote = nil
            } else if quote == nil && (ch == "\"" || (singleQuotes && ch == "'")) {
                quote = ch
                inWord = true
            } else if quote != nil {
                word.append(ch)
            } else if ch == " " || ch == "\t" {
                if inWord { result.append(word) }
                word = ""
                inWord = false
            } else if ch == "#" && !inWord {
                break
            } else {
                word.append(ch)
                inWord = true
            }
        }
        if inWord { result.append(word) }
        return result
    }

    static func isPattern(_ alias: String) -> Bool {
        alias.contains { $0 == "*" || $0 == "?" || $0 == "!" }
    }

    /// `# boo: group=prod tags=db,eu`.
    static func booMeta(_ comment: String) -> (group: String?, tags: [String])? {
        let body = comment.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix("boo:") else { return nil }
        var group: String?
        var tags: [String] = []
        for part in words(String(body.dropFirst(4))) {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, !pair[1].isEmpty else { continue }
            switch pair[0].lowercased() {
            case "group": group = pair[1]
            case "tags", "tag":
                tags = pair[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                    !$0.isEmpty
                }
            default: break
            }
        }
        return group == nil && tags.isEmpty ? nil : (group, tags)
    }

    /// Relative includes resolve against `~/.ssh`; globs expand sorted.
    static func expandInclude(_ target: String, sshDir: String) -> [String] {
        var path = (target as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (sshDir as NSString).appendingPathComponent(path) }
        guard path.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) else { return [path] }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].flatMap { String(cString: $0) } }.sorted()
    }
}

/// Picks the destination out of an `ssh …` command line.
enum SSHCommandLine {
    /// Options that take an argument (ssh(1)).
    private static let withArgument = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// `user@host` or `host` for `ssh [opts] dest [cmd]`; nil when not ssh.
    static func destination(of command: String) -> String? {
        let tokens = SSHConfigParser.words(command, singleQuotes: true)
        guard let first = tokens.first, (first as NSString).lastPathComponent == "ssh" else { return nil }
        var i = 1
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" { return i + 1 < tokens.count ? tokens[i + 1] : nil }
            guard token.hasPrefix("-"), token.count > 1 else { return token }
            // `-p22` carries its value; `-p 22` takes the next token.
            let flags = token.dropFirst()
            if let index = flags.firstIndex(where: { withArgument.contains($0) }),
                index == flags.index(before: flags.endIndex)
            {
                i += 1
            }
            i += 1
        }
        return nil
    }

    /// The host part of `user@host` / `ssh://user@host:port`.
    static func host(of destination: String) -> String {
        var d = destination
        if d.hasPrefix("ssh://") {
            d = String(d.dropFirst(6))
            if let colon = d.lastIndex(of: ":") { d = String(d[..<colon]) }
        }
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        return d
    }
}
