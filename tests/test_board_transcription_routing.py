"""Exercise the production annotation routing with a fake script boundary; no credentials or network."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFTC = shutil.which('swiftc')

@unittest.skipUnless(SWIFTC, 'needs the Swift compiler (swiftc)')
class RoutingTest(unittest.TestCase):
    def test_actual_model_selection_routes_and_rejects_wrong_model(self):
        source = (ROOT / 'app/macos/Sources/PointTakenApp/Capture/Board.swift').read_text(encoding="utf-8")
        production = (ROOT / 'app/macos/Sources/PointTakenApp/Capture/BoardModelStatus.swift').read_text(encoding="utf-8").replace('import PointTakenCore', '') + source[source.index('enum BoardTranscription {'):source.index('final class BoardSpeech {')]
        harness = r'''
import Foundation
var config: [String: Any] = [:]
func recordConfig() -> [String: Any] { config }
func setRecordConfig(_ key: String, _ value: [String: Any]) { config[key] = value }
struct BoardSpeechSegment { let start: Double; let end: Double; let text: String }
enum BoardLongImage { struct Failure: Error { let message: String } }
enum CloudSpeechCheck { static func sentence(_ code: String?) -> String { code ?? "error" } }
enum PointTaken { static let nameZh = "懂你意思" }
enum Loc { static func string(_ key: String, table: String) -> String { key } }
enum BoardSpeech {
    struct FileTranscript { var text: String; var segments: [BoardSpeechSegment] = [] }
    static func appleFile(_ url: URL, _ locale: String, _ done: (Result<FileTranscript, Error>) -> Void) {
        done(.success(FileTranscript(text: "local")))
    }
}
enum Scripts {
    struct Failure: Error { let code: String }
    static var calls: [[String]] = []
    static var response: Result<[String: Any], Failure> = .success([:])
    static func call(_ script: String, _ args: [String], timeout: Double,
                     done: (Result<[String: Any], Failure>) -> Void) {
        precondition(script == "transcribe.py")
        calls.append(args); done(response)
    }
}
'''
        checks = r'''
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let audio = temp.appendingPathComponent("synthetic.wav")
precondition(BoardTranscription.selected == BoardTranscription.apple)
BoardTranscription.transcribe(audio, locale: "zh-CN", model: BoardTranscription.selected) {
    precondition(try! $0.get().text == "local")
}
precondition(Scripts.calls.isEmpty)
config["board"] = ["locale": "zh-CN"]
BoardTranscription.select("volcengine-seedasr")
precondition((config["board"] as? [String: Any])?["locale"] as? String == "zh-CN")
let chosen = BoardTranscription.selected
BoardTranscription.select(BoardTranscription.apple)
Scripts.response = .success(["model": chosen, "text": "背景和最后的补充", "segments": [
    ["start": 0.9, "end": 8.8, "text": "背景"], ["start": 51.2, "end": 55.3, "text": "最后的补充"]]])
BoardTranscription.transcribe(audio, locale: "zh-CN", model: chosen) {
    let file = try! $0.get()
    precondition(file.text == "背景和最后的补充" && file.segments.count == 2)
    precondition(file.segments.last!.start == 51.2)
}
precondition(Scripts.calls.last! == ["note", audio.path, "--model-id", chosen, "--segments", "--no-download"])
Scripts.response = .success(["model": "wrong", "text": "bad", "segments": []])
BoardTranscription.transcribe(audio, locale: "zh-CN", model: chosen) {
    if case .success = $0 { fatalError("wrong provider accepted") }
}
Scripts.response = .success(["model": chosen, "text": "shortened by loop removal", "segments": [], "looped": true])
BoardTranscription.transcribe(audio, locale: "zh-CN", model: chosen) {
    if case .success = $0 { fatalError("incomplete looped transcript accepted") }
}
Scripts.response = .failure(Scripts.Failure(code: "auth"))
BoardTranscription.transcribe(audio, locale: "zh-CN", model: chosen) {
    if case .success = $0 { fatalError("failure hidden") }
}
print("routing passed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / 'main.swift').write_text(harness + production + checks, encoding="utf-8")
            result = subprocess.run([SWIFTC, str(path / 'main.swift'), '-o', str(path / 'check')], capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(path / 'check')], capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == '__main__':
    unittest.main()
