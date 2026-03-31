import XCTest

@testable import Boo

final class DensityMetricsTests: XCTestCase {

    func testComfortableMetrics() {
        let metrics = DensityMetrics(for: .comfortable)
        XCTAssertEqual(metrics.listItemHeight, 28)
        XCTAssertEqual(metrics.statusBarHeight, 28)
        XCTAssertEqual(metrics.panelPaddingH, 12)
        XCTAssertEqual(metrics.panelPaddingV, 8)
        XCTAssertEqual(metrics.panelGap, 8)
        XCTAssertEqual(metrics.iconSize, 16)
        XCTAssertEqual(metrics.fontSize, 13)
    }

    func testCompactMetrics() {
        let metrics = DensityMetrics(for: .compact)
        XCTAssertEqual(metrics.listItemHeight, 22)
        XCTAssertEqual(metrics.statusBarHeight, 24)
        XCTAssertEqual(metrics.panelPaddingH, 8)
        XCTAssertEqual(metrics.panelPaddingV, 6)
        XCTAssertEqual(metrics.panelGap, 4)
        XCTAssertEqual(metrics.iconSize, 14)
        XCTAssertEqual(metrics.fontSize, 12)
    }

}
