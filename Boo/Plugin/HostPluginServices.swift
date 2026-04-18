import Foundation
import IOKit.ps

/// Concrete implementation of PluginServices wrapping existing system APIs.
@MainActor
final class HostPluginServices: PluginServices {
    let shell: ShellService = HostShellService()
    let system: SystemInfoService = HostSystemInfoService()
}

/// Runs shell commands via Process.
final class HostShellService: ShellService {
    func run(executable: String, arguments: [String], cwd: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            if let cwd = cwd {
                task.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            continuation.resume(returning: output)
        }
    }
}

/// Provides system info using the same methods SystemInfoPlugin used statically.
struct HostSystemInfoService: SystemInfoService {

    // MARK: - Memory

    func memoryUsage() -> Double {
        let totals = memoryTotals()
        guard totals.totalGB > 0 else { return 0 }
        return min(1, totals.usedGB / totals.totalGB)
    }

    func memoryTotals() -> (usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let usedBytes = active + wired + compressed
        return (usedBytes / 1_073_741_824, totalBytes / 1_073_741_824)
    }

    // MARK: - Disk

    func diskUsage() -> (usage: Double, freeGB: Double) {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory())
        else { return (0, 0) }
        let total = (attrs[.systemSize] as? Int64) ?? 0
        let free = (attrs[.systemFreeSize] as? Int64) ?? 0
        guard total > 0 else { return (0, 0) }
        let usage = 1.0 - Double(free) / Double(total)
        let freeGB = Double(free) / 1_073_741_824
        return (usage, freeGB)
    }

    // MARK: - CPU / Load

    func loadAverage() -> Double {
        var loadavg = [Double](repeating: 0, count: 3)
        getloadavg(&loadavg, 3)
        return loadavg[0]
    }

    func cpuUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        var totalUser: Int32 = 0
        var totalSystem: Int32 = 0
        var totalIdle: Int32 = 0
        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += info[offset + Int(CPU_STATE_USER)] + info[offset + Int(CPU_STATE_NICE)]
            totalSystem += info[offset + Int(CPU_STATE_SYSTEM)]
            totalIdle += info[offset + Int(CPU_STATE_IDLE)]
        }
        let total = Double(totalUser + totalSystem + totalIdle)
        guard total > 0 else { return 0 }
        return Double(totalUser + totalSystem) / total
    }

    // MARK: - Uptime

    func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Network

    func networkThroughput() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let data = unsafeBitCast(addr.pointee.ifa_data, to: UnsafeMutablePointer<if_data>.self)
                totalIn += UInt64(data.pointee.ifi_ibytes)
                totalOut += UInt64(data.pointee.ifi_obytes)
            }
            ptr = addr.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }

    // MARK: - Battery

    func batteryInfo() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
            let first = sources.first,
            let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any]
        else { return nil }

        let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        let source = desc[kIOPSPowerSourceStateKey] as? String
        let isPluggedIn = source == kIOPSACPowerValue

        return BatteryInfo(
            level: Double(capacity) / Double(max(1, maxCapacity)),
            isCharging: isCharging,
            isPluggedIn: isPluggedIn
        )
    }
}
