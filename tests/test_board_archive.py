"""Exercise the actual transcript/export/audio helpers without a microphone or clipboard access."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'app/macos/Sources/PointTakenCore/BoardArchive.swift'

HARNESS = r'''
import Foundation
import AVFoundation

func check(_ ok: Bool, _ message: String) {
    if !ok { fatalError(message) }
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// Captured macOS on-device sequence: metadata settles a sentence while isFinal stays false.
// After the pause, partial text restarts at the next sentence; all timestamps initially read zero.
var paused = BoardTranscript()
paused.update("首先这里太丑了，我觉得这里应该是给他删掉", final: false)
paused.update("首先这里太丑了，我觉得这里应该是给他删掉", final: false, utteranceComplete: true)
_ = paused.markPage()
paused.update("这", final: false)
paused.update("这个按钮也删掉这里放大一点", final: false)
paused.update("这个按钮也删掉，这里放大一点", final: false, utteranceComplete: true)
paused.update("这个按钮也删掉，这里放大一点", final: true, utteranceComplete: true)
check(paused.text == "首先这里太丑了，我觉得这里应该是给他删掉 这个按钮也删掉，这里放大一点", "A pause discarded earlier speech")
check(paused.pageText.trimmingCharacters(in: .whitespaces) == "这个按钮也删掉，这里放大一点", "Next-page excerpt was lost after the recognizer reset")
var cumulative = BoardTranscript()
cumulative.update("背景。", final: false, utteranceComplete: true)
cumulative.update("背景。补充", final: false)
cumulative.update("", final: false)
check(cumulative.text == "背景。补充", "Empty partial deleted pending speech")
cumulative.update("背景。补充。", final: true)
check(cumulative.text == "背景。补充。", "Cumulative recognition duplicated a settled prefix")
cumulative.replaceWithFileTranscript("背景。补充。结束的话。")
check(cumulative.text == "背景。补充。结束的话。", "File transcription did not include the audio tail")
try cumulative.text.write(to: directory.appendingPathComponent("完整转写.txt"), atomically: true, encoding: .utf8)
try "".write(to: directory.appendingPathComponent("交付转写.txt"), atomically: true, encoding: .utf8)
check(BoardDeliveryTranscript.load(from: directory) == cumulative.text, "Legacy empty delivery hid the full transcript")
try BoardDeliveryTranscript.saveEdit("用户修改后的全文", to: directory)
check(BoardDeliveryTranscript.load(from: directory) == "用户修改后的全文", "Explicit user edits were lost")
try BoardDeliveryTranscript.saveEdit("", to: directory)
check(BoardDeliveryTranscript.load(from: directory) == "", "Intentional deletion was incorrectly restored")
check(try String(contentsOf: directory.appendingPathComponent("完整转写.txt"), encoding: .utf8) == cumulative.text, "Editing destroyed the original transcription")
var transcript = BoardTranscript()
transcript.update("先说一下背景", final: false)
transcript.update("先说一下背景：这是给老人用的。", final: false)
_ = transcript.markPage()
transcript.update("先说一下背景：这是给老人用的。按钮要大一点。", final: true)
_ = transcript.markPage()
transcript.update("最后补充：别改变原来的颜色。", final: false)
transcript.commit()
let expected = "先说一下背景：这是给老人用的。按钮要大一点。 最后补充：别改变原来的颜色。"
check(transcript.text == expected, "Page boundaries or finalization lost/repeated speech")
let emptyImages: [URL] = [] // all screenshot pages removed; the background must remain
check(BoardExport.text(transcript: transcript.text, images: emptyImages, terminal: false).contains(expected),
      "Speech-only export lost background or trailing words")
let images = [directory.appendingPathComponent("图1.png"), directory.appendingPathComponent("图2.png")]
for terminal in [false, true] {
    let output = BoardExport.text(transcript: transcript.text, images: images, terminal: terminal)
    check(output.components(separatedBy: expected).count == 2, "Full transcript must appear exactly once")
    check(output.contains("图1") && output.contains("图2"), "Image order missing")
    check(!terminal || output.contains(images[1].path), "Terminal image path missing")
}
// Raw samples must survive multiple page saves and recognition failure (neither affects this writer).
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
buffer.frameLength = 4800
for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.03)) * 0.25 }
let url = directory.appendingPathComponent("原始录音.wav")
let archive = try BoardAudioArchive(url: url, format: format)
for _ in 0..<4 { try archive.append(buffer) }
archive.close()
archive.close()
let saved = try AVAudioFile(forReading: url)
check(saved.length == 19200, "Not all microphone buffers were saved")
check(saved.fileFormat.sampleRate == 48000, "Original sample rate was changed")
let decoded = AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 4096)!
var total = 0
while total < 19200 {
    try saved.read(into: decoded)
    check(decoded.frameLength > 0, "Audio ended before the last buffer")
    for i in 0..<Int(decoded.frameLength) {
        check(abs(decoded.floatChannelData![0][i] - buffer.floatChannelData![0][(total + i) % 4800]) < 0.000001,
              "Original audio samples changed")
    }
    total += Int(decoded.frameLength)
}
check(total == 19200, "Audio was truncated")
// A bad destination must fail visibly instead of pretending to record.
var rejected = false
do { _ = try BoardAudioArchive(url: directory.appendingPathComponent("missing/audio.wav"), format: format) }
catch { rejected = true }
check(rejected, "Unwritable audio destination was silently accepted")
print("PASS: transcript revisions, page boundaries, full export, original audio round-trip, write errors")
'''

@unittest.skipUnless(sys.platform == 'darwin', 'AVFoundation requires macOS')
class BoardArchive(unittest.TestCase):
    def test_retention_and_delivery(self):
        with tempfile.TemporaryDirectory(prefix='point-taken-archive-check-') as temporary:
            directory = Path(temporary)
            main = directory / 'main.swift'
            main.write_text(HARNESS, encoding="utf-8")
            binary = directory / 'check'
            env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
            built = subprocess.run(['xcrun', 'swiftc', str(SOURCE), str(main), '-o', str(binary)],
                                   env=env, capture_output=True, text=True, encoding="utf-8", timeout=90)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary), str(directory)], capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS:', result.stdout)
