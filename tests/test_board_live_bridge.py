"""Replay the actual Swift caption-event receiver, without starting ASR or using a microphone."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which('swiftc')     # macOS: Xcode's (/usr/bin/swiftc); the Linux runners have a Swift toolchain too


@unittest.skipUnless(SWIFTC, 'needs the Swift compiler (swiftc)')
class LiveBridgeTest(unittest.TestCase):
    def test_file_result_stays_separate_from_live_text_and_rejects_incomplete_results(self):
        source = (ROOT / 'app/macos/Sources/PointTakenApp/Capture/BoardLiveSpeech.swift').read_text(encoding="utf-8")
        methods = source[source.index('    private func receive('):source.index('\n}\n\n/// Buffer format')]
        harness = r'''
import Foundation
struct BoardSpeechSegment { var start: Double; var end: Double; var text: String }
enum BoardSpeech { struct FileTranscript { var text: String; var segments: [BoardSpeechSegment] } }
enum BoardModelStatus {
    static func writeReceipt(audio: URL, state: String, model: String, response: [String: Any] = [:], filename: String = "") {}
    static func failureText(_ code: String) -> String { code }
}
final class Fixture {
    let model = "selected-local"
    let audioURL = URL(fileURLWithPath: "/unused/audio.wav")
    var terminal = false, cancelled = false, failed = false, receivedText = false
    var completedCleanly = false, fileFinalizationAttempted = false
    var finalFileTranscript: BoardSpeech.FileTranscript?
    var lastMetadata: [String: Any] = [:]
    var segments: [BoardSpeechSegment] = []
    var onText: ((String, Bool) -> Void)?, onFailure: ((String) -> Void)?
    var onFinalizing: (() -> Void)?, onReady: (() -> Void)?, completion: (() -> Void)?
    func accept(_ event: [String: Any]) { receive(event) }
'''
        checks = r'''
}
let live = Fixture()
var words: [String] = [], finalizing = false, completed = false
live.onText = { text, _ in words.append(text) }
live.onFinalizing = { finalizing = true }
live.completion = { completed = true }
live.accept(["event": "partial", "model": live.model, "text": "实时字幕"])
live.accept(["event": "finalizing", "model": live.model, "ok": true])
precondition(finalizing && live.fileFinalizationAttempted)
live.accept(["event": "file_transcript", "model": live.model, "ok": true,
             "provider": "fixture", "text": "完整录音里的所有句子",
             "segments": [["start": 0.1, "end": 5.0, "text": "完整录音里的所有句子"]]])
precondition(live.finalFileTranscript?.text == "完整录音里的所有句子")
precondition(live.finalFileTranscript?.segments.count == 1)
precondition(words == ["实时字幕"], "Full text must replace the live draft, not append to it")
live.accept(["event": "done", "model": live.model, "ok": true])
precondition(completed && live.completedCleanly)
for bad in [
    ["ok": false, "code": "error"],
    ["ok": true, "text": "shortened", "segments": [], "looped": true],
    ["ok": true, "text": "bad timestamps", "segments": [["start": -1.0, "end": 2.0, "text": "bad"]]]
] as [[String: Any]] {
    let failed = Fixture()
    var event = bad; event["model"] = failed.model; event["event"] = "file_transcript"
    failed.accept(event)
    precondition(failed.fileFinalizationAttempted && failed.failed && failed.finalFileTranscript == nil)
    failed.accept(["event": "done", "model": failed.model, "ok": true])
    precondition(!failed.completedCleanly)
}
print("PASS: live/file transcript handoff, timestamps, failure and loop rejection")
'''
        with tempfile.TemporaryDirectory(prefix='point-taken-live-bridge-') as temporary:
            directory = Path(temporary)
            swift = directory / 'main.swift'
            swift.write_text(harness + methods + checks, encoding="utf-8")
            binary = directory / 'check'
            compiled = subprocess.run([SWIFTC, str(swift), '-o', str(binary)], capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
