import AppKit

extension KubeStore {
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

    func logs(_ target: String, container: String? = nil, previous: Bool = false) {
        openTab(
            KubeCommand.logs(target, container: container, previous: previous, context: context, namespace: namespace))
    }

    /// Probes for a free local port on click; the menu label shows the preferred one.
    func portForward(_ target: String, port: Int) {
        let local = KubeCommand.freeLocalPort(for: port)
        openTab(KubeCommand.portForward(target, port: port, localPort: local, context: context, namespace: namespace))
    }

    func describe(_ target: String) {
        openTab(KubeCommand.describe(target, context: context, namespace: namespace))
    }

    func showYAML(_ target: String) {
        openTab(KubeCommand.yaml(target, context: context, namespace: namespace))
    }

    func edit(_ target: String) {
        openTab(KubeCommand.edit(target, context: context, namespace: namespace))
    }

    func showEvents() {
        openTab(KubeCommand.events(context: context, namespace: namespace))
    }

    func openIngress(_ ingress: KubeIngress, host: String) {
        guard let url = ingress.url(for: host) else { return }
        NSWorkspace.shared.open(url)
    }

    func delete(_ kind: KubeKind, name: String, info: String) {
        guard
            confirm(
                "Delete \(kind.resource) \(name)?", info: "In \(context ?? "?")/\(namespace). \(info)",
                button: "Delete")
        else { return }
        resourceAction(["delete", kind.resource, name, "--wait=false"])
    }

    func rolloutRestart(_ kind: KubeKind, _ workload: KubeWorkload) {
        guard
            confirm(
                "Restart \(kind.resource) \(workload.name)?",
                info: "Rolls all pods of \(workload.name) in \(context ?? "?")/\(namespace).", button: "Restart")
        else { return }
        resourceAction(["rollout", "restart", kind.resource + "/" + workload.name])
    }

    func scale(_ kind: KubeKind, _ workload: KubeWorkload) {
        let alert = NSAlert()
        alert.messageText = "Scale \(workload.name)"
        alert.informativeText = "Replicas in \(context ?? "?")/\(namespace) (now \(workload.replicas)):"
        alert.alertStyle = .warning
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        field.stringValue = String(workload.replicas)
        alert.accessoryView = field
        alert.addButton(withTitle: "Scale")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let replicas = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), replicas >= 0 else {
            BooAlert.showTransient("Replicas must be a whole number ≥ 0")
            return
        }
        resourceAction(["scale", kind.resource + "/" + workload.name, "--replicas=\(replicas)"])
    }

    /// Runs a cronjob now, as a job named `<cronjob>-manual-<timestamp>`.
    func trigger(_ cronJob: KubeCronJob) {
        guard
            confirm(
                "Run cronjob \(cronJob.name) now?", info: "Creates a job in \(context ?? "?")/\(namespace).",
                button: "Run")
        else { return }
        resourceAction(["create", "job", Self.manualJobName(for: cronJob.name), "--from=cronjob/" + cronJob.name])
    }

    func setSuspended(_ cronJob: KubeCronJob, _ suspended: Bool) {
        resourceAction([
            "patch", "cronjob", cronJob.name, "--type=merge", "-p", "{\"spec\":{\"suspend\":\(suspended)}}"
        ])
    }

    /// Job names are DNS labels: at most 63 characters.
    nonisolated static func manualJobName(for cronJob: String, date: Date = Date()) -> String {
        let suffix = "-manual-\(Int(date.timeIntervalSince1970))"
        var prefix = String(cronJob.prefix(63 - suffix.count))
        while prefix.hasSuffix("-") { prefix.removeLast() }
        return prefix + suffix
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
                case let r? where r.status != 0: Self.lastLine(r.stderr) ?? "kubectl exited \(r.status)"
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
}
