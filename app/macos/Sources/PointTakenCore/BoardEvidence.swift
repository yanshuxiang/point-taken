import Foundation

/// Audio positions come from samples actually written, never from speech callback arrival times.
public struct BoardMoment: Codable, Equatable {
    public var elapsed: Double
    public var audio: Double?
    public init(elapsed: Double, audio: Double? = nil) { self.elapsed = elapsed; self.audio = audio }
}

public struct BoardMarkEvidence: Codable, Equatable {
    public var number: Int
    public var start: BoardMoment?
    public var end: BoardMoment?
    /// what the user wrote for this mark in the review window (nil: nothing written)
    public var note: String?
    /// drawn in the review window after recording (so it has no recording time by design, not by loss)
    public var added: Bool?
    public init(number: Int, start: BoardMoment? = nil, end: BoardMoment? = nil, note: String? = nil, added: Bool? = nil) {
        self.number = number; self.start = start; self.end = end; self.note = note; self.added = added
    }
    /// the written note, trimmed; nil when there is none
    public var writtenNote: String? {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
    public var isAdded: Bool { added == true }
}

public struct BoardSpeechSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct BoardVisit: Codable {
    public var pageID: String
    public var app: String
    public var title: String
    public var start: BoardMoment
    public var end: BoardMoment
    public init(pageID: String, app: String, title: String, start: BoardMoment, end: BoardMoment) {
        self.pageID = pageID; self.app = app; self.title = title; self.start = start; self.end = end
    }
}

public struct BoardEvidence: Codable {
    public var version = 1
    public var visits: [BoardVisit] = []
    public var speech: [BoardSpeechSegment] = []
    public var speechTimingSource = "unavailable"
    public init() {}
    public static let filename = "时间线.json"

    public static func load(_ directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public func save(_ directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
    public static func stamp(_ seconds: Double) -> String {
        let t = max(0, seconds)
        return String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
    public static func range(_ start: BoardMoment, _ end: BoardMoment) -> String {
        if let a = start.audio, let b = end.audio { return "音频 \(stamp(a))–\(stamp(max(a, b)))" }
        return "会话 \(stamp(start.elapsed))–\(stamp(max(start.elapsed, end.elapsed)))（此段无完整音频定位）"
    }
    /// Whole recognition phrases plus nearby context; this is a candidate set, never a semantic assignment.
    public func nearby(_ mark: BoardMarkEvidence) -> [BoardSpeechSegment] {
        guard let start = mark.start?.audio, let end = mark.end?.audio else { return [] }
        let valid = speech.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard let first = valid.firstIndex(where: { $0.end >= start - 5 && $0.start <= end + 5 }),
              let last = valid.lastIndex(where: { $0.end >= start - 5 && $0.start <= end + 5 }) else { return [] }
        let lower = first > 0 && start - valid[first - 1].end <= 10 ? first - 1 : first
        let upper = last + 1 < valid.count && valid[last + 1].start - end <= 10 ? last + 1 : last
        return Array(valid[lower...upper])
    }
    /// how near (s) a sentence that doesn't overlap any drawing must be to a mark to be about it
    static let saidReach = 3.0
    /// the longest pause (s) after which a following sentence still goes on about the same mark
    static let saidPause = 2.0

    /// What was said about each mark of one page, by time only (never a guess at what "this" meant), one sentence to
    /// one mark (2026-11-15 dogfood: three marks a few seconds apart each got the same two or three sentences):
    /// - a sentence said while a mark was being drawn is that mark's; overlapping two drawings, the one it overlaps more
    /// - otherwise the mark it is nearest to, before or after, within `saidReach` (people start talking just before
    ///   they draw, or right after)
    /// - otherwise it goes on about the mark the sentence before it was about, when the pause between them is at most
    ///   `saidPause` and no other mark was drawn in between ("…换成圆角矩形吧。" "不对，是换成圆形。")
    /// - half a sentence (no 。？！ at its end) followed right away by the rest goes where the rest went
    /// - anything else is about no mark (it stays in the full transcript)
    /// A mark left with nothing, drawn while a sentence went to another mark (one sentence about two marks drawn
    /// during it), shares that sentence. Only sentences said while the mark's page was up count (no visit known: ten
    /// seconds either side of the mark). Pure fillers (嗯, 啊…) are left out. Marks without a recording time (drawn in
    /// review) get nothing. Keyed by mark number, sentences in order.
    public func said(about marks: [BoardMarkEvidence], onPage pageIDs: [String]) -> [Int: [BoardSpeechSegment]] {
        let fillers: Set<String> = ["嗯", "啊", "呃", "额", "哦", "唔", "嗯嗯", "啊啊"]
        let sentences = speech.filter {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                && !text.isEmpty && !fillers.contains(text)
        }.sorted { $0.start < $1.start }
        let stays: [(Double, Double)] = visits.filter { pageIDs.contains($0.pageID) }.compactMap { v in
            guard let a = v.start.audio, let b = v.end.audio, a.isFinite, b.isFinite else { return nil }
            return (a, max(a, b))
        }
        let timed = marks.compactMap { m -> (number: Int, start: Double, end: Double)? in
            guard let a = m.start?.audio, let b = m.end?.audio, a.isFinite, b.isFinite else { return nil }
            return (m.number, a, max(a, b))
        }.sorted { $0.start < $1.start }
        // each mark's window: the visit it was drawn in; without one, ten seconds either side
        let windows = timed.map { mark -> (Double, Double) in
            let stay = stays.first { $0.0 - 0.05 <= mark.start && mark.start <= $0.1 + 0.05 }
            return (min(stay?.0 ?? mark.start - 10, mark.start), max(stay?.1 ?? mark.end + 10, mark.end))
        }
        func overlap(_ s: BoardSpeechSegment, _ a: Double, _ b: Double) -> Double { min(s.end, b) - max(s.start, a) }
        func gap(_ s: BoardSpeechSegment, _ m: Int) -> Double {
            max(timed[m].start - s.end, s.start - timed[m].end, 0)
        }
        // which mark (index into timed) each sentence is about, nil: none
        var owner = [Int?](repeating: nil, count: sentences.count)
        for (k, s) in sentences.enumerated() {
            let reachable = timed.indices.filter { overlap(s, windows[$0].0, windows[$0].1) > 0 }
            let drawing = reachable.filter { overlap(s, timed[$0].start, timed[$0].end) > 0 }
            if let m = drawing.max(by: { overlap(s, timed[$0].start, timed[$0].end) < overlap(s, timed[$1].start, timed[$1].end) }) {
                owner[k] = m
            } else if let m = reachable.filter({ gap(s, $0) <= Self.saidReach }).min(by: { gap(s, $0) < gap(s, $1) }) {
                owner[k] = m
            } else if k > 0, let m = owner[k - 1], reachable.contains(m),
                      s.start - sentences[k - 1].end <= Self.saidPause,
                      !timed.indices.contains(where: { $0 != m && timed[$0].start >= timed[m].start && timed[$0].start < s.start }) {
                owner[k] = m
            }
        }
        // half a sentence (recognition cut it, no 。？！ at the end) goes with the rest of it when that follows right away:
        // "然后这些" | "这些按钮吧，让它…" (2026-11-15 18:06)
        let enders: Set<Character> = ["。", "？", "！", "?", "!", ".", "…"]
        for k in sentences.indices.dropLast().reversed() {
            let text = sentences[k].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = text.last, !enders.contains(last), let next = owner[k + 1],
                  sentences[k + 1].start - sentences[k].end <= Self.saidPause,
                  overlap(sentences[k], windows[next].0, windows[next].1) > 0 else { continue }
            owner[k] = next
        }
        var out: [Int: [BoardSpeechSegment]] = [:]
        for (i, mark) in timed.enumerated() {
            var mine = sentences.indices.filter { owner[$0] == i }
            if mine.isEmpty { mine = sentences.indices.filter { overlap(sentences[$0], mark.start, mark.end) > 0 } }
            out[mark.number] = mine.map { sentences[$0] }
        }
        return out
    }
}

public struct BoardCaptureClock {
    private var began: Double
    private var excluded = 0.0
    private var pauseStart: Double?
    public init(now: Double) { began = now }
    public mutating func pause(at now: Double) { if pauseStart == nil { pauseStart = now } }
    public mutating func resume(at now: Double) {
        if let start = pauseStart { excluded += max(0, now - start); pauseStart = nil }
    }
    public func elapsed(at now: Double) -> Double { max(0, (pauseStart ?? now) - began - excluded) }
}
