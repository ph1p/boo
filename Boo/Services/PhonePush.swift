import Cocoa

/// Outgoing ntfy webhook for "you're away from the desk" events.
///
/// Browser push over the LAN-HTTP remote page is impossible (Web Push needs a
/// secure context), so Boo POSTs to an ntfy topic instead. Only metadata leaves
/// the machine — event type, workspace name, agent name — never terminal content.
enum PhonePush {
    enum Event: String, CaseIterable {
        case agentNeedsInput = "agent"
        case longCommand = "command"
        case sshDropped = "ssh"
        /// A trigger rule fired; carries the rule id, never the matched text.
        case trigger = "trigger"
    }

    /// ssh exits 255 when the connection itself failed or dropped.
    static let sshTransportExitCode: Int32 = 255

    /// A session shorter than this that exits 255 never connected — the user is
    /// still looking at the failure, so it is not a "dropped" push.
    static let sshMinimumSessionSeconds: TimeInterval = 5

    static let throttleInterval: TimeInterval = 10
    static let timeout: TimeInterval = 5

    /// Which push (if any) a finished command earns. ssh never counts as a long
    /// command: an interactive session ending normally is not news.
    static func classify(command: String, duration: TimeInterval, exitCode: Int32, threshold: TimeInterval) -> Event? {
        if isSSH(command) {
            return exitCode == sshTransportExitCode && duration >= sshMinimumSessionSeconds ? .sshDropped : nil
        }
        return duration >= threshold ? .longCommand : nil
    }

    static func isSSH(_ command: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace)
        // Skip leading `VAR=value` assignments and `exec`/`command` wrappers.
        guard let program = words.first(where: { !$0.contains("=") && $0 != "exec" && $0 != "command" }) else {
            return false
        }
        return (program as NSString).lastPathComponent == "ssh"
    }

    /// Title and body for an event. Deliberately takes no command, path or output.
    static func message(for event: Event, workspaceName: String, agentName: String?) -> (title: String, body: String) {
        let title = workspaceName.isEmpty ? "Boo" : workspaceName
        switch event {
        case .agentNeedsInput:
            return (title, "\(agentName ?? "Agent") needs your input")
        case .longCommand:
            return (title, "Long command finished")
        case .sshDropped:
            return (title, "SSH connection dropped")
        case .trigger:
            return (title, "Rule \"\(agentName ?? "trigger")\" matched")
        }
    }

    /// ntfy publish request. Fields go in query parameters (ntfy's `?title=` form)
    /// rather than headers so non-ASCII workspace names survive.
    static func request(
        topicURL: String, event: Event, workspaceName: String, agentName: String?, clickURL: String?
    ) -> URLRequest? {
        let trimmed = topicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            components.host?.isEmpty == false
        else { return nil }
        let msg = message(for: event, workspaceName: workspaceName, agentName: agentName)
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "title", value: msg.title))
        items.append(URLQueryItem(name: "tags", value: tag(for: event)))
        if let clickURL { items.append(URLQueryItem(name: "click", value: clickURL)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = Data(msg.body.utf8)
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return req
    }

    private static func tag(for event: Event) -> String {
        switch event {
        case .agentNeedsInput: return "robot"
        case .longCommand: return "hourglass"
        case .sshDropped: return "electric_plug"
        case .trigger: return "bell"
        }
    }

    /// At most one push per event type per interval.
    struct Throttle {
        private var lastSent: [Event: Date] = [:]

        mutating func allow(_ event: Event, now: Date = Date(), interval: TimeInterval = throttleInterval) -> Bool {
            if let last = lastSent[event], now.timeIntervalSince(last) < interval { return false }
            lastSent[event] = now
            return true
        }
    }
}

/// Sends pushes and remembers when each tab's command started.
@MainActor
final class PhonePusher {
    static let shared = PhonePusher()

    private var throttle = PhonePush.Throttle()
    private var commandStarts: [UUID: (command: String, date: Date)] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = PhonePush.timeout
        config.timeoutIntervalForResource = PhonePush.timeout
        return URLSession(configuration: config)
    }()

    private init() {}

    func commandStarted(tabID: UUID, command: String, at date: Date = Date()) {
        commandStarts[tabID] = (command, date)
    }

    /// Classifies the finished command; `focused` skips the push (the user is looking at it).
    func commandEnded(tabID: UUID, exitCode: Int32, workspaceName: String, focused: Bool, at date: Date = Date()) {
        guard let start = commandStarts.removeValue(forKey: tabID), !focused else { return }
        let threshold = TimeInterval(AppSettings.shared.phonePushLongCommandSeconds)
        guard
            let event = PhonePush.classify(
                command: start.command, duration: date.timeIntervalSince(start.date), exitCode: exitCode,
                threshold: threshold)
        else { return }
        send(event, workspaceName: workspaceName, agentName: nil)
    }

    func agentNeedsInput(workspaceName: String, agentName: String) {
        send(.agentNeedsInput, workspaceName: workspaceName, agentName: agentName)
    }

    func triggerFired(ruleID: String, workspaceName: String) {
        send(.trigger, workspaceName: workspaceName, agentName: ruleID)
    }

    /// Settings "Send Test" button: bypasses the enabled flag and throttle.
    func sendTest(topicURL: String, completion: @escaping @MainActor (String?) -> Void) {
        guard
            let req = PhonePush.request(
                topicURL: topicURL, event: .agentNeedsInput, workspaceName: "Boo", agentName: "Test",
                clickURL: Self.clickURL())
        else {
            completion("Not a valid http(s) URL")
            return
        }
        session.dataTask(with: req) { _, response, error in
            let failure = Self.failureText(response: response, error: error)
            Task { @MainActor in completion(failure) }
        }.resume()
    }

    private func send(_ event: PhonePush.Event, workspaceName: String, agentName: String?) {
        let settings = AppSettings.shared
        guard settings.phonePushEnabled, !settings.phonePushURL.isEmpty else { return }
        guard
            let req = PhonePush.request(
                topicURL: settings.phonePushURL, event: event, workspaceName: workspaceName, agentName: agentName,
                clickURL: Self.clickURL())
        else {
            booLog(.warning, .app, "[PhonePush] invalid topic URL — push skipped")
            return
        }
        guard throttle.allow(event) else { return }
        session.dataTask(with: req) { _, response, error in
            if let failure = Self.failureText(response: response, error: error) {
                booLog(.warning, .app, "[PhonePush] \(event.rawValue) push failed: \(failure)")
            }
        }.resume()
    }

    /// Remote web UI, without the token: the phone's page keeps it in localStorage,
    /// and the token must never reach the ntfy server.
    private static func clickURL() -> String? {
        let server = RemoteControlServer.shared
        guard server.isRunning else { return nil }
        let host = RemoteControlServer.lanIPAddress() ?? "127.0.0.1"
        return "http://\(host):\(server.port)/"
    }

    nonisolated private static func failureText(response: URLResponse?, error: Error?) -> String? {
        if let error { return error.localizedDescription }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return "HTTP \(http.statusCode)"
        }
        return nil
    }
}
