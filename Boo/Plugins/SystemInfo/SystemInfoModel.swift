import Combine
import Foundation

/// One reading of every metric, plus the recent history the panel graphs.
struct SystemInfoState: Equatable {
    var cpuUsage: Double = 0  // 0.0-1.0
    var memoryUsage: Double = 0  // 0.0-1.0
    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var diskUsage: Double = 0  // 0.0-1.0
    var diskFreeGB: Double = 0
    var loadAverage: Double = 0
    var uptimeSeconds: TimeInterval = 0
    var battery: BatteryInfo?
    var netRateIn: UInt64 = 0  // bytes/sec
    var netRateOut: UInt64 = 0  // bytes/sec

    // Oldest first, at most `SystemInfoModel.historyLength` samples.
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var netInHistory: [Double] = []
    var netOutHistory: [Double] = []
}

/// Samples system metrics and publishes them. The sidebar panel observes the
/// model directly, so a new sample repaints the panel without a plugin cycle.
/// The sampling timer runs only while a panel is on screen.
@MainActor
final class SystemInfoModel: ObservableObject {
    nonisolated static let sampleInterval: TimeInterval = 2
    nonisolated static let historyLength = 60
    /// Two readings closer than this are too few CPU ticks apart to be a usable rate.
    static let minimumGap: TimeInterval = 1

    @Published private(set) var state = SystemInfoState()

    var service: SystemInfoService {
        didSet { resetBaselines() }
    }

    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var previousNet: (bytesIn: UInt64, bytesOut: UInt64)?
    private var lastRefresh: Date?
    private var lastHistorySample: Date?
    private var timer: Timer?
    private var visiblePanels = 0

    init(service: SystemInfoService = HostSystemInfoService()) {
        self.service = service
        refresh()
    }

    // MARK: - Sampling

    /// Reads every metric. `recordHistory` also appends the reading to the graphs.
    func refresh(now: Date = Date(), recordHistory: Bool = false) {
        let elapsed = lastRefresh.map { now.timeIntervalSince($0) }
        if let elapsed, elapsed >= 0, elapsed < Self.minimumGap { return }

        var next = state
        next.memoryUsage = service.memoryUsage()
        let totals = service.memoryTotals()
        next.memoryUsedGB = totals.usedGB
        next.memoryTotalGB = totals.totalGB
        (next.diskUsage, next.diskFreeGB) = service.diskUsage()
        next.loadAverage = service.loadAverage()
        next.uptimeSeconds = service.uptime()
        next.battery = service.batteryInfo()
        next.cpuUsage = sampleCPU(fallback: next.cpuUsage)

        let net = service.networkThroughput()
        if let previous = previousNet, let elapsed, elapsed > 0 {
            next.netRateIn = Self.rate(from: previous.bytesIn, to: net.bytesIn, over: elapsed)
            next.netRateOut = Self.rate(from: previous.bytesOut, to: net.bytesOut, over: elapsed)
        }
        previousNet = net
        lastRefresh = now

        if recordHistory {
            // A gap (panel was hidden) would draw as a straight line; start over instead.
            if let last = lastHistorySample, now.timeIntervalSince(last) > Self.sampleInterval * 3 {
                next.cpuHistory = []
                next.memoryHistory = []
                next.netInHistory = []
                next.netOutHistory = []
            }
            Self.append(next.cpuUsage, to: &next.cpuHistory)
            Self.append(next.memoryUsage, to: &next.memoryHistory)
            Self.append(Double(next.netRateIn), to: &next.netInHistory)
            Self.append(Double(next.netRateOut), to: &next.netOutHistory)
            lastHistorySample = now
        }

        if next != state { state = next }
    }

    /// Usage between this reading and the previous one. The first reading has
    /// no interval yet and reports the average since boot.
    private func sampleCPU(fallback: Double) -> Double {
        guard let ticks = service.cpuTicks() else { return service.cpuUsage() }
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return service.cpuUsage() }
        // Counters wrapped or did not advance: keep the last value.
        guard ticks.total > previous.total, ticks.busy >= previous.busy else { return fallback }
        return min(1, Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total))
    }

    private static func rate(from old: UInt64, to new: UInt64, over elapsed: TimeInterval) -> UInt64 {
        guard new >= old else { return 0 }
        let perSecond = Double(new - old) / elapsed
        // Double(UInt64.max) rounds up to 2^64, which UInt64() cannot hold.
        guard perSecond.isFinite, perSecond < Double(UInt64.max) else { return 0 }
        return UInt64(perSecond)
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
    }

    private func resetBaselines() {
        previousTicks = nil
        previousNet = nil
        lastRefresh = nil
    }

    // MARK: - Live Updates

    func panelAppeared() {
        visiblePanels += 1
        guard timer == nil else { return }
        refresh(recordHistory: true)
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.refresh(recordHistory: true)
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        guard visiblePanels == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}
