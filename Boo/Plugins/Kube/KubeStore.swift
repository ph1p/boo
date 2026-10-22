import AppKit
import Combine

extension Notification.Name {
    /// The kube context or namespace changed (status bar redraw).
    static let kubeContextChanged = Notification.Name("BooKubeContextChanged")
}

/// Shells out to kubectl for the Kube plugin. Idle while the plugin is
/// disabled: the kubeconfig is polled (by mtime) only while enabled, and
/// resources are watched only while the panel is active.
@MainActor
final class KubeStore: ObservableObject {
    static let shared = KubeStore()
    static let pluginID = "kube"

    @Published private(set) var config = KubeConfigInfo()
    @Published private(set) var namespaces: [String] = []
    @Published private(set) var pods = KubeCollection<KubePod>()
    @Published private(set) var deployments = KubeCollection<KubeDeployment>()
    @Published private(set) var services = KubeCollection<KubeSvc>()
    /// Last watch or config error, for the panel.
    @Published private(set) var error: String?
    @Published private(set) var kubectlPath: String?

    private var timer: Timer?
    private var configMTime: Date?
    private var configLoading = false
    private var watching = false
    private var watches: [KubeKind: KubeWatch] = [:]
    /// Context/namespace the running watches were started for.
    private var watchTarget: (context: String, namespace: String)?

    private init() {}

    var isEnabled: Bool { AppSettings.shared.isPluginEnabled(Self.pluginID) }

    /// Starts the kubeconfig poll; cheap (a stat) and a no-op while disabled.
    func start() {
        guard timer == nil else { return }
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
        if kubectlPath == nil { kubectlPath = Self.findKubectl() }
        let mtime = Self.kubeconfigPaths().compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
        guard mtime != configMTime else { return }
        configMTime = mtime
        reloadConfig()
    }

    func reloadConfig() {
        guard let kubectl = kubectlPath, !configLoading else { return }
        configLoading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.run(kubectl, ["config", "view", "-o", "json"], timeout: 10)
            let info = result.flatMap { $0.status == 0 ? KubeConfigInfo.parse(Data($0.stdout.utf8)) : nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = KubeStore.shared
                    store.configLoading = false
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

    private func stopWatches() {
        for watch in watches.values { watch.stop() }
        watches = [:]
        watchTarget = nil
    }

    private func restartWatchesIfNeeded() {
        guard let kubectl = kubectlPath, let context = config.current else {
            stopWatches()
            clearResources()
            error = kubectlPath == nil ? "kubectl not found" : "No current context in kubeconfig"
            return
        }
        let namespace = config.namespace
        if let target = watchTarget, target.context == context, target.namespace == namespace, !watches.isEmpty {
            return
        }
        stopWatches()
        clearResources()
        error = nil
        watchTarget = (context, namespace)
        for kind in KubeKind.allCases {
            let watch = KubeWatch(kind: kind, kubectl: kubectl, context: context, namespace: namespace)
            watch.onEvent = { [weak self] event in self?.handle(event, kind: kind) }
            watch.onError = { [weak self] message in self?.error = message }
            watches[kind] = watch
            watch.start()
        }
        loadNamespaces()
    }

    private func clearResources() {
        KubeKind.allCases.forEach(watchRelisting)
    }

    private func handle(_ event: KubeWatchEvent, kind: KubeKind) {
        if event.kind == .error {
            error = (event.object["message"] as? String) ?? "watch error"
            return
        }
        error = nil
        switch kind {
        case .pods: KubePod.parse(event.object).map { pods.apply(event.kind, $0) }
        case .deployments: KubeDeployment.parse(event.object).map { deployments.apply(event.kind, $0) }
        case .services: KubeSvc.parse(event.object).map { services.apply(event.kind, $0) }
        }
    }

    /// A watch restarted (relist): drop what it had so deleted items go.
    fileprivate func watchRelisting(_ kind: KubeKind) {
        switch kind {
        case .pods: pods.removeAll()
        case .deployments: deployments.removeAll()
        case .services: services.removeAll()
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

    // MARK: - Context / namespace

    func useContext(_ name: String) {
        runAction(["config", "use-context", name]) { _ in KubeStore.shared.reloadConfig() }
    }

    func useNamespace(_ name: String) {
        runAction(["config", "set-context", "--current", "--namespace", name]) { _ in KubeStore.shared.reloadConfig() }
    }

    // MARK: - Actions

    /// Opens a new tab in the active pane running `command`.
    func openTab(_ command: String) {
        WindowManager.shared.activeController?.openCommandTab(command)
    }

    var context: String? { config.current }
    var namespace: String { config.namespace }

    func exec(_ pod: KubePod, container: String?) {
        openTab(KubeCommand.exec(pod.name, container: container, context: context, namespace: namespace))
    }

    func logs(_ target: String, container: String? = nil) {
        openTab(KubeCommand.logs(target, container: container, context: context, namespace: namespace))
    }

    func portForward(_ target: String, port: Int) {
        openTab(KubeCommand.portForward(target, port: port, context: context, namespace: namespace))
    }

    func describe(_ target: String) {
        openTab(KubeCommand.describe(target, context: context, namespace: namespace))
    }

    func deletePod(_ pod: KubePod) {
        guard
            confirm(
                "Delete pod \(pod.name)?",
                info: "In \(context ?? "?")/\(namespace). A controller may recreate it.", button: "Delete")
        else { return }
        resourceAction(["delete", "pod", pod.name, "--wait=false"])
    }

    func rolloutRestart(_ deployment: KubeDeployment) {
        guard
            confirm(
                "Restart deployment \(deployment.name)?",
                info: "Rolls all pods of \(deployment.name) in \(context ?? "?")/\(namespace).", button: "Restart")
        else { return }
        resourceAction(["rollout", "restart", "deployment/" + deployment.name])
    }

    func scale(_ deployment: KubeDeployment) {
        let alert = NSAlert()
        alert.messageText = "Scale \(deployment.name)"
        alert.informativeText = "Replicas in \(context ?? "?")/\(namespace) (now \(deployment.replicas)):"
        alert.alertStyle = .warning
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        field.stringValue = String(deployment.replicas)
        alert.accessoryView = field
        alert.addButton(withTitle: "Scale")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let replicas = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), replicas >= 0 else {
            BooAlert.showTransient("Replicas must be a whole number ≥ 0")
            return
        }
        resourceAction(["scale", "deployment/" + deployment.name, "--replicas=\(replicas)"])
    }

    private func confirm(_ message: String, info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Runs a kubectl command against the current context/namespace.
    private func resourceAction(_ args: [String]) {
        guard let context else { return }
        runAction(["--context", context, "-n", namespace] + args) { _ in }
    }

    /// Runs kubectl in the background; errors show as a toast.
    private func runAction(_ args: [String], completion: @escaping @MainActor (Bool) -> Void) {
        guard let kubectl = kubectlPath else {
            BooAlert.showTransient("kubectl not found")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(kubectl, args, timeout: 60)
            let error: String? =
                switch result {
                case nil: "kubectl timed out"
                case let r? where r.status != 0:
                    r.stderr.split(separator: "\n").last.map(String.init) ?? "kubectl exited \(r.status)"
                default: nil
                }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error { BooAlert.showTransient(error) }
                    completion(error == nil)
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

    nonisolated static func findKubectl() -> String? {
        let candidates =
            ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl", "/usr/bin/kubectl"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/kubectl" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func kubeconfigPaths() -> [String] {
        if let env = ProcessInfo.processInfo.environment["KUBECONFIG"], !env.isEmpty {
            return env.split(separator: ":").map { ($0 as NSString).expandingTildeInPath }
        }
        return [(NSHomeDirectory() as NSString).appendingPathComponent(".kube/config")]
    }

    /// GUI apps get a minimal PATH; credential plugins (gke-gcloud-auth-plugin,
    /// aws, kubelogin) live in the usual install dirs.
    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/google-cloud-sdk/bin",
            "/opt/homebrew/share/google-cloud-sdk/bin", home + "/.krew/bin"
        ]
        env["PATH"] = ((env["PATH"].map { [$0] } ?? ["/usr/bin:/bin:/usr/sbin:/sbin"]) + extra).joined(separator: ":")
        return env
    }

    nonisolated static func run(
        _ kubectl: String, _ args: [String], timeout: TimeInterval
    ) -> RemoteExplorer.CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        process.arguments = args
        process.environment = environment()
        return RemoteExplorer.runProcessCapturing(process, timeout: timeout)
    }
}

/// One `kubectl get <kind> -w` process, restarted with backoff when it exits.
@MainActor
final class KubeWatch {
    let kind: KubeKind
    let kubectl: String
    let context: String
    let namespace: String
    var onEvent: ((KubeWatchEvent) -> Void)?
    var onError: ((String) -> Void)?

    private var process: Process?
    private var stopped = false
    private var failures = 0
    private var startedAt = Date()

    init(kind: KubeKind, kubectl: String, context: String, namespace: String) {
        self.kind = kind
        self.kubectl = kubectl
        self.context = context
        self.namespace = namespace
    }

    func start() {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        process.arguments = [
            "--context", context, "-n", namespace, "get", kind.rawValue, "--watch", "--output-watch-events", "-o",
            "json"
        ]
        process.environment = KubeStore.environment()
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // The handler runs serially on a background queue; only it touches the splitter.
        nonisolated(unsafe) var splitter = JSONObjectStreamSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = splitter.feed(data).compactMap(KubeWatchEvent.parse)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.failures = 0
                    for event in events { self.onEvent?(event) }
                }
            }
        }
        process.terminationHandler = { [weak self] proc in
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(status: status, stderr: stderr) }
            }
        }
        startedAt = Date()
        do {
            try process.run()
            self.process = process
        } catch {
            exited(status: -1, stderr: error.localizedDescription)
        }
    }

    func stop() {
        stopped = true
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// Watches end on their own (server timeouts, network); relist after a backoff.
    private func exited(status: Int32, stderr: String) {
        guard !stopped else { return }
        process = nil
        // A watch that ran a while ended normally; restart promptly.
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 } else { failures += 1 }
        if status != 0, let line = stderr.split(separator: "\n").last {
            onError?(String(line))
        }
        let delay = failures == 0 ? 1 : min(30, pow(2, Double(min(failures, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            KubeStore.shared.watchRelisting(self.kind)
            self.start()
        }
    }
}
