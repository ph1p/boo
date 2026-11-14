import XCTest

@testable import Boo

@MainActor
final class SystemInfoModelTests: XCTestCase {
    private final class FakeSystem: SystemInfoService {
        var ticks: (busy: UInt64, total: UInt64)? = (100, 1000)
        var sinceBootUsage = 0.1
        var memory = 0.5
        var net: (bytesIn: UInt64, bytesOut: UInt64) = (0, 0)

        func memoryUsage() -> Double { memory }
        func memoryTotals() -> (usedGB: Double, totalGB: Double) { (8, 16) }
        func diskUsage() -> (usage: Double, freeGB: Double) { (0.5, 100) }
        func loadAverage() -> Double { 1 }
        func cpuUsage() -> Double { sinceBootUsage }
        func cpuTicks() -> (busy: UInt64, total: UInt64)? { ticks }
        func uptime() -> TimeInterval { 60 }
        func networkThroughput() -> (bytesIn: UInt64, bytesOut: UInt64) { net }
        func batteryInfo() -> BatteryInfo? { nil }
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// A model whose first reading was taken at `start`.
    private func makeModel(_ system: FakeSystem) -> SystemInfoModel {
        let model = SystemInfoModel(service: system)
        model.service = system  // drops the init reading's timestamp
        model.refresh(now: start)
        return model
    }

    func testFirstReadingReportsAverageSinceBoot() {
        let model = makeModel(FakeSystem())
        XCTAssertEqual(model.state.cpuUsage, 0.1, accuracy: 0.0001)
    }

    func testCPUUsageIsTheTickDeltaBetweenReadings() {
        let system = FakeSystem()
        let model = makeModel(system)

        system.ticks = (150, 1100)  // 50 busy of 100 ticks
        model.refresh(now: start.addingTimeInterval(2))

        XCTAssertEqual(model.state.cpuUsage, 0.5, accuracy: 0.0001)
    }

    func testCPUUsageKeepsLastValueWhenCountersWrap() {
        let system = FakeSystem()
        let model = makeModel(system)
        system.ticks = (150, 1100)
        model.refresh(now: start.addingTimeInterval(2))

        system.ticks = (10, 20)
        model.refresh(now: start.addingTimeInterval(4))

        XCTAssertEqual(model.state.cpuUsage, 0.5, accuracy: 0.0001)
    }

    func testNetworkRateIsBytesPerSecond() {
        let system = FakeSystem()
        let model = makeModel(system)

        system.net = (4096, 1024)
        model.refresh(now: start.addingTimeInterval(2))

        XCTAssertEqual(model.state.netRateIn, 2048)
        XCTAssertEqual(model.state.netRateOut, 512)
    }

    func testReadingsCloserThanTheMinimumGapAreSkipped() {
        let system = FakeSystem()
        let model = makeModel(system)

        system.memory = 0.9
        model.refresh(now: start.addingTimeInterval(0.2))
        XCTAssertEqual(model.state.memoryUsage, 0.5)

        model.refresh(now: start.addingTimeInterval(2))
        XCTAssertEqual(model.state.memoryUsage, 0.9)
    }

    func testHistoryIsCappedAndOnlyRecordedOnRequest() {
        let system = FakeSystem()
        let model = makeModel(system)
        XCTAssertTrue(model.state.cpuHistory.isEmpty)

        for step in 1...(SystemInfoModel.historyLength + 5) {
            system.memory = Double(step) / 100
            model.refresh(now: start.addingTimeInterval(Double(step) * 2), recordHistory: true)
        }

        XCTAssertEqual(model.state.memoryHistory.count, SystemInfoModel.historyLength)
        XCTAssertEqual(model.state.memoryHistory.last ?? 0, 0.65, accuracy: 0.0001)
        XCTAssertEqual(model.state.memoryHistory.first ?? 0, 0.06, accuracy: 0.0001)
    }

    func testHistoryRestartsAfterAGap() {
        let system = FakeSystem()
        let model = makeModel(system)
        model.refresh(now: start.addingTimeInterval(2), recordHistory: true)
        model.refresh(now: start.addingTimeInterval(4), recordHistory: true)
        XCTAssertEqual(model.state.cpuHistory.count, 2)

        model.refresh(now: start.addingTimeInterval(120), recordHistory: true)

        XCTAssertEqual(model.state.cpuHistory.count, 1)
    }

    func testFormatting() {
        XCTAssertEqual(SystemInfoFormat.rate(512), "512 B/s")
        XCTAssertEqual(SystemInfoFormat.rate(2048), "2.0 KB/s")
        XCTAssertEqual(SystemInfoFormat.rate(300 * 1024), "300 KB/s")
        XCTAssertEqual(SystemInfoFormat.rate(5 * 1024 * 1024), "5.0 MB/s")
        XCTAssertEqual(SystemInfoFormat.percent(0.426), "43%")
        XCTAssertEqual(SystemInfoFormat.gigabytes(6.54), "6.5 GB")
        XCTAssertEqual(SystemInfoFormat.gigabytes(120.4), "120 GB")
        XCTAssertEqual(SystemInfoFormat.uptime(7200), "2h 0m")
        XCTAssertEqual(SystemInfoFormat.uptime(90061), "1d 1h 1m")
    }
}
