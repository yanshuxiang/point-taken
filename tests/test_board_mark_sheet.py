"""Review-window marks: numbers, notes and times stay with their own stroke through edits."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / 'app/macos/Sources/PointTakenCore'
HARNESS = r'''
import Foundation
import CoreGraphics
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let timed = BoardMarkEvidence(number: 4, start: .init(elapsed: 1, audio: 1), end: .init(elapsed: 2, audio: 2))
// a recorded page: two strokes, the second from an old record with no evidence
var sheet = BoardMarkSheet(strokes: [[[0.1, 0.1], [0.3, 0.1]], [[0.5, 0.5]]], evidence: [timed], firstFree: 9)
check(sheet.evidence.map(\.number) == [4, 9], "old strokes not numbered from the first free number")
check(sheet.evidence[1].start == nil && !sheet.evidence[1].isAdded, "old stroke given an invented time or flag")
sheet.add([[0.7, 0.7], [0.9, 0.9]], number: 10)
check(sheet.evidence.last == BoardMarkEvidence(number: 10, added: true), "added mark not flagged")
// deleting one in the middle keeps every other mark's number, time and points
check(sheet.remove(number: 9), "delete failed")
check(sheet.evidence.map(\.number) == [4, 10] && sheet.evidence[0] == timed, "delete shifted another mark")
check(sheet.strokes == [[[0.1, 0.1], [0.3, 0.1]], [[0.7, 0.7], [0.9, 0.9]]], "delete kept the wrong strokes")
check(!sheet.remove(number: 9), "deleted twice")
// notes
check(sheet.setNote("  改成圆角  ", number: 10) && sheet.evidence[1].note == "改成圆角", "note not trimmed/saved")
check(!sheet.setNote("改成圆角", number: 10), "unchanged note reported as a change")
check(sheet.setNote("   ", number: 10) && sheet.evidence[1].note == nil, "blank note not cleared")
// hit testing in a 1000×500 picture
let size = CGSize(width: 1000, height: 500)
check(sheet.hit(CGPoint(x: 200, y: 52), size: size, tolerance: 6, ring: 18, badge: 22) == 4, "line not hit")
check(sheet.hit(CGPoint(x: 600, y: 300), size: size, tolerance: 6, ring: 18, badge: 22) == nil, "empty space hit")
let badge = BoardMarkSheet.badgeCenter([[0.7, 0.7]], size: size, diameter: 22)!
check(abs(badge.x - 689) < 0.01 && abs(badge.y - 339) < 0.01, "badge not up-left of the start: \(badge)")
check(sheet.hit(badge, size: size, tolerance: 6, ring: 18, badge: 22) == 10, "badge not hit")
let corner = BoardMarkSheet.badgeCenter([[0, 0]], size: size, diameter: 22)!
check(corner == CGPoint(x: 11, y: 11), "badge left the picture")
let ring = BoardMarkSheet(strokes: [[[0.5, 0.5]]], evidence: [], firstFree: 1)
check(ring.hit(CGPoint(x: 515, y: 250), size: size, tolerance: 6, ring: 18, badge: 0) == 1, "tap ring not hit")
// inclusion: first mark checks, last mark removed unchecks, otherwise the user's choice stays
check(BoardPageInclusion.after(change: 0, to: 1, included: false), "first mark did not check the page")
check(!BoardPageInclusion.after(change: 1, to: 0, included: true), "removing the last mark kept the page checked")
check(!BoardPageInclusion.after(change: 2, to: 3, included: false), "user's unchecked choice overridden")
check(BoardPageInclusion.after(change: 0, to: 0, included: true), "manual page unchecked without a change")
// Current association: nearest mark / sentence continuation within a visit, not every neighboring gap.
func m(_ n: Int, _ a: Double, _ b: Double) -> BoardMarkEvidence { .init(number: n, start: .init(elapsed: a, audio: a), end: .init(elapsed: b, audio: b)) }
func at(_ a: Double, _ b: Double) -> BoardMoment { .init(elapsed: a, audio: a) }
var ev = BoardEvidence()
ev.visits = [.init(pageID: "p", app: "", title: "", start: at(0, 0), end: at(30, 30)),
             .init(pageID: "q", app: "", title: "", start: at(30, 30), end: at(40, 40)),
             .init(pageID: "p", app: "", title: "", start: at(40, 40), end: at(60, 60))]
ev.speech = [.init(start: 0.4, end: 7.2, text: "先介绍一下"), .init(start: 6, end: 6.5, text: "嗯"),
             .init(start: 8, end: 11, text: "这里改成圆角"), .init(start: 14, end: 19, text: "这个按钮去掉"),
             .init(start: 22, end: 28, text: "最后补充"), .init(start: 31, end: 33, text: "别的页面"),
             .init(start: 41, end: 44, text: "回来再看这里")]
let said = ev.said(about: [m(1, 3.7, 5.2), m(2, 12, 13), m(3, 20, 21), m(4, 45, 46), .init(number: 5, added: true)], onPage: ["p"])
func texts(_ n: Int) -> [String] { (said[n] ?? []).map(\.text) }
check(texts(1) == ["先介绍一下"], "first mark: \(texts(1))")
// The unpunctuated introduction continues into the next sentence; mark 1 keeps its directly overlapping speech.
check(texts(2) == ["先介绍一下", "这里改成圆角", "这个按钮去掉"], "middle mark should keep its nearest speech and continuation: \(texts(2))")
check(texts(3) == ["最后补充"], "last mark of the visit: \(texts(3))")
check(texts(4) == ["回来再看这里"], "revisit leaked other page or earlier visit: \(texts(4))")
check(said[5] == nil, "a mark drawn in review was given speech")
// the real record of 2026-11-15 12:53: one long sentence over the mark
var real = BoardEvidence()
real.visits = [.init(pageID: "a", app: "", title: "", start: at(0, 0), end: at(0.2, 0.2)),
               .init(pageID: "b", app: "", title: "", start: at(0.2, 0.2), end: at(8.9, 8.9))]
real.speech = [.init(start: 0.37, end: 7.21, text: "Today, I'm going to introduce one thing. Like you can see here, we should replace them.")]
check(real.said(about: [m(1, 3.7, 5.2)], onPage: ["b"])[1]?.count == 1, "the real record's sentence was not counted")
print("PASS: mark numbers, notes, delete, hit testing, inclusion, speech between marks")
'''


@unittest.skipUnless(sys.platform == 'darwin', 'macOS dependencies')
class BoardMarkSheetTests(unittest.TestCase):
    def test_marks_keep_their_numbers_and_notes(self):
        with tempfile.TemporaryDirectory(prefix='point-taken-mark-sheet-test-') as path:
            directory = Path(path)
            (directory / 'main.swift').write_text(HARNESS, encoding="utf-8")
            # BoardScrollProof.swift: BoardInput, which BoardEvidence.swift keeps
            command = ['xcrun', 'swiftc'] + [str(CORE / name) for name in
                       ['BoardEvidence.swift', 'BoardScrollProof.swift', 'BoardMarkSheet.swift']]
            command += [str(directory / 'main.swift'), '-o', str(directory / 'check')]
            result = subprocess.run(command, env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'),
                                    capture_output=True, text=True, encoding="utf-8", timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(directory / 'check')], capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS:', result.stdout)


if __name__ == '__main__':
    unittest.main()
