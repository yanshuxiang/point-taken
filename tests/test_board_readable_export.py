"""Keep complete/user-edited speech intact while formatting compact handoffs."""
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
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
var evidence = BoardEvidence()
evidence.speech = [.init(start: 0, end: 5, text: "先说明背景。"),
                   .init(start: 6, end: 12, text: "这个按钮放大。"),
                   .init(start: 13, end: 15, text: "嗯"),
                   .init(start: 30, end: 34, text: "结束前补充：不要改变颜色。")]
let transcript = evidence.speech.map(\.text).joined()
let a = BoardMoment(elapsed: 7, audio: 7), b = BoardMoment(elapsed: 8, audio: 8)
evidence.visits = [.init(pageID: "home", app: "Example", title: "Home | Settings", start: a, end: b),
                   .init(pageID: "background", app: "Other", title: "背景页", start: .init(elapsed: 20, audio: 20), end: .init(elapsed: 25, audio: 25)),
                   .init(pageID: "home", app: "Example", title: "Home | Settings", start: .init(elapsed: 30, audio: 30), end: .init(elapsed: 34, audio: 34))]
let page = BoardReadablePage(images: [URL(fileURLWithPath: "/tmp/image 1.png")], contextIDs: ["home"],
                             marks: [.init(number: 1, start: a, end: b), .init(number: 2)])
let output = BoardReadableExport.text(pages: [page], transcript: transcript, evidence: evidence)
let full = output.components(separatedBy: "## 完整转写\n\n")[1].components(separatedBy: "\n\n## 按图查看")[0]
for segment in evidence.speech {
    check(full.components(separatedBy: segment.text).count == 2, "full transcript lost or duplicated a segment")
}
check(output.contains("00:30.0–00:34.0"), "return-visit interval lost")
check(output.contains("背景页"), "unmarked visit context lost")
check(output.contains("| 标记 1 | 00:07.0–00:08.0 | “这个按钮放大。” |"), "mark no longer points to its speech")
check(output.contains("| 标记 2 | 未记录 | — |"), "review edit invented a recording time")
check(output.components(separatedBy: "先说明背景。").count == 2, "unrelated background repeated for each mark")
let edited = "用户修改后的背景。这个按钮放大。结束前补充：不要改变颜色。"
let modified = BoardReadableExport.text(pages: [page], transcript: edited, evidence: evidence)
check(modified.contains(edited), "formatted original replaced the user's edited text")
let deleted = BoardReadableExport.text(pages: [], transcript: transcript, evidence: evidence)
check(deleted.contains("结束前补充：不要改变颜色。") && !deleted.contains("| 标记 1 |"), "deleting screenshots deleted speech")
let terminal = BoardReadableExport.text(pages: [page], transcript: edited, evidence: evidence, terminal: true)
check(terminal.contains("图1：/tmp/image 1.png"), "terminal image path lost")
check(BoardReadableExport.text(pages: [page], transcript: edited, evidence: nil) == BoardExport.text(transcript: edited, images: page.images, terminal: false), "legacy export changed unexpectedly")
var unsafe = evidence
unsafe.speech = [.init(start: 6, end: 12, text: "把 A|B\n按钮放大。")]
let escaped = BoardReadableExport.text(pages: [page], transcript: "完整稿保持原样", evidence: unsafe)
check(escaped.contains("A\\|B 按钮放大"), "speech broke the Markdown table")
let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
let source = directory.appendingPathComponent("原图.png")
let bytes = Data([137, 80, 78, 71, 42])
try bytes.write(to: source)
var input = page
input.images = [source, source]
let root = directory.appendingPathComponent("导出")
let bundle = try BoardFolderExport.create(root: root, pages: [input], transcript: edited, evidence: evidence)
check(bundle.images.map(\.lastPathComponent) == ["图1.png", "图2.png"], "export numbering/order incorrect")
check(bundle.text.contains(edited) && bundle.text.contains("标记 1"), "export lost transcript/evidence")
check(!bundle.text.contains("附件顺序"), "path handoff still asks for attachments")
for image in bundle.images {
    let saved = try Data(contentsOf: image)
    check(saved == bytes && bundle.text.contains(image.path), "export path or bytes invalid")
}
let savedText = try String(contentsOf: bundle.directory.appendingPathComponent("说明.md"), encoding: .utf8)
check(savedText == bundle.text, "saved explanation differs from clipboard text")
try Data([99]).write(to: source)
let second = try BoardFolderExport.create(root: root, pages: [input], transcript: "edited", evidence: nil)
check(second.directory != bundle.directory, "later handoff overwrites earlier files")
try fm.removeItem(at: source)
let originalBytes = try Data(contentsOf: bundle.images[0])
check(originalBytes == bytes, "archive edits/delete damaged exported snapshot")
let before = try fm.contentsOfDirectory(atPath: root.path).sorted()
var missing = input
missing.images = [bundle.images[0], source]
do {
    _ = try BoardFolderExport.create(root: root, pages: [missing], transcript: edited, evidence: evidence)
    fatalError("missing image silently omitted")
} catch {}
let after = try fm.contentsOfDirectory(atPath: root.path).sorted()
check(before == after, "failed export leaves partial handoff")
let speechOnly = try BoardFolderExport.create(root: root, pages: [], transcript: edited, evidence: evidence)
check(speechOnly.images.isEmpty && speechOnly.text.contains(edited), "speech-only export lost text")
// review notes: a written note leads, an added mark says 补画, a note-less timed mark keeps its speech hint
let noted = BoardReadablePage(images: [URL(fileURLWithPath: "/tmp/n.png")], contextIDs: ["home"],
                              marks: [.init(number: 1, start: a, end: b, note: "按钮放大到 44pt"),
                                      .init(number: 7, note: "这里去掉", added: true),
                                      .init(number: 8, added: true),
                                      .init(number: 9, note: "   ", added: true)])
let notedText = BoardReadableExport.text(pages: [noted], transcript: transcript, evidence: evidence)
check(notedText.contains("| 标记 | 时间 | 说明 / 语音参考 |"), "noted page lost its note column")
check(notedText.contains("| 标记 1 | 00:07.0–00:08.0 | 说明：按钮放大到 44pt（这时说的：“这个按钮放大。”） |"), "note did not lead the speech hint")
check(notedText.contains("| 标记 7 | 补画 | 说明：这里去掉 |"), "added mark lost its note")
check(notedText.contains("| 标记 8 | 补画 | — |") && notedText.contains("| 标记 9 | 补画 | — |"), "empty note handled wrongly")
check(notedText.contains("“补画”表示") && !notedText.contains("“未记录”表示"), "added marks explained as legacy")
check(!notedText.contains("未记录"), "added mark shown as lost time")
let unexplained = BoardReadableExport.unexplained(noted.marks, onPage: noted.contextIDs, evidence: evidence).map(\.number)
check(unexplained == [8, 9], "unexplained marks wrong: \(unexplained)")
let roundTrip = try JSONDecoder().decode([BoardMarkEvidence].self, from: JSONEncoder().encode(noted.marks))
check(roundTrip == noted.marks, "note/added lost on save")
let oldRow = try JSONDecoder().decode(BoardMarkEvidence.self, from: Data(#"{"number":3}"#.utf8))
check(oldRow.note == nil && !oldRow.isAdded, "old 页面.json marks no longer load")
print("PASS: complete and edited speech, timing, compact references, unknown times, terminal images, escaping, notes")
'''

@unittest.skipUnless(sys.platform == 'darwin', 'macOS dependencies')
class BoardReadableExportTests(unittest.TestCase):
    def test_handoff_keeps_information_readable(self):
        with tempfile.TemporaryDirectory(prefix='point-taken-readable-test-') as path:
            directory = Path(path)
            (directory / 'main.swift').write_text(HARNESS)
            command = ['xcrun', 'swiftc'] + [str(CORE / name) for name in
                       ['BoardArchive.swift', 'BoardEvidence.swift', 'BoardReadableExport.swift', 'BoardFolderExport.swift']]
            command += [str(directory / 'main.swift'), '-o', str(directory / 'check')]
            result = subprocess.run(command, env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'),
                                    capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(directory / 'check')], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS:', result.stdout)
