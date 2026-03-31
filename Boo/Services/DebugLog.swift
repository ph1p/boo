import Foundation

/// Conditional debug logging. Enabled via Settings > Debug Logging.
/// Usage: debugLog("[Category] message")
func debugLog(_ message: @autoclosure () -> String) {
    guard AppSettings.shared.debugLogging else { return }
    NSLog("%@", message())
}
