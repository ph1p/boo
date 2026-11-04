import AppKit
import Combine

extension Notification.Name {
    /// The kube context or namespace changed (status bar redraw).
    static let kubeContextChanged = Notification.Name("BooKubeContextChanged")
}

/// Shells out to kubectl for the Kube plugin. Idle while the plugin is
/// disabled: the kubeconfig is polled (by mtime) only while enabled, and
/// resources are watched only while the panel is active, and only for the
/// sections that are expanded.
@MainActor
final class KubeStore: ObservableObject {
    static let shared = KubeStore()
    static let pluginID = "kube"
    private static let expandedKey = "KubeExpandedKinds"

    @Published private(set) var config = KubeConfigInfo()
    @Published private(set) var namespaces: [String] = []
    @Published private(set) var pods = KubeCollection<KubePod>()
    @Published private(set) var deployments = KubeCollection<KubeWorkload>()
    @Published private(set) var statefulsets = KubeCollection<KubeWorkload>()
    @Published private(set) var daemonsets = KubeCollection<KubeWorkload>()
    @Published private(set) var jobs = KubeCollection<KubeJob>()
    @Published private(set) var cronjobs = KubeCollection<KubeCronJob>()
    @Published private(set) var services = KubeCollection<KubeSvc>()
    @Published private(set) var ingresses = KubeCollection<KubeIngress>()
    /// Config / kubectl error, for the panel header.
    @Published private(set) var error: String?
    /// Last watch error per kind (e.g. RBAC forbids listing it), shown in its section.
    @Published private(set) var errors: [KubeKind: String] = [:]
    @Published private(set) var kubectlPath: String?
    /// Sections the user has open; only these are watched. Global, like the store.
    @Published private(set) var expanded: Set<KubeKind>

    private var timer: Timer?
    private var configMTime: Date?
    private var configLoading = false
    private var watching = false
    private var watches: [KubeKind: KubeWatch] = [:]
    /// Pending `dropStale` per kind after a watch relist.
    private var staleDrops: [KubeKind: DispatchWorkItem] = [:]
    /// Context/namespace the running watches were started for.
    private var watchTarget: (context: String, namespace: String)?

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.expandedKey) {
            expanded = Set(saved.compactMap(KubeKind.init(rawValue:)))
        } else {
            expanded = KubeKind.expandedByDefault
        }
    }

    var isEnabled: Bool { AppSettings.shared.isPluginEnabled(Self.pluginID) }

    /// Starts the kubeconfig poll; cheap (a stat) and a no-op while disabled.
    func start() {
        guard timer == nil else { return }
        LoginShellEnvironment.shared.prewarm()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { KubeStore.shared.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard isEnabled else {
            if watching { stopWatching() }
            if config != KubeConfigInfo() {
                config = KubeConfigInfo()
                configMTime = nil
                NotificationCenter.default.post(name: .kubeContextChanged, object: nil)
            }
            return
        }
        // Retried every tick: the login shell's PATH (mise/asdf/nix) arrives a moment
        // after launch.
        if kubectlPath == nil { kubectlPath = Self.findKubectl(wait: false) }
        let mtime = Self.kubeconfigPaths().compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
        // Record the mtime only once a load can start: otherwise a kubectl found
        // later (or a change during a load) would never trigger the reload.
        guard mtime != configMTime, kubectlPath != nil, !configLoading else { return }
        configMTime = mtime
        reloadConfig()
    }

    func reloadConfig() {
        guard let kubectl = kubectlPath, !configLoading else { return }
        configLoading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.run(kubectl, ["config", "view", "-o", "json"], timeout: 10)
            let info = result.flatMap { $0.status == 0 ? KubeConfigInfo.parse(Data($0.stdout.utf8)) : nil }
            let failure = result.flatMap { $0.status == 0 ? nil : Self.lastLine($0.stderr) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = KubeStore.shared
                    store.configLoading = false
                    // The panel shows its own placeholder for "no context".
                    store.error = failure
                    store.apply(info ?? KubeConfigInfo())
                }
            }
        }
    }

    private func apply(_ info: KubeConfigInfo) {
        guard info != config else { return }
        let contextChanged = info.current != config.current
        config = info
        NotificationCenter.default.post(name: .kubeContextChanged, object: nil)
        if contextChanged { namespaces = [] }
        if watching { restartWatchesIfNeeded() }
    }

    // MARK: - Watching

    func startWatching() {
        guard isEnabled else { return }
        start()
        watching = true
        restartWatchesIfNeeded()
    }

    func stopWatching() {
        watching = false
        stopWatches()
    }

    func isExpanded(_ kind: KubeKind) -> Bool { expanded.contains(kind) }

    /// Opens or closes a section; starts or stops only that kind's watch.
    func toggle(_ kind: KubeKind) {
        if expanded.remove(kind) == nil { expanded.insert(kind) }
        UserDefaults.standard.set(expanded.map(\.rawValue).sorted(), forKey: Self.expandedKey)
        if expanded.contains(kind) {
            if let target = watchTarget { startWatch(kind, context: target.context, namespace: target.namespace) }
        } else {
            watches.removeValue(forKey: kind)?.stop()
            cancelStaleDrop(kind)
            perform(.removeAll, on: kind)
            errors[kind] = nil
        }
    }

    private func stopWatches() {
        for watch in watches.values { watch.stop() }
        watches = [:]
        for kind in staleDrops.keys { cancelStaleDrop(kind) }
        watchTarget = nil
    }

    private func restartWatchesIfNeeded() {
        guard kubectlPath != nil, let context = config.current else {
            stopWatches()
            clearResources()
            // Keep a `kubectl config view` failure; it explains the missing context better.
            if error == nil || kubectlPath == nil {
                error = kubectlPath == nil ? "kubectl not found" : "No current context in kubeconfig"
            }
            return
        }
        let namespace = config.namespace
        if let target = watchTarget, target.context == context, target.namespace == namespace {
            return
        }
        stopWatches()
        // Another context/namespace: nothing of the old one may linger.
        clearResources()
        error = nil
        errors = [:]
        watchTarget = (context, namespace)
        for kind in KubeKind.allCases where expanded.contains(kind) {
            startWatch(kind, context: context, namespace: namespace)
        }
        loadNamespaces()
    }

    private func startWatch(_ kind: KubeKind, context: String, namespace: String) {
        guard let kubectl = kubectlPath, watches[kind] == nil else { return }
        let watch = KubeWatch(kind: kind, kubectl: kubectl, context: context, namespace: namespace)
        watch.onEvents = { [weak self] events in self?.handle(events, kind: kind) }
        watch.onError = { [weak self] message in self?.errors[kind] = message }
        watch.onRelist = { [weak self] in self?.watchRelisting(kind) }
        watches[kind] = watch
        watch.start()
    }

    private func clearResources() {
        for kind in KubeKind.allCases { perform(.removeAll, on: kind) }
    }

    private func handle(_ events: [KubeWatchEvent], kind: KubeKind) {
        if let failure = events.last(where: { $0.kind == .error }) {
            errors[kind] = (failure.object["message"] as? String) ?? "watch error"
        } else if errors[kind] != nil {
            errors[kind] = nil
        }
        let changes = events.filter { $0.kind != .error }
        guard !changes.isEmpty else { return }
        switch kind {
        case .pods: update(\.pods, changes, parse: KubePod.parse)
        case .deployments: update(\.deployments, changes, parse: KubeWorkload.parse)
        case .statefulsets: update(\.statefulsets, changes, parse: KubeWorkload.parse)
        case .daemonsets: update(\.daemonsets, changes, parse: KubeWorkload.parse)
        case .jobs: update(\.jobs, changes, parse: KubeJob.parse)
        case .cronjobs: update(\.cronjobs, changes, parse: KubeCronJob.parse)
        case .services: update(\.services, changes, parse: KubeSvc.parse)
        case .ingresses: update(\.ingresses, changes, parse: KubeIngress.parse)
        }
        // After a relist, the initial ADDED burst re-sends everything that still
        // exists; once it goes quiet, the leftovers were deleted while the watch was down.
        if staleDrops[kind] != nil { scheduleStaleDrop(kind, after: 2) }
    }

    /// Applies a batch to a copy and publishes once, instead of once per event.
    private func update<Item>(
        _ keyPath: ReferenceWritableKeyPath<KubeStore, KubeCollection<Item>>, _ events: [KubeWatchEvent],
        parse: ([String: Any]) -> Item?
    ) {
        mutate(keyPath) { collection in
            for event in events {
                if let item = parse(event.object) { collection.apply(event.kind, item) }
            }
        }
    }

    /// Mutates a copy and publishes only when something changed.
    private func mutate<Item>(
        _ keyPath: ReferenceWritableKeyPath<KubeStore, KubeCollection<Item>>,
        _ body: (inout KubeCollection<Item>) -> Void
    ) {
        var collection = self[keyPath: keyPath]
        body(&collection)
        if collection != self[keyPath: keyPath] { self[keyPath: keyPath] = collection }
    }

    /// A watch restarted and re-lists: keep the rows visible (no flicker), drop the
    /// ones it doesn't re-send.
    private func watchRelisting(_ kind: KubeKind) {
        perform(.markStale, on: kind)
        scheduleStaleDrop(kind, after: 10)
    }

    private func scheduleStaleDrop(_ kind: KubeKind, after delay: TimeInterval) {
        staleDrops[kind]?.cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                let store = KubeStore.shared
                store.staleDrops[kind] = nil
                store.perform(.dropStale, on: kind)
            }
        }
        staleDrops[kind] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelStaleDrop(_ kind: KubeKind) {
        staleDrops.removeValue(forKey: kind)?.cancel()
    }

    private enum CollectionOp {
        case markStale, dropStale, removeAll

        func apply<Item>(_ collection: inout KubeCollection<Item>) {
            switch self {
            case .markStale: collection.markStale()
            case .dropStale: collection.dropStale()
            case .removeAll: collection.removeAll()
            }
        }
    }

    private func perform(_ op: CollectionOp, on kind: KubeKind) {
        switch kind {
        case .pods: mutate(\.pods, op.apply)
        case .deployments: mutate(\.deployments, op.apply)
        case .statefulsets: mutate(\.statefulsets, op.apply)
        case .daemonsets: mutate(\.daemonsets, op.apply)
        case .jobs: mutate(\.jobs, op.apply)
        case .cronjobs: mutate(\.cronjobs, op.apply)
        case .services: mutate(\.services, op.apply)
        case .ingresses: mutate(\.ingresses, op.apply)
        }
    }

    func loadNamespaces() {
        guard let kubectl = kubectlPath, let context = config.current else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.run(
                kubectl, ["--context", context, "get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"],
                timeout: 15)
            guard let result, result.status == 0 else { return }
            let names = result.stdout.split(separator: " ").map(String.init).sorted()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = KubeStore.shared
                    if store.config.current == context, store.namespaces != names { store.namespaces = names }
                }
            }
        }
    }

    // MARK: - Status

    /// A rule switches to a profile for this context (e.g. a red prod theme).
    func isGuardedContext(_ context: String?) -> Bool {
        guard let context else { return false }
        return RulesStore.shared.active.rules.contains { rule in
            guard rule.enabled, case .profile = rule.then, let pattern = rule.when.kubeContext else { return false }
            return Glob.matches(pattern, context)
        }
    }

    // MARK: - Process

    /// `wait: false` on the main thread: uses the login-shell PATH only once resolved.
    nonisolated static func findKubectl(wait: Bool = true) -> String? {
        let path = environment(wait: wait)["PATH"] ?? ""
        return BinaryScanner.path(of: "kubectl", in: path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    }

    /// KUBECONFIG as the login shell exports it (falls back to Boo's own environment).
    nonisolated static func kubeconfigPaths() -> [String] {
        // Read the one variable directly: this runs on every 3s tick.
        let value =
            LoginShellEnvironment.shared.snapshot?["KUBECONFIG"] ?? ProcessInfo.processInfo.environment["KUBECONFIG"]
        if let value, !value.isEmpty {
            return value.split(separator: ":").map { ($0 as NSString).expandingTildeInPath }
        }
        return [(NSHomeDirectory() as NSString).appendingPathComponent(".kube/config")]
    }

    /// GUI apps get launchd's minimal environment. Take PATH and KUBECONFIG from the
    /// login shell, plus the usual install dirs of kubectl and its credential plugins
    /// (gke-gcloud-auth-plugin, aws, kubelogin).
    nonisolated static func environment(wait: Bool = true) -> [String: String] {
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/google-cloud-sdk/bin",
            "/opt/homebrew/share/google-cloud-sdk/bin", home + "/.krew/bin", home + "/.rd/bin",
            "/Applications/Docker.app/Contents/Resources/bin", home + "/.nix-profile/bin", "/run/current-system/sw/bin",
            home + "/.local/share/mise/shims", home + "/.asdf/shims"
        ]
        return LoginShellEnvironment.shared.environment(wait: wait, extraPaths: extra)
    }

    nonisolated static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
    }

    nonisolated static func run(
        _ kubectl: String, _ args: [String], timeout: TimeInterval
    ) -> Subprocess.Result? {
        Subprocess.run(kubectl, args, environment: environment(), timeout: timeout)
    }
}
