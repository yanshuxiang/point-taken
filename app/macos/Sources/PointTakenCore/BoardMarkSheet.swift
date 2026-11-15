import CoreGraphics
import Foundation

/// One page's marks as the review window edits them: each stroke kept together with its number, its recording times
/// and the note written for it, so deleting or re-noting one mark can never shift another's number or words.
/// Points are normalized 0–1, origin top-left (the format `页面.json` keeps).
public struct BoardMarkSheet: Equatable {
    public struct Mark: Equatable {
        public var points: [[Double]]
        public var evidence: BoardMarkEvidence
        public init(points: [[Double]], evidence: BoardMarkEvidence) { self.points = points; self.evidence = evidence }
    }
    public private(set) var marks: [Mark]

    /// Pairs strokes with their evidence by position. Strokes an older record kept without evidence get numbers from
    /// `firstFree` on (and no times: nothing is invented).
    public init(strokes: [[[Double]]], evidence: [BoardMarkEvidence], firstFree: Int) {
        var next = firstFree
        marks = strokes.enumerated().map { i, points in
            if evidence.indices.contains(i) { return Mark(points: points, evidence: evidence[i]) }
            defer { next += 1 }
            return Mark(points: points, evidence: BoardMarkEvidence(number: next))
        }
    }

    public var strokes: [[[Double]]] { marks.map(\.points) }
    public var evidence: [BoardMarkEvidence] { marks.map(\.evidence) }
    public var isEmpty: Bool { marks.isEmpty }
    public func index(of number: Int) -> Int? { marks.firstIndex { $0.evidence.number == number } }

    /// A mark drawn in the review window: numbered `number`, flagged as added after recording.
    public mutating func add(_ points: [[Double]], number: Int) {
        marks.append(Mark(points: points, evidence: BoardMarkEvidence(number: number, added: true)))
    }
    @discardableResult public mutating func remove(number: Int) -> Bool {
        guard let i = index(of: number) else { return false }
        marks.remove(at: i)
        return true
    }
    /// Whitespace-only text clears the note. False when nothing changed.
    @discardableResult public mutating func setNote(_ text: String, number: Int) -> Bool {
        guard let i = index(of: number) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: String? = trimmed.isEmpty ? nil : trimmed
        guard marks[i].evidence.note != new else { return false }
        marks[i].evidence.note = new
        return true
    }

    /// Where a mark's number badge sits in a `size` picture (top-left origin): up and left of where the stroke began,
    /// kept inside the picture. The same place the exported PNG draws it.
    public static func badgeCenter(_ points: [[Double]], size: CGSize, diameter: CGFloat) -> CGPoint? {
        guard let first = points.first, first.count == 2 else { return nil }
        let r = diameter / 2
        let x = min(max(r, CGFloat(first[0]) * size.width - r), size.width - r)
        let y = min(max(r, CGFloat(first[1]) * size.height - r), size.height - r)
        return CGPoint(x: x, y: y)
    }

    /// The mark under `p` in a `size` picture (top-left origin): its badge first, then its line within `tolerance`
    /// (a single-point mark is a ring of radius `ring`). The mark drawn last wins where they overlap.
    public func hit(_ p: CGPoint, size: CGSize, tolerance: CGFloat, ring: CGFloat, badge: CGFloat) -> Int? {
        for mark in marks.reversed() {
            if let c = Self.badgeCenter(mark.points, size: size, diameter: badge), hypot(p.x - c.x, p.y - c.y) <= badge / 2 + 2 {
                return mark.evidence.number
            }
        }
        for mark in marks.reversed() {
            let pts = mark.points.filter { $0.count == 2 }.map { CGPoint(x: CGFloat($0[0]) * size.width, y: CGFloat($0[1]) * size.height) }
            guard let first = pts.first else { continue }
            if pts.count == 1 {
                if hypot(p.x - first.x, p.y - first.y) <= ring + tolerance { return mark.evidence.number }
                continue
            }
            for (a, b) in zip(pts, pts.dropFirst()) where Self.distance(p, a, b) <= tolerance { return mark.evidence.number }
        }
        return nil
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Whether a page goes to the AI after its marks changed in review: gaining its first mark checks it, losing its last
/// unchecks it; anything else keeps the user's choice.
public enum BoardPageInclusion {
    public static func after(change before: Int, to after: Int, included: Bool) -> Bool {
        if before == 0 && after > 0 { return true }
        if before > 0 && after == 0 { return false }
        return included
    }
}
