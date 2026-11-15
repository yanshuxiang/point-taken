// PointTakenCore/BoardEvidence.said: which sentences go with which mark — one sentence to one mark, by time.
import XCTest
@testable import PointTakenCore

final class BoardSaidTests: XCTestCase {
    private func mark(_ n: Int, _ a: Double, _ b: Double) -> BoardMarkEvidence {
        BoardMarkEvidence(number: n, start: BoardMoment(elapsed: a, audio: a), end: BoardMoment(elapsed: b, audio: b))
    }
    private func visit(_ id: String, _ a: Double, _ b: Double) -> BoardVisit {
        BoardVisit(pageID: id, app: "", title: "", start: BoardMoment(elapsed: a, audio: a), end: BoardMoment(elapsed: b, audio: b))
    }
    private func texts(_ said: [Int: [BoardSpeechSegment]], _ n: Int) -> [String] { (said[n] ?? []).map(\.text) }

    /// The 2026-11-15 17:49 recording: marks 2, 3, 4 each got two or three of the same sentences.
    private var dogfood: BoardEvidence {
        var e = BoardEvidence()
        e.visits = [visit("p2", 0, 0.1), visit("p1", 1.3, 11.3), visit("p2", 11.3, 36.7)]
        e.speech = [
            BoardSpeechSegment(start: 5.27, end: 7.97, text: "这个地方换成圆角矩形吧。"),
            BoardSpeechSegment(start: 8.30, end: 10.86, text: "不对，是换成圆形。"),
            BoardSpeechSegment(start: 14.75, end: 17.04, text: "这个直接删掉就行了。"),
            BoardSpeechSegment(start: 17.80, end: 22.94, text: "然后这些地方直接就是去除吧。"),
            BoardSpeechSegment(start: 31.96, end: 36.90, text: "右边那个符号不要哦。"),
        ]
        return e
    }

    func testOneSentencePerMark() {
        let said = dogfood.said(about: [mark(2, 14.6, 15.7), mark(3, 18.2, 20.6), mark(4, 33.3, 35.1)], onPage: ["p2"])
        XCTAssertEqual(texts(said, 2), ["这个直接删掉就行了。"])
        XCTAssertEqual(texts(said, 3), ["然后这些地方直接就是去除吧。"])
        XCTAssertEqual(texts(said, 4), ["右边那个符号不要哦。"])
    }

    func testCorrectionRightAfterStaysWithTheMark() {
        let said = dogfood.said(about: [mark(1, 4.3, 6.0)], onPage: ["p1"])
        XCTAssertEqual(texts(said, 1), ["这个地方换成圆角矩形吧。", "不对，是换成圆形。"])
    }

    func testShortPausesKeepGoingButALongOneStops() {
        var e = BoardEvidence()
        e.visits = [visit("p", 0, 60)]
        e.speech = [
            BoardSpeechSegment(start: 1.5, end: 4, text: "这个按钮太大了"),
            BoardSpeechSegment(start: 4.5, end: 8, text: "还有颜色也不对"),        // 0.5 s pause, 3.5 s past the mark
            BoardSpeechSegment(start: 9, end: 12, text: "而且字也小"),             // 1 s pause: still going on
            BoardSpeechSegment(start: 25, end: 28, text: "好了先这样"),            // 13 s later: about nothing
        ]
        let said = e.said(about: [mark(1, 1, 2)], onPage: ["p"])
        XCTAssertEqual(texts(said, 1), ["这个按钮太大了", "还有颜色也不对", "而且字也小"])
    }

    func testSaidJustBeforeDrawingGoesToThatMark() {
        var e = BoardEvidence()
        e.visits = [visit("p", 0, 60)]
        e.speech = [BoardSpeechSegment(start: 3, end: 5, text: "这里删掉"), BoardSpeechSegment(start: 12, end: 14, text: "那里改大")]
        let said = e.said(about: [mark(1, 1, 2), mark(2, 15, 16)], onPage: ["p"])
        XCTAssertEqual(texts(said, 1), ["这里删掉"])
        XCTAssertEqual(texts(said, 2), ["那里改大"])
    }

    func testOneSentenceOverTwoQuickMarksIsShared() {
        var e = BoardEvidence()
        e.visits = [visit("p", 0, 60)]
        e.speech = [BoardSpeechSegment(start: 1, end: 6, text: "这个和这个都删掉")]
        let said = e.said(about: [mark(1, 1.5, 2.5), mark(2, 3, 5)], onPage: ["p"])
        XCTAssertEqual(texts(said, 2), ["这个和这个都删掉"])
        XCTAssertEqual(texts(said, 1), ["这个和这个都删掉"])
    }

    /// The 2026-11-15 18:06 recording, page 4: recognition cut "然后这些 | 这些按钮吧…" in two, right after mark 2.
    func testHalfSentenceGoesWithTheRestOfIt() {
        var e = BoardEvidence()
        e.visits = [visit("p", 16.8, 20.9), visit("q", 20.9, 22.9), visit("p", 22.9, 26.7)]
        e.speech = [
            BoardSpeechSegment(start: 17.57, end: 20.76, text: "这个地方往左移一点。"),
            BoardSpeechSegment(start: 20.77, end: 23.53, text: "然后这些"),
            BoardSpeechSegment(start: 23.86, end: 29.22, text: "这些按钮吧，让它以另外一种方式来显现。"),
        ]
        let said = e.said(about: [mark(2, 18.7, 20.6), mark(3, 24.4, 26.5)], onPage: ["p"])
        XCTAssertEqual(texts(said, 2), ["这个地方往左移一点。"])
        XCTAssertEqual(texts(said, 3), ["然后这些", "这些按钮吧，让它以另外一种方式来显现。"])
    }

    func testOtherPagesSpeechDoesNotCount() {
        let said = dogfood.said(about: [mark(2, 14.6, 15.7)], onPage: ["p2"])
        XCTAssertFalse(texts(said, 2).contains("不对，是换成圆形。"))
    }
}
