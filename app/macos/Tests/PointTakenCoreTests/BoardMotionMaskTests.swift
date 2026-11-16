import XCTest
@testable import PointTakenCore

final class BoardMotionMaskTests: XCTestCase {
    private let columns = BoardMotionMask.columns, rows = BoardMotionMask.rows

    /// A page: varied static cells, and a "carousel" box whose cells take `cover` as their value.
    private func page(cover: UInt8, box: (x: Range<Int>, y: Range<Int>) = (40..<56, 10..<20), base: UInt8 = 0) -> BoardFrameFingerprint {
        var values = [UInt8](repeating: 0, count: columns * rows)
        for y in 0..<rows { for x in 0..<columns {
            values[y * columns + x] = box.x.contains(x) && box.y.contains(y) ? cover : UInt8((x * 7 + y * 13) % 200) &+ base
        } }
        return BoardFrameFingerprint(values: values)
    }

    func testATurningCarouselIsLearnedAndLeftOut() {
        let first = page(cover: 30), second = page(cover: 220)
        var mask = BoardMotionMask()
        // the whole-screen distance sees a change well above "same viewport" (0.002) and even "navigation" (0.045)
        XCTAssertGreaterThan(first.distance(to: second), 0.045)
        mask.learn(from: first, to: second)
        XCTAssertTrue(mask.usable)
        XCTAssertEqual(mask.distance(first, second), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(mask.movingDistance(first, second), 0.5)
        // a real change elsewhere still shows
        var elsewhere = second.values
        for y in 25..<35 { for x in 5..<30 { elsewhere[y * columns + x] = 255 } }
        XCTAssertGreaterThan(mask.distance(second, BoardFrameFingerprint(values: elsewhere)), 0.01)
    }

    func testMarksOnTheMovingPartAreRecognised() {
        var mask = BoardMotionMask()
        mask.learn(from: page(cover: 30), to: page(cover: 220))
        // a box drawn around the cover (cells 40–55 × 10–19 → x 0.62–0.87, y 0.25–0.5)
        XCTAssertTrue(mask.touches([[0.6, 0.22], [0.9, 0.22], [0.9, 0.52], [0.6, 0.52], [0.6, 0.22]]))
        XCTAssertFalse(mask.touches([[0.05, 0.7], [0.3, 0.8]]))
        XCTAssertFalse(BoardMotionMask().touches([[0.6, 0.22], [0.9, 0.52]]))
    }

    func testMostOfTheScreenChangingIsNeverAWidget() {
        var mask = BoardMotionMask()
        // a slideshow advancing, a page loading: three quarters of the screen
        mask.learn(from: page(cover: 30, box: (0..<64, 0..<30)), to: page(cover: 220, box: (0..<64, 0..<30)))
        XCTAssertTrue(mask.isEmpty)
        // small learned parts that would add up past half the screen stop being added
        for i in 0..<12 {
            let box = (x: (i % 4) * 16..<((i % 4) * 16 + 14), y: (i / 4) * 13..<((i / 4) * 13 + 11))
            mask.learn(from: page(cover: 30, box: box), to: page(cover: 220, box: box))
        }
        XCTAssertLessThanOrEqual(mask.share, BoardMotionMask.widgetLimit)
        mask.reset()
        XCTAssertTrue(mask.isEmpty)
        // without a usable mask, distances are the plain ones
        XCTAssertEqual(mask.distance(page(cover: 30), page(cover: 220)), page(cover: 30).distance(to: page(cover: 220)))
    }

    func testGateIgnoresTheCarouselNearAnInput() {
        let first = page(cover: 30), second = page(cover: 220)
        var plain = BoardPageGate()
        _ = plain.observe(first, context: "safari|首页", at: 0)
        plain.interaction(at: 0.5, scroll: false)
        XCTAssertEqual(plain.observe(second, context: "safari|首页", at: 1), .leave)

        var mask = BoardMotionMask()
        mask.learn(from: first, to: second)
        var gate = BoardPageGate()
        _ = gate.observe(first, context: "safari|首页", at: 0, mask: mask)
        gate.interaction(at: 0.5, scroll: false)
        XCTAssertEqual(gate.observe(second, context: "safari|首页", at: 1, mask: mask), .reference)
    }
}
