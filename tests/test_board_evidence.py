"""Exercise persisted time evidence and sample-based clocks without hardware or user files."""
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
import AVFoundation
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
var clock = BoardCaptureClock(now: 100)
check(clock.elapsed(at: 105) == 5, "initial clock")
clock.pause(at: 106)
clock.pause(at: 110)
check(clock.elapsed(at: 120) == 6, "paused interval leaked")
clock.resume(at: 130)
check(clock.elapsed(at: 134) == 10, "resume shifted timeline")
var evidence = BoardEvidence()
let start = BoardMoment(elapsed: 15, audio: 10)
let end = BoardMoment(elapsed: 16, audio: 11)
evidence.visits = [BoardVisit(pageID: "home", app: "Example", title: "主页", start: start, end: end)]
evidence.speech = [
    .init(start: 1, end: 4, text: "先说背景，这是主页。"),
    .init(start: 7, end: 9, text: "这个按钮"),
    .init(start: 12, end: 15, text: "请放大。"),
    .init(start: 20, end: 23, text: "再说下一页。"),
    .init(start: 40, end: 45, text: "远处的内容不应当作附近语句。")]
let mark = BoardMarkEvidence(number: 3, start: start, end: end)
let nearby = evidence.nearby(mark)
check(nearby.contains { $0.text == "这个按钮" }, "speech before mark missing")
check(nearby.contains { $0.text == "请放大。" }, "speech after mark missing")
check(!nearby.contains { $0.start == 40 }, "far away speech linked")
check(evidence.nearby(.init(number: 4)).isEmpty, "review edits invented speech times")
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try evidence.save(directory)
let loaded = BoardEvidence.load(directory)!
check(loaded.visits[0].start.audio == 10 && loaded.speech == evidence.speech, "time metadata roundtrip")
check(BoardEvidence.range(start, end).contains("00:10.0"), "wrong clock used for audio")
check(BoardEvidence.range(.init(elapsed: 1), .init(elapsed: 3)).contains("无完整音频定位"), "missing audio misrepresented")
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
buffer.frameLength = 4800
let writer = try BoardAudioArchive(url: directory.appendingPathComponent("audio.wav"), format: format)
for _ in 0..<10 { try writer.append(buffer) }
writer.close()
check(abs(writer.seconds - 1) < 0.00001, "audio clock drifted from saved samples")
try writer.append(buffer)
check(abs(writer.seconds - 1) < 0.00001, "closed writer advanced audio clock")
print("PASS: page/mark times, phrase context, pause/resume, metadata persistence, audio clock")
'''

@unittest.skipUnless(sys.platform == 'darwin', 'macOS audio archive')
class BoardEvidenceTests(unittest.TestCase):
    def test_timing_round_trip_and_audio_clock(self):
        with tempfile.TemporaryDirectory(prefix='point-taken-evidence-test-') as path:
            directory = Path(path)
            (directory / 'main.swift').write_text(HARNESS, encoding="utf-8")
            # BoardEvidence.swift keeps the inputs the screen feed saw: BoardInput, from BoardScrollProof.swift
            result = subprocess.run(['xcrun', 'swiftc', str(CORE / 'BoardEvidence.swift'), str(CORE / 'BoardScrollProof.swift'),
                                     str(CORE / 'BoardArchive.swift'), str(directory / 'main.swift'),
                                     '-o', str(directory / 'check')], capture_output=True, text=True, encoding="utf-8",
                                    env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'), timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(directory / 'check'), str(directory)], capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS:', result.stdout)
