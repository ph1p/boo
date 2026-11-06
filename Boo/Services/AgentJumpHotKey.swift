import Cocoa

/// A system-wide hotkey that brings Boo forward on the next agent that needs
/// the user (a question, a permission prompt, an error, an unread answer):
/// the global twin of Window → Jump to Next Waiting Agent (⇧⌘J). Off until a
/// shortcut is set in Settings → Keyboard Shortcuts.
@MainActor
final class AgentJumpHotKey {
    static let shared = AgentJumpHotKey()

    private var hotKey: GlobalHotKey?
    /// Why the configured hotkey is not active, for the settings page.
    private(set) var problem: String?
    private var settingsObserver: NSObjectProtocol?

    private init() {}

    func start() {
        configure()
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.configure() } }
    }

    func configure() {
        let text = AppSettings.shared.agentJumpHotkey.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, AppSettings.shared.agentsEnabled else {
            hotKey = nil
            problem = nil
            return
        }
        guard let spec = HotKeySpec.parse(text) else {
            hotKey = nil
            problem = "\"\(text)\" is not a valid shortcut"
            return
        }
        guard hotKey?.spec != spec else { return }
        hotKey = nil  // Release the old combination before claiming the new one.
        hotKey = GlobalHotKey(spec: spec) { Self.jump() }
        problem = hotKey == nil ? "\(spec.display) is taken by another app or Boo's Quick Terminal" : nil
    }

    /// Nothing waiting: a beep, so the key press is not silently lost.
    static func jump() {
        if !AgentInbox.shared.jumpToNextAttention() { NSSound.beep() }
    }
}
