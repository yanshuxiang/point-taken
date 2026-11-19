"""Exercise the exact runtime identity predicate used by permission reads and paste."""
from pathlib import Path
import os, re, subprocess, sys, tempfile, unittest
ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'app/macos/Sources/PointTakenApp/Capture/BoardPaste.swift'

@unittest.skipUnless(sys.platform == 'darwin', 'Swift compiler required')
class RuntimeIdentityTests(unittest.TestCase):
    def test_board_reads_real_permissions_but_test_bundles_stay_simulated(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index('    static var testMode: Bool {')
        end = source.index('    /// clipboard managers skip', start)
        predicate = source[start:end]
        harness = '''
import Foundation
struct Bundle { static var main = Bundle(); var bundleIdentifier: String? }
struct ProcessInfo { static var processInfo = ProcessInfo(); var environment: [String: String] = [:] }
enum PointTaken { static let bundleID = "io.github.yanshuxiang.pointtaken" }
enum Identity {
''' + predicate + '''
}
func check(_ ok: Bool, _ label: String) { if !ok { print("FAIL: " + label); exit(1) } }
for id in ["io.github.yanshuxiang.pointtaken"] {
    Bundle.main.bundleIdentifier = id
    check(!Identity.testMode, "production app gets fake permissions: " + id)
}
for id in [nil, "pointtaken.recorder", "pointtaken.recorder.test", "io.github.yanshuxiang.pointtaken.test", "pointtaken.recorder.board", "other"] as [String?] {
    Bundle.main.bundleIdentifier = id
    check(Identity.testMode, "unknown/test app may send real keys")
}
Bundle.main.bundleIdentifier = "io.github.yanshuxiang.pointtaken"
ProcessInfo.processInfo.environment = ["POINT_TAKEN_TEST_COMMANDS": "1"]
check(Identity.testMode, "explicit diagnostic mode ignored")
print("PASS")
'''
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory/'main.swift').write_text(harness, encoding="utf-8")
            result = subprocess.run(['xcrun','swiftc',str(directory/'main.swift'),'-o',str(directory/'check')],
                env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'),capture_output=True,text=True, encoding="utf-8")
            self.assertEqual(result.returncode,0,result.stderr)
            result = subprocess.run([str(directory/'check')],capture_output=True,text=True, encoding="utf-8")
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
