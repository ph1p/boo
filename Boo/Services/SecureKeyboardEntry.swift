import Carbon
import Cocoa

/// Secure Keyboard Entry: while on, other processes can't observe keystrokes
/// (event taps, keyloggers) typed into Boo.
///
/// Secure input is system-wide while enabled, so it's held only while Boo is
/// the active app, as Terminal and iTerm2 do; otherwise every other app would
/// lose features like text expansion while Boo merely runs in the background.
@MainActor
final class SecureKeyboardEntry {
    static let shared = SecureKeyboardEntry()

    /// Whether Boo currently holds a secure input request (the calls nest).
    private var holding = false
    private var observers: [NSObjectProtocol] = []

    /// Whether secure input is on system-wide (Boo's or another app's).
    static var isActive: Bool { IsSecureEventInputEnabled() }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { SecureKeyboardEntry.shared.apply() }
                })
        }
        apply()
    }

    /// Matches the held request to the setting and the app's active state.
    func apply() {
        let want = AppSettings.shared.secureKeyboardEntry && NSApp.isActive
        guard want != holding else { return }
        if want {
            EnableSecureEventInput()
        } else {
            DisableSecureEventInput()
        }
        holding = want
    }
}
