"""Synthetic screen sequences exercise the shipped boundary detector and stitcher, no desktop capture."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'app/macos/Sources'
HARNESS = r'''
import Foundation
import CoreGraphics
func check(_ ok: Bool, _ why: String) { if !ok { fatalError(why) } }
func flat(_ value: CGFloat) -> CGImage {
    let c = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: value, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    return c.makeImage()!
}
let a = BoardFrameFingerprint(flat(0.2)), b = BoardFrameFingerprint(flat(0.8))
var gate = BoardPageGate()
check(gate.observe(a, context: "a", at: 0) == .reference, "first frame")
check(gate.observe(b, context: "a", at: 1) == .reference, "animation without input made a page")
gate.interaction(at: 2, scroll: true)
check(gate.observe(b, context: "a", at: 2.1) == .reference, "scroll at page edge without pixel movement made a page")
gate.interaction(at: 3, scroll: true)
check(gate.observe(a, context: "a", at: 3.1) == .leave, "scroll did not retain previous page")
gate.interaction(at: 3.2, scroll: true)
check(gate.observe(b, context: "a", at: 3.3) == .settling, "one scroll burst generated multiple pages")
check(gate.observe(b, context: "a", at: 3.8) == .settling, "settling too short")
check(gate.observe(b, context: "a", at: 4.2) == .reference, "stable screen not rearmed")
gate.interaction(at: 5, scroll: false)
check(gate.observe(a, context: "a", at: 5.1) == .leave, "navigation not detected")
check(gate.observe(a, context: "b", at: 5.4) == .leave, "window switch not detected")
// Deterministic detailed document: two crops have exactly 200 px vertical overlap.
let w = 320, h = 600
let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for y in 0..<h {
    for x in stride(from: 0, to: w, by: 8) {
        let v = CGFloat((y * 73 + x * 37 + y * x * 13) % 251) / 251
        c.setFillColor(CGColor(gray: v, alpha: 1)); c.fill(CGRect(x: x, y: y, width: 8, height: 1))
    }
}
let document = c.makeImage()!
let top = document.cropping(to: CGRect(x: 0, y: 0, width: w, height: 400))!
let bottom = document.cropping(to: CGRect(x: 0, y: 200, width: w, height: 400))!
let alignment = BoardScrollStitcher.alignment(previous: top, next: bottom)
check(alignment != nil && abs(alignment!.scrollDelta - 200) <= 1, "known scroll overlap incorrect: \(String(describing: alignment))")
check(alignment!.confidence >= 0.97, "exact overlap confidence too low")
let result = try BoardScrollStitcher.stitch([top, bottom])
check(result.width == w && result.height == h, "wrong stitched dimensions")
let expectedPixels = BoardGrayFrame(document, targetWidth: w, targetHeight: h).bytes
let actualPixels = BoardGrayFrame(result, targetWidth: w, targetHeight: h).bytes
check(zip(expectedPixels, actualPixels).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "stitched rows duplicated, missing, flipped or reordered")
check(BoardScrollStitcher.alignment(previous: flat(0.1), next: flat(0.9)) == nil, "blank unrelated images stitched")
var rejected = false
do { try BoardScrollStitcher.validateOutputSize(width: 10000, height: 10000) } catch { rejected = true }
check(rejected, "pixel budget not enforced")
print("PASS: page boundaries, input-free animation, scroll bursts, exact overlap, rejection and memory limit")
'''

@unittest.skipUnless(sys.platform == 'darwin', 'CoreGraphics/Vision require macOS')
class BoardPaging(unittest.TestCase):
    def test_boundaries_and_stitching(self):
        with tempfile.TemporaryDirectory(prefix='point-taken-paging-check-') as tmp:
            path = Path(tmp)
            (path / 'main.swift').write_text(HARNESS)
            env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
            result = subprocess.run(['xcrun', 'swiftc', str(BASE / 'PointTakenCore/BoardPaging.swift'),
                                     str(BASE / 'PointTakenApp/Capture/BoardScrollStitcher.swift'),
                                     str(path / 'main.swift'), '-o', str(path / 'check')], env=env,
                                    capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(path / 'check')], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS:', result.stdout)
