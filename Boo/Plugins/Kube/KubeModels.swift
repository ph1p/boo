import Foundation

/// Contexts from `kubectl config view -o json`.
struct KubeConfigInfo: Equatable, Sendable {
    var current: String?
    /// Context name → its default namespace (nil: "default").
    var contexts: [String: String?] = [:]

    var namespace: String {
        current.flatMap { contexts[$0] ?? nil } ?? "default"
    }

    var contextNames: [String] {
        contexts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func parse(_ data: Data) -> KubeConfigInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var info = KubeConfigInfo()
        let current = root["current-context"] as? String
        info.current = current?.isEmpty == false ? current : nil
        for entry in root["contexts"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let namespace = (entry["context"] as? [String: Any])?["namespace"] as? String
            info.contexts[name] = namespace?.isEmpty == false ? namespace : nil
        }
        return info
    }
}

enum KubeKind: String, CaseIterable, Sendable {
    case pods, deployments, services
}

struct KubePod: Equatable, Identifiable, Sendable {
    var name: String
    var phase: String
    /// CrashLoopBackOff, ImagePullBackOff, Init:…, Terminating; nil when none.
    var reason: String?
    var ready: Int
    var total: Int
    var restarts: Int
    var containers: [String]
    var ports: [Int]
    var createdAt: Date?

    var id: String { name }

    /// `reason` or the phase, as `kubectl get pods` shows STATUS.
    var status: String { reason ?? phase }

    enum Health { case ok, pending, failing, done }

    var health: Health {
        if let reason {
            return reason == "Terminating" || reason.hasPrefix("Init:") || reason == "ContainerCreating"
                || reason == "PodInitializing" ? .pending : .failing
        }
        switch phase {
        case "Running": return ready == total ? .ok : .pending
        case "Succeeded": return .done
        case "Pending": return .pending
        default: return .failing
        }
    }

    static func parse(_ object: [String: Any]) -> KubePod? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let specContainers = spec["containers"] as? [[String: Any]] ?? []
        let statuses = status["containerStatuses"] as? [[String: Any]] ?? []
        let initStatuses = status["initContainerStatuses"] as? [[String: Any]] ?? []

        var reason: String?
        if meta["deletionTimestamp"] != nil {
            reason = "Terminating"
        } else if let initReason = initStatuses.lazy.compactMap(Self.stuckReason).first {
            reason = "Init:" + initReason
        } else {
            reason = statuses.lazy.compactMap(Self.stuckReason).first ?? status["reason"] as? String
        }

        return KubePod(
            name: name,
            phase: status["phase"] as? String ?? "Unknown",
            reason: reason,
            ready: statuses.filter { $0["ready"] as? Bool == true }.count,
            total: specContainers.count,
            restarts: statuses.reduce(0) { $0 + ($1["restartCount"] as? Int ?? 0) },
            containers: specContainers.compactMap { $0["name"] as? String },
            ports: specContainers.flatMap {
                ($0["ports"] as? [[String: Any]] ?? []).compactMap { $0["containerPort"] as? Int }
            },
            createdAt: (meta["creationTimestamp"] as? String).flatMap(KubeTime.parse))
    }

    /// Waiting reason, or a non-zero terminated reason (Error, OOMKilled).
    private static func stuckReason(_ status: [String: Any]) -> String? {
        let state = status["state"] as? [String: Any] ?? [:]
        if let waiting = state["waiting"] as? [String: Any] { return waiting["reason"] as? String }
        if let terminated = state["terminated"] as? [String: Any], terminated["exitCode"] as? Int != 0 {
            return terminated["reason"] as? String
        }
        return nil
    }
}

struct KubeDeployment: Equatable, Identifiable, Sendable {
    var name: String
    var replicas: Int
    var ready: Int
    var updated: Int

    var id: String { name }

    static func parse(_ object: [String: Any]) -> KubeDeployment? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        return KubeDeployment(
            name: name,
            replicas: spec["replicas"] as? Int ?? 1,
            ready: status["readyReplicas"] as? Int ?? 0,
            updated: status["updatedReplicas"] as? Int ?? 0)
    }
}

struct KubeSvc: Equatable, Identifiable, Sendable {
    struct Port: Equatable, Sendable {
        var port: Int
        var proto: String
        var nodePort: Int?
    }

    var name: String
    var type: String
    var clusterIP: String?
    var ports: [Port]

    var id: String { name }

    var portsLabel: String {
        ports.map { p in "\(p.port)" + (p.nodePort.map { ":\($0)" } ?? "") + (p.proto == "TCP" ? "" : "/\(p.proto)") }
            .joined(separator: ",")
    }

    static func parse(_ object: [String: Any]) -> KubeSvc? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let ip = spec["clusterIP"] as? String
        return KubeSvc(
            name: name,
            type: spec["type"] as? String ?? "ClusterIP",
            clusterIP: ip == "None" || ip?.isEmpty == true ? nil : ip,
            ports: (spec["ports"] as? [[String: Any]] ?? []).compactMap { p in
                (p["port"] as? Int).map {
                    Port(port: $0, proto: p["protocol"] as? String ?? "TCP", nodePort: p["nodePort"] as? Int)
                }
            })
    }
}

/// One line of `kubectl get … -w -o json --output-watch-events`.
struct KubeWatchEvent {
    enum Kind: String {
        case added = "ADDED"
        case modified = "MODIFIED"
        case deleted = "DELETED"
        case error = "ERROR"
    }

    var kind: Kind
    var object: [String: Any]

    static func parse(_ data: Data) -> KubeWatchEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let kind = (root["type"] as? String).flatMap(Kind.init(rawValue:)),
            let object = root["object"] as? [String: Any]
        else { return nil }
        return KubeWatchEvent(kind: kind, object: object)
    }
}

/// Resources by name for one kind, kept sorted for display.
struct KubeCollection<Item: Identifiable & Equatable>: Equatable where Item.ID == String {
    private(set) var items: [Item] = []

    mutating func apply(_ kind: KubeWatchEvent.Kind, _ item: Item) {
        let index = items.firstIndex { $0.id == item.id }
        switch (kind, index) {
        case (.deleted, let i?): items.remove(at: i)
        case (.added, let i?), (.modified, let i?): items[i] = item
        case (.added, nil), (.modified, nil):
            let at =
                items.firstIndex { $0.id.localizedStandardCompare(item.id) == .orderedDescending } ?? items.endIndex
            items.insert(item, at: at)
        default: break
        }
    }

    mutating func removeAll() { items = [] }
}

/// Splits a byte stream of concatenated JSON objects (what `kubectl -o json -w`
/// prints, pretty-printed and not newline-delimited) into whole objects.
struct JSONObjectStreamSplitter {
    private var buffer: [UInt8] = []
    private var depth = 0
    private var inString = false
    private var escaped = false
    /// Index in `buffer` where the current top-level object starts.
    private var start: Int?
    /// Bytes of `buffer` already scanned.
    private var scanned = 0

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var objects: [Data] = []
        var i = scanned
        while i < buffer.count {
            let byte = buffer[i]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                if depth > 0 { inString = true }
            } else if byte == UInt8(ascii: "{") {
                if depth == 0 { start = i }
                depth += 1
            } else if byte == UInt8(ascii: "}"), depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    objects.append(Data(buffer[s...i]))
                    start = nil
                }
            }
            i += 1
        }
        // Drop consumed bytes; keep an object still being read.
        let keepFrom = start ?? buffer.count
        buffer.removeFirst(keepFrom)
        scanned = buffer.count
        if start != nil { start = 0 }
        return objects
    }

    mutating func reset() { self = JSONObjectStreamSplitter() }
}

enum KubeTime {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// kubectl command lines for the terminal.
enum KubeCommand {
    static func base(context: String?, namespace: String?) -> String {
        var parts = ["kubectl"]
        if let context { parts += ["--context", shellEscape(context)] }
        if let namespace { parts += ["-n", shellEscape(namespace)] }
        return parts.joined(separator: " ")
    }

    static func exec(_ pod: String, container: String?, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " exec -it " + shellEscape(pod)
            + (container.map { " -c " + shellEscape($0) } ?? "")
            + " -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }

    static func logs(_ target: String, container: String?, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " logs -f --tail 200 " + shellEscape(target)
            + (container.map { " -c " + shellEscape($0) }
                ?? (target.hasPrefix("deployment/") ? " --all-containers" : ""))
    }

    /// Local port matches the remote one unless that needs root.
    static func localPort(for remote: Int) -> Int { remote < 1024 ? 8000 + remote : remote }

    static func portForward(_ target: String, port: Int, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " port-forward " + shellEscape(target)
            + " \(localPort(for: port)):\(port)"
    }

    static func describe(_ target: String, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " describe " + shellEscape(target)
    }
}
