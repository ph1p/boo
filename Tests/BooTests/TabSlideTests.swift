import XCTest

@testable import Boo

final class TabSlideTests: XCTestCase {

    func testOffsetsSkipTabsThatStayed() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let old = [a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0), c: CGPoint(x: 200, y: 0)]
        let new = [a: CGPoint(x: 100, y: 0), b: CGPoint(x: 0, y: 0), c: CGPoint(x: 200, y: 0)]
        let offsets = TabSlide.offsets(old: old, new: new)
        XCTAssertEqual(offsets[a], CGPoint(x: -100, y: 0))
        XCTAssertEqual(offsets[b], CGPoint(x: 100, y: 0))
        XCTAssertNil(offsets[c])
    }

    func testOffsetStartsAtDeltaAndEasesToZero() {
        let id = UUID()
        let slide = TabSlide(from: [id: CGPoint(x: 80, y: -20)], start: 10)
        XCTAssertEqual(slide.offset(for: id, at: 10), CGPoint(x: 80, y: -20))
        let mid = slide.offset(for: id, at: 10 + TabSlide.duration / 2)
        XCTAssertLessThan(mid.x, 40, "ease-out covers more than half the way by mid-time")
        XCTAssertGreaterThan(mid.x, 0)
        XCTAssertEqual(slide.offset(for: id, at: 10 + TabSlide.duration), .zero)
        XCTAssertTrue(slide.isFinished(at: 10 + TabSlide.duration))
        XCTAssertEqual(slide.offset(for: UUID(), at: 10), .zero)
    }
}
