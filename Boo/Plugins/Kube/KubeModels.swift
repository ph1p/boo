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
    case pods, deployments, statefulsets, daemonsets, jobs, cronjobs, services, ingresses

    var title: String {
        switch self {
        case .pods: "Pods"
        case .deployments: "Deployments"
        case .statefulsets: "StatefulSets"
        case .daemonsets: "DaemonSets"
        case .jobs: "Jobs"
        case .cronjobs: "CronJobs"
        case .services: "Services"
        case .ingresses: "Ingresses"
        }
    }

    /// `kubectl` resource prefix for `kind/name` targets.
    var resource: String {
        switch self {
        case .pods: "pod"
        case .deployments: "deployment"
        case .statefulsets: "statefulset"
        case .daemonsets: "daemonset"
        case .jobs: "job"
        case .cronjobs: "cronjob"
        case .services: "svc"
        case .ingresses: "ingress"
        }
    }

    /// Sections open (and watched) until the user collapses them; the rest start
    /// collapsed so a fresh install runs three kubectl watches, not eight.
    static let expandedByDefault: Set<KubeKind> = [.pods, .deployments, .services]
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

/// A deployment, statefulset or daemonset: desired vs ready replicas.
struct KubeWorkload: Equatable, Identifiable, Sendable {
    var name: String
    var replicas: Int
    var ready: Int
    var updated: Int

    var id: String { name }
    var healthy: Bool { ready >= replicas }

    static func parse(_ object: [String: Any]) -> KubeWorkload? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        // Daemonsets have no spec.replicas: one pod per scheduled node.
        if let desired = status["desiredNumberScheduled"] as? Int {
            return KubeWorkload(
                name: name, replicas: desired, ready: status["numberReady"] as? Int ?? 0,
                updated: status["updatedNumberScheduled"] as? Int ?? 0)
        }
        return KubeWorkload(
            name: name,
            replicas: spec["replicas"] as? Int ?? 1,
            ready: status["readyReplicas"] as? Int ?? 0,
            updated: status["updatedReplicas"] as? Int ?? 0)
    }
}

struct KubeJob: Equatable, Identifiable, Sendable {
    var name: String
    var completions: Int
    var succeeded: Int
    var failed: Int
    var active: Int
    var createdAt: Date?

    var id: String { name }

    enum Health { case running, complete, failed }

    var health: Health {
        if succeeded >= completions { return .complete }
        if active == 0 && failed > 0 { return .failed }
        return .running
    }

    static func parse(_ object: [String: Any]) -> KubeJob? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let conditions = status["conditions"] as? [[String: Any]] ?? []
        let failedCondition = conditions.contains {
            $0["type"] as? String == "Failed" && $0["status"] as? String == "True"
        }
        return KubeJob(
            name: name,
            completions: spec["completions"] as? Int ?? 1,
            succeeded: status["succeeded"] as? Int ?? 0,
            failed: max(status["failed"] as? Int ?? 0, failedCondition ? 1 : 0),
            active: status["active"] as? Int ?? 0,
            createdAt: (meta["creationTimestamp"] as? String).flatMap(KubeTime.parse))
    }
}

struct KubeCronJob: Equatable, Identifiable, Sendable {
    var name: String
    var schedule: String
    var suspended: Bool
    var active: Int
    var lastSchedule: Date?

    var id: String { name }

    static func parse(_ object: [String: Any]) -> KubeCronJob? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        return KubeCronJob(
            name: name,
            schedule: spec["schedule"] as? String ?? "",
            suspended: spec["suspend"] as? Bool ?? false,
            active: (status["active"] as? [Any])?.count ?? 0,
            lastSchedule: (status["lastScheduleTime"] as? String).flatMap(KubeTime.parse))
    }
}

struct KubeIngress: Equatable, Identifiable, Sendable {
    var name: String
    var hosts: [String]
    var tls: Bool

    var id: String { name }

    /// Browser URL for a host; https when the ingress terminates TLS for it.
    /// Nil for wildcard hosts (`*.example.com`), which name no single site.
    func url(for host: String) -> URL? {
        guard !host.hasPrefix("*") else { return nil }
        return URL(string: (tls ? "https://" : "http://") + host)
    }

    static func parse(_ object: [String: Any]) -> KubeIngress? {
        guard let meta = object["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        let spec = object["spec"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        let hosts = (spec["rules"] as? [[String: Any]] ?? []).compactMap { $0["host"] as? String }
            .filter { seen.insert($0).inserted }
        return KubeIngress(
            name: name,
            hosts: hosts,
            tls: !(spec["tls"] as? [Any] ?? []).isEmpty)
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
    /// Items from before a watch restart, not yet re-sent by the new watch.
    /// Kept visible (no flicker) until `dropStale` removes what really went away.
    private(set) var stale: Set<String> = []

    mutating func apply(_ kind: KubeWatchEvent.Kind, _ item: Item) {
        stale.remove(item.id)
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

    /// A watch restarted and will re-list everything: mark what we have as stale.
    mutating func markStale() { stale = Set(items.map(\.id)) }

    /// Drops items the restarted watch didn't re-send (deleted while it was down).
    mutating func dropStale() {
        guard !stale.isEmpty else { return }
        items.removeAll { stale.contains($0.id) }
        stale = []
    }

    mutating func removeAll() {
        items = []
        stale = []
    }
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
    /// Pod events arrive by the hundred; building a formatter per parse showed up in profiles.
    /// ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        formatter.date(from: string)
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

    static func logs(
        _ target: String, container: String?, previous: Bool = false, context: String?, namespace: String?
    ) -> String {
        let multiPod = ["deployment/", "statefulset/", "daemonset/", "job/"].contains { target.hasPrefix($0) }
        return base(context: context, namespace: namespace) + " logs "
            + (previous ? "--previous --tail 500 " : "-f --tail 200 ")
            + shellEscape(target)
            + (container.map { " -c " + shellEscape($0) } ?? (multiPod ? " --all-containers --prefix" : ""))
    }

    /// Local port matches the remote one unless that needs root.
    static func localPort(for remote: Int) -> Int { remote < 1024 ? 8000 + remote : remote }

    /// `localPort(for:)` when it's free, else the next free port above it, so a second
    /// forward (or a dev server already on 8080) doesn't make kubectl exit at once.
    static func freeLocalPort(for remote: Int, isFree: (Int) -> Bool = KubeCommand.isPortFree) -> Int {
        let preferred = localPort(for: remote)
        return (preferred..<min(preferred + 100, 65536)).first(where: isFree) ?? preferred
    }

    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    static func portForward(
        _ target: String, port: Int, localPort: Int, context: String?, namespace: String?
    ) -> String {
        base(context: context, namespace: namespace) + " port-forward " + shellEscape(target)
            + " \(localPort):\(port)"
    }

    static func yaml(_ target: String, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " get " + shellEscape(target) + " -o yaml"
    }

    static func edit(_ target: String, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " edit " + shellEscape(target)
    }

    static func events(context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " get events --sort-by=.lastTimestamp -w"
    }

    static func describe(_ target: String, context: String?, namespace: String?) -> String {
        base(context: context, namespace: namespace) + " describe " + shellEscape(target)
    }
}
