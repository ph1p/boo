import Cocoa
import Combine

/// Composes and posts VoiceOver announcements when terminal focus changes.
/// This is the accessibility equivalent of the visual sidebar transformation —
/// screen reader users hear the context summary on every pane switch.
final class ContextAnnouncementEngine {
    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.2

    /// Cached last-announced state to avoid duplicate announcements.
    private var lastAnnouncedPaneID: UUID?

    /// Start listening to a TerminalBridge for focus change events.
    func subscribe(to bridge: TerminalBridge) {
        bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                if case .focusChanged = event {
                    self?.scheduleAnnouncement(for: bridge.state)
                }
            }
            .store(in: &cancellables)
    }

    /// Schedule a debounced announcement. Rapid focus changes (e.g. holding
    /// Cmd+Opt+Arrow) only announce the final state.
    private func scheduleAnnouncement(for state: BridgeState) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.announce(state: state)
        }
    }

    private func announce(state: BridgeState) {
        guard state.paneID != lastAnnouncedPaneID else { return }
        lastAnnouncedPaneID = state.paneID

        guard NSWorkspace.shared.isVoiceOverEnabled else { return }

        let text = Self.composeAnnouncement(from: state)
        guard !text.isEmpty else { return }

        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: userInfo
        )
    }

    /// Compose the announcement string from terminal state.
    /// Format: "{environment}, {path}, {git branch if present}"
    static func composeAnnouncement(from state: BridgeState) -> String {
        var parts: [String] = []

        // Environment type
        if let session = state.remoteSession {
            switch session {
            case .ssh(let host, _):
                parts.append("SSH to \(host)")
            case .docker(let container):
                parts.append("Docker container \(container)")
            }
        } else {
            parts.append("Local terminal")
        }

        // Working directory
        let path = abbreviatePath(state.workingDirectory)
        if !path.isEmpty {
            parts.append(path)
        }

        // Foreground process (if not a shell)
        if !state.foregroundProcess.isEmpty {
            parts.append(state.foregroundProcess)
        }

        return parts.joined(separator: ", ")
    }

    private static let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    private static func abbreviatePath(_ path: String) -> String {
        if path.hasPrefix(homeDir) {
            return "~" + path.dropFirst(homeDir.count)
        }
        return path
    }

    deinit {
        debounceTimer?.invalidate()
    }
}
