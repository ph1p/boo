import Foundation

/// Injectable services that plugins use instead of calling system APIs directly.
@MainActor protocol PluginServices: AnyObject {
    var shell: ShellService { get }
    var system: SystemInfoService { get }
}

/// Runs shell commands on behalf of plugins.
///
/// A non-zero exit is not an error: plugins shell out to commands where failure is
/// a normal answer (`grep` with no match, `git diff --exit-code`), and they want the
/// output. Only a command that never ran to completion throws.
protocol ShellService {
    func run(executable: String, arguments: [String], cwd: String?) async throws -> String
}

/// Thrown when a `ShellService` command cannot be run to completion.
/// Declared alongside the protocol so every implementation throws the same type.
enum ShellServiceError: Error {
    /// The executable failed to launch, or exceeded the wall-clock timeout.
    case commandFailed(String)
}

/// Provides system resource information.
protocol SystemInfoService {
    func memoryUsage() -> Double
    func memoryTotals() -> (usedGB: Double, totalGB: Double)
    func diskUsage() -> (usage: Double, freeGB: Double)
    func loadAverage() -> Double
    func cpuUsage() -> Double
    /// Cumulative CPU ticks since boot, summed over all cores. Two readings
    /// give the usage between them; `cpuUsage()` alone is the average since boot.
    /// `nil` when the service has no tick counters.
    func cpuTicks() -> (busy: UInt64, total: UInt64)?
    func uptime() -> TimeInterval
    func networkThroughput() -> (bytesIn: UInt64, bytesOut: UInt64)
    func batteryInfo() -> BatteryInfo?
}

extension SystemInfoService {
    func cpuTicks() -> (busy: UInt64, total: UInt64)? { nil }
}

/// Battery status for portable Macs.
struct BatteryInfo: Equatable {
    let level: Double  // 0.0-1.0
    let isCharging: Bool
    let isPluggedIn: Bool
}
