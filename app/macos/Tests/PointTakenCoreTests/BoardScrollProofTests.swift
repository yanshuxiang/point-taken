import XCTest
@testable import PointTakenCore

final class BoardScrollProofTests: XCTestCase {
    // MARK: inputs

    func testOnlyDownwardScrollingBetweenCapturesCounts() {
        let down = [BoardInput(kind: .scroll, at: 5, dy: -40), BoardInput(kind: .scroll, at: 6, dy: -12)]
        XCTAssertTrue(BoardScrollInput.onlyScrolledDown(down, from: 4, to: 7))
        // nothing between the captures, or the captures in the wrong order
        XCTAssertFalse(BoardScrollInput.onlyScrolledDown(down, from: 7, to: 9))
        XCTAssertFalse(BoardScrollInput.onlyScrolledDown(down, from: 7, to: 4))
        // upwards overall
        XCTAssertFalse(BoardScrollInput.onlyScrolledDown([BoardInput(kind: .scroll, at: 5, dy: 30)], from: 4, to: 7))
        XCTAssertFalse(BoardScrollInput.onlyScrolledDown(down + [BoardInput(kind: .scroll, at: 6.5, dy: 80)], from: 4, to: 7))
        // a click or a key press could have navigated
        XCTAssertFalse(BoardScrollInput.onlyScrolledDown(down + [BoardInput(kind: .click, at: 5.5)], from: 4, to: 7))
        XCTAssertFalse(BoardScrollInput.onlyScrolledDown(down + [BoardInput(kind: .key, at: 5.5)], from: 4, to: 7))
        // inputs outside the two captures do not matter
        XCTAssertTrue(BoardScrollInput.onlyScrolledDown(down + [BoardInput(kind: .click, at: 3), BoardInput(kind: .key, at: 8)], from: 4, to: 7))
    }

    func testTrackpadBurstsAreCoalesced() {
        var inputs: [BoardInput] = []
        for i in 0..<60 { BoardScrollInput.append(BoardInput(kind: .scroll, at: Double(i) / 60, dy: -2), to: &inputs) }
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].dy ?? 0, -120, accuracy: 0.001)
        BoardScrollInput.append(BoardInput(kind: .click, at: 1.05), to: &inputs)
        BoardScrollInput.append(BoardInput(kind: .scroll, at: 1.1, dy: -3), to: &inputs)
        XCTAssertEqual(inputs.map(\.kind), [.scroll, .click, .scroll])
    }

    // MARK: pixels

    /// A screen: a pinned bar on top and at the bottom, and between them a window onto `document` from `offset`.
    private func screen(_ document: [UInt8], width: Int, height: Int, offset: Int, header: Int = 60, footer: Int = 50,
                        clock: UInt8 = 0) -> BoardGrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                if y < header { value = (x / 40) % 2 == 0 ? 40 : 60 }
                else if y >= height - footer { value = 30 }
                else { value = document[(y - header + offset) * width + x] }
                pixels[y * width + x] = value
            }
        }
        // a ticking clock in the menu bar must not stop the bar counting as pinned
        for y in 4..<20 { for x in (width - 30)..<(width - 4) { pixels[y * width + x] = clock } }
        return BoardGrayImage(width: width, height: height, pixels: pixels)
    }

    /// Text-like lines of different lengths on white.
    private func article(width: Int, height: Int) -> [UInt8] {
        var doc = [UInt8](repeating: 250, count: width * height)
        var seed: UInt64 = 42
        var y = 10
        while y < height - 30 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = width / 4 + Int(seed >> 33) % (width / 2)
            let thickness = 10 + Int(seed >> 50) % 12
            for line in y..<min(height, y + thickness) {
                var x = 20
                while x < 20 + length {
                    seed = seed &* 6364136223846793005 &+ 1
                    let word = 12 + Int(seed >> 59)
                    for c in x..<min(width, x + word) { doc[line * width + c] = UInt8(30 + Int(seed >> 56) % 60) }
                    x += word + 8
                }
            }
            y += thickness + 14 + Int(seed >> 45) % 30
        }
        return doc
    }

    func testExactScrollDistanceIsProven() throws {
        let width = 480, height = 600
        let doc = article(width: width, height: 3000)
        let a = screen(doc, width: width, height: height, offset: 0, clock: 10)
        for delta in [12, 137, 300] {
            let b = screen(doc, width: width, height: height, offset: delta, clock: 200)
            let proof = try XCTUnwrap(BoardScrollProver.prove(previous: a, next: b), "delta \(delta)")
            XCTAssertEqual(proof.delta, delta)
            XCTAssertGreaterThanOrEqual(proof.header, 60)
            XCTAssertGreaterThanOrEqual(proof.footer, 50)
        }
    }

    func testAnythingButAClearDownwardScrollIsRefused() {
        let width = 480, height = 600
        let doc = article(width: width, height: 3000)
        let a = screen(doc, width: width, height: height, offset: 200)
        // the same picture, scrolled up, scrolled past any overlap, another document
        XCTAssertNil(BoardScrollProver.prove(previous: a, next: a))
        XCTAssertNil(BoardScrollProver.prove(previous: a, next: screen(doc, width: width, height: height, offset: 80)))
        XCTAssertNil(BoardScrollProver.prove(previous: a, next: screen(doc, width: width, height: height, offset: 200 + 470)))
        let other = article(width: width, height: 3000).reversed()
        XCTAssertNil(BoardScrollProver.prove(previous: a, next: screen(Array(other), width: width, height: height, offset: 0)))
        // a blank page: every distance "matches"
        let blank = [UInt8](repeating: 250, count: width * 3000)
        XCTAssertNil(BoardScrollProver.prove(previous: screen(blank, width: width, height: height, offset: 0),
                                             next: screen(blank, width: width, height: height, offset: 100)))
    }

    func testRepeatingRowsAreAmbiguousAndRefused() {
        let width = 480, height = 600
        var list = [UInt8](repeating: 250, count: width * 3000)
        for y in 0..<3000 where y % 60 < 3 || (y % 60 > 20 && y % 60 < 34) {
            for x in 20..<300 { list[y * width + x] = 40 }
        }
        let a = screen(list, width: width, height: height, offset: 0)
        let b = screen(list, width: width, height: height, offset: 180)
        XCTAssertNil(BoardScrollProver.prove(previous: a, next: b))
    }

    func testChangedContentInsideTheOverlapIsRefused() {
        let width = 480, height = 600
        let doc = article(width: width, height: 3000)
        let a = screen(doc, width: width, height: height, offset: 0)
        let b = screen(doc, width: width, height: height, offset: 120)
        var edited = b.pixels
        for y in 200..<260 { for x in 40..<400 { edited[y * width + x] = 0 } }   // a popup over the content
        XCTAssertNil(BoardScrollProver.prove(previous: a, next: BoardGrayImage(width: width, height: height, pixels: edited)))
    }
}
