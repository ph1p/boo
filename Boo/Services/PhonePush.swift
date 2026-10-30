import Cocoa

/// "Push to phone": POSTs short notices to an ntfy-style URL
/// (`https://ntfy.sh/<secret-topic>` or a self-hosted server) so a phone hears
/// about an agent waiting, a long command finishing or an SSH session dropping.
///
/// Off until the user sets a URL. A notice carries only the event, the
/// workspace name and an agent name or host, never terminal content. The
/// remote-control link it may attach has no token: the page keeps the token
/// from its last visit, and the push server must never see it.
@MainActor
final class PhonePush {
    static let shared = PhonePush()

    enum Event {
        case agentWaiting
        case commandFinished
        case sshDropped
    }

    struct Message: Equatable {
        let title: String
        let body: String
        let tags: String
    }

    /// At most one push per event kind in this window.
    nonisolated static let throttle: TimeInterval = 10
    /// The user counts as present while Boo is frontmost and had input this recently.
    static let presenceWindow: TimeInterval = 60

    private var lastSent: [Event: Date] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    // MARK: - Events

    func agentWaiting(agent: String, workspaceName: String) {
        send(.agentWaiting, Self.message(for: .agentWaiting, workspaceName: workspaceName, subject: agent))
    }

    /// Pushes an SSH or mosh session that dropped (exit 255), or any other
    /// command that ran past the threshold.
    func commandFinished(_ command: FinishedCommand, workspaceName: String) {
        if Self.isDroppedRemoteSession(command: command.command, exitCode: command.exitCode) {
            let host = command.host ?? Self.remoteHost(in: command.command) ?? "remote host"
            send(.sshDropped, Self.message(for: .sshDropped, workspaceName: workspaceName, subject: host))
            return
        }
        let threshold = AppSettings.shared.phonePushMinCommandSeconds
        guard threshold > 0, command.duration >= TimeInterval(threshold) else { return }
        let outcome = command.failed ? "exit \(command.exitCode ?? 0)" : "done"
        send(
            .commandFinished,
            Self.message(
                for: .commandFinished, workspaceName: workspaceName,
                subject: "\(outcome) after \(DurationFormat.compact(command.duration))"))
    }

    /// Sends a fixed sample so the user can check the URL from Settings.
    func sendTest(completion: @escaping @MainActor (Bool) -> Void) {
        guard let url = Self.endpoint(AppSettings.shared.phonePushURL) else { return completion(false) }
        let message = Message(title: "Boo", body: "Push to phone works.", tags: "white_check_mark")
        post(Self.request(url: url, message: message, click: nil)) { completion($0) }
    }

    // MARK: - Delivery

    private func send(_ event: Event, _ message: Message) {
        guard let url = Self.endpoint(AppSettings.shared.phonePushURL), !userIsPresent() else { return }
        let now = Date()
        guard Self.allows(event, at: now, lastSent: lastSent) else { return }
        lastSent[event] = now
        let click = RemoteControlServer.shared.isRunning ? RemoteControlServer.shared.linkWithoutToken : nil
        post(Self.request(url: url, message: message, click: click)) { _ in }
    }

    private func post(_ request: URLRequest, completion: @escaping @MainActor (Bool) -> Void) {
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<300).contains(status)
            if !ok {
                booLog(
                    .warning, .app,
                    "[PhonePush] delivery failed: \(error?.localizedDescription ?? "HTTP \(status)")")
            }
            Task { @MainActor in completion(ok) }
        }.resume()
    }

    private func userIsPresent() -> Bool {
        guard NSApp.isActive, let anyInput = CGEventType(rawValue: UInt32.max) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            < Self.presenceWindow
    }

    // MARK: - Pure helpers

    /// An http(s) URL with a host, or nil (push off).
    nonisolated static func endpoint(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    nonisolated static func allows(_ event: Event, at now: Date, lastSent: [Event: Date]) -> Bool {
        guard let last = lastSent[event] else { return true }
        return now.timeIntervalSince(last) >= throttle
    }

    nonisolated static func message(for event: Event, workspaceName: String, subject: String) -> Message {
        switch event {
        case .agentWaiting:
            return Message(title: workspaceName, body: "\(subject) is waiting for you", tags: "robot")
        case .commandFinished:
            return Message(title: workspaceName, body: "Command \(subject)", tags: "hourglass")
        case .sshDropped:
            return Message(title: workspaceName, body: "Connection to \(subject) dropped", tags: "warning")
        }
    }

    /// ntfy reads the title, tags and click link from headers; the body is plain text.
    nonisolated static func request(url: URL, message: Message, click: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(message.body.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(headerSafe(message.title), forHTTPHeaderField: "Title")
        request.setValue(message.tags, forHTTPHeaderField: "Tags")
        if let click { request.setValue(click, forHTTPHeaderField: "Click") }
        return request
    }

    /// ssh and mosh exit 255 when the connection fails or drops.
    nonisolated static func isDroppedRemoteSession(command: String, exitCode: Int32?) -> Bool {
        guard exitCode == 255, let first = command.split(separator: " ").first else { return false }
        let program = first.split(separator: "/").last ?? first
        return program == "ssh" || program == "mosh"
    }

    /// The first non-option argument of an ssh/mosh command line, minus any `user@`.
    nonisolated static func remoteHost(in command: String) -> String? {
        RemoteExplorer.sshDestination(in: command).map { String($0.split(separator: "@").last ?? Substring($0)) }
    }

    /// HTTP header values must be Latin-1; ntfy accepts RFC 2047 for the rest.
    nonisolated static func headerSafe(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return value }
        return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }
}
