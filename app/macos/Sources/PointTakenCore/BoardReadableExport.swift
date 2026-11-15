import Foundation

/// A presentation-only view of selected pages. No archive is rewritten to format a handoff.
public struct BoardReadablePage {
    public var images: [URL]
    public var contextIDs: [String]
    public var marks: [BoardMarkEvidence]
    public init(images: [URL], contextIDs: [String], marks: [BoardMarkEvidence]) {
        self.images = images; self.contextIDs = contextIDs; self.marks = marks
    }
}

public enum BoardReadableExport {
    public static func text(pages: [BoardReadablePage], transcript: String, evidence: BoardEvidence?, terminal: Bool = false) -> String {
        let images = pages.flatMap(\.images)
        guard let evidence else { return BoardExport.text(transcript: transcript, images: images, terminal: terminal) }
        let count = Set(pages.flatMap(\.marks).map(\.number)).count
        let imageReference = terminal ? "图号对应下方本地图片路径" : "图号对应附件顺序"
        var sections = ["# 界面反馈\n\n\(images.count) 张截图 · \(count) 个标记\n\n\(imageReference)，标记号对应图中编号。时间与语音参考只是线索，可能跨页，请结合全文判断；页面名称取自窗口标题。"]
        let segments = evidence.speech.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start < $1.start }

        if !transcript.isEmpty {
            // Only substitute timestamped paragraphs if they cover the exact supplied transcript.
            // Edited or incomplete text must never be silently replaced with recognizer output.
            let joined = segments.map(\.text)
            let timed = !segments.isEmpty && (transcript == joined.joined() || transcript == joined.joined(separator: " "))
            let body = timed ? segments.map { "**\(span($0.start, $0.end))**　\($0.text)" }.joined(separator: "\n\n") : transcript
            sections.append("## 完整转写\n\n" + body)
        }
        if !pages.isEmpty { sections.append("## 按图查看") }
        var imageIndex = 1
        let linked = Set(pages.flatMap(\.contextIDs))
        for page in pages {
            let names = page.images.indices.map { "图\(imageIndex + $0)" }
            let name = names.isEmpty ? "未附图片" : names.joined(separator: "、")
            let visits = evidence.visits.filter { page.contextIDs.contains($0.pageID) }
            let contexts = unique(visits.map { context($0) })
            let caption = contexts.isEmpty ? "" : " · " + inline(contexts.joined(separator: " / "))
            var lines = ["### \(name)\(caption)"]
            let times = unique(visits.map { range($0.start, $0.end) })
            if !times.isEmpty { lines += ["", "页面停留：" + times.joined(separator: "；")] }
            if terminal {
                lines += [""] + zip(names, page.images).map { "\($0)：\($1.path)" }
            }
            if !page.marks.isEmpty {
                // a written note is what the user meant; what was said around the mark is a time-based reference
                let noted = page.marks.contains { $0.writtenNote != nil }
                let around = evidence.said(about: page.marks, onPage: page.contextIDs)
                lines += ["", noted ? "| 标记 | 时间 | 说明 / 语音参考 |" : "| 标记 | 时间 | 语音参考 |", "| --- | --- | --- |"]
                for mark in page.marks {
                    let time: String
                    if let start = mark.start, let end = mark.end { time = range(start, end) }
                    else { time = mark.isAdded ? "补画" : "未记录" }
                    let quote = quotes(around[mark.number] ?? [])
                    let said: String
                    if let note = mark.writtenNote { said = "说明：" + note + (quote.map { "（这时说的：\($0)）" } ?? "") }
                    else { said = quote ?? "—" }
                    lines.append("| 标记 \(mark.number) | \(time) | \(cell(said)) |")
                }
                if page.marks.contains(where: { $0.isAdded && ($0.start == nil || $0.end == nil) }) {
                    lines += ["", "*“补画”表示录音结束后在检查窗口补上的标记，没有录音时间，以说明为准。*"]
                }
                if page.marks.contains(where: { !$0.isAdded && ($0.start == nil || $0.end == nil) }) {
                    lines += ["", "*“未记录”表示旧版标记，没有录音时间。*"]
                }
            } else { lines += ["", "手动保留的截图，没有标记。"] }
            sections.append(lines.joined(separator: "\n"))
            imageIndex += page.images.count
        }
        let unlinked = evidence.visits.filter { !linked.contains($0.pageID) }
        if !unlinked.isEmpty {
            let lines = unlinked.map { "- \(range($0.start, $0.end)) · \(inline(context($0)))" }
            sections.append("## 其他页面停留（无截图）\n\n" + lines.joined(separator: "\n"))
        }
        sections.append("*时间默认对应原始录音，暂停不计入；标注“会话”的时间没有完整音频定位。表中语音按时间归到标记：画的时候说的、紧挨着画说的，以及停顿很短的接着说的话；一句只归一个标记，离哪个标记都远的话只在全文里。“—”表示这段时间没有说话。*")
        return sections.joined(separator: "\n\n")
    }

    /// Marks the AI would get with nothing to go on: no written note and nothing said around them on their page.
    public static func unexplained(_ marks: [BoardMarkEvidence], onPage pageIDs: [String], evidence: BoardEvidence?) -> [BoardMarkEvidence] {
        let around = evidence?.said(about: marks, onPage: pageIDs) ?? [:]
        return marks.filter { $0.writtenNote == nil && (around[$0.number] ?? []).isEmpty }
    }
    /// The sentences as quotes in one table cell: up to three, then how many more the full transcript has.
    private static func quotes(_ said: [BoardSpeechSegment]) -> String? {
        guard !said.isEmpty else { return nil }
        let shown = said.prefix(3).map { excerpt($0.text) }.joined(separator: " ")
        return said.count > 3 ? shown + "（另有 \(said.count - 3) 句，见全文）" : shown
    }
    private static func span(_ start: Double, _ end: Double) -> String {
        BoardEvidence.stamp(start) + "–" + BoardEvidence.stamp(max(start, end))
    }
    private static func range(_ start: BoardMoment, _ end: BoardMoment) -> String {
        if let a = start.audio, let b = end.audio { return span(a, b) }
        return "会话 " + span(start.elapsed, end.elapsed)
    }
    private static func context(_ visit: BoardVisit) -> String {
        let parts = [visit.app, visit.title].filter { !$0.isEmpty }
        return parts.isEmpty ? "标题不可用" : parts.joined(separator: " · ")
    }
    private static func unique(_ strings: [String]) -> [String] {
        var seen: Set<String> = []
        return strings.filter { seen.insert($0).inserted }
    }
    private static func excerpt(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return "“" + String(text.prefix(64)) + (text.count > 64 ? "…" : "") + "”"
    }
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "`", with: "\\`")
    }
    private static func cell(_ text: String) -> String { inline(text).replacingOccurrences(of: "|", with: "\\|") }
}
