"""Menu must separate configured choice from actual completed requests."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'app/macos/Sources/PointTakenApp/Capture/BoardModelStatus.swift'
SWIFTC = shutil.which('swiftc')
@unittest.skipUnless(SWIFTC, 'needs the Swift compiler (swiftc)')
class StatusTest(unittest.TestCase):
 def test_menu_distinguishes_success_skipped_and_pending(self):
  self.assertTrue(SOURCE.exists(), 'Menu has no model status or request evidence')
  checks = r'''
let model = "volcengine-seedasr"
let finished: [String: Any] = ["model": model, "state": "complete"]
let receipt: [String: Any] = ["state": "success", "model": model, "actualModel": model, "provider": "volcengine", "requestID": "fixture-request"]
precondition(BoardModelStatus.result(state: finished, receipt: receipt).contains("豆包"))
precondition(BoardModelStatus.result(state: finished, receipt: receipt).contains("已完成"))
let skipped: [String: Any] = ["model": model, "state": "incomplete", "warning": "原始音频和实时转写已保存；可从历史重新转写完整录音。"]
precondition(BoardModelStatus.result(state: skipped, receipt: nil).contains("退出"))
precondition(!BoardModelStatus.result(state: skipped, receipt: nil).contains("已完成"))
precondition(BoardModelStatus.result(state: ["model":model,"state":"recording"], receipt:nil).contains("尚未调用"))
precondition(BoardModelStatus.result(state: ["model":model,"state":"finalizing"], receipt:nil).contains("正在"))
precondition(BoardModelStatus.result(state: [:], receipt:nil).contains("未记录"))
precondition(BoardModelStatus.result(state: finished, receipt: ["state":"failed","model":model]).contains("未完成"))
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let audio = directory.appendingPathComponent("sample.wav")
BoardModelStatus.writeReceipt(audio:audio, state:"success", model:model,
  response:["model":model,"provider":"volcengine","service_model":"seed-asr-2.0", "request_id":"fixture-request","text":"private","key":"secret"])
let saved = BoardModelStatus.read(directory.appendingPathComponent("转写调用.json"))!
precondition(saved["text"] == nil && saved["key"] == nil)
precondition(saved["requestID"] as? String == "fixture-request")
'''
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)
   boundary = """
   enum PointTaken { static let nameZh = "懂你意思" }
   enum CloudSpeechCheck { static func sentence(_ code: String?) -> String { code ?? "unknown" } }
   enum Loc { static func string(_ key: String, table: String) -> String { key } }
   """
   (p/'main.swift').write_text(SOURCE.read_text(encoding="utf-8").replace('import PointTakenCore', '')+boundary+checks, encoding="utf-8")
   r=subprocess.run([SWIFTC,str(p/'main.swift'),'-o',str(p/'check')],capture_output=True,text=True, encoding="utf-8")
   self.assertEqual(r.returncode,0,r.stderr)
   r=subprocess.run([str(p/'check')],capture_output=True,text=True, encoding="utf-8")
   self.assertEqual(r.returncode,0,r.stderr)
if __name__=='__main__':unittest.main()
