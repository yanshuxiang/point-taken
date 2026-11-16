import CoreGraphics
import Foundation

/// The parts of the screen that move on their own: a carousel of video covers, a playing video, an animated banner.
/// Learned from frames that changed while the user did nothing (no click, no key, no scroll), so the change can only
/// be the page itself. Comparisons that decide "is this still the same page" leave these cells out: a cover turning
/// over is not a new page. Cells are those of BoardFrameFingerprint (64 × 40, rows from the top).
///
/// It stays a widget-sized exception: a quiet change over more than half the screen (a slideshow advancing, a page
/// loading) is never learned, and a mask that would cover more than half the screen is not used.
public struct BoardMotionMask: Equatable {
    public static let columns = 64, rows = 40
    static let count = columns * rows
    /// a cell counts as changed when its mean gray level moved by more than this
    static let cellTolerance = 8
    /// share of the screen above which a quiet change is not a widget, and a mask is not used
    public static let widgetLimit = 0.5

    public private(set) var dynamic = [Bool](repeating: false, count: count)
    public init() {}

    public var isEmpty: Bool { !dynamic.contains(true) }
    public var share: Double { Double(dynamic.lazy.filter { $0 }.count) / Double(Self.count) }
    /// usable: something moves, and it is a part of the screen, not most of it
    public var usable: Bool { !isEmpty && share <= Self.widgetLimit }

    public mutating func reset() { dynamic = [Bool](repeating: false, count: Self.count) }

    /// Learns from two consecutive frames with no user input between or just before them. The changed cells (and
    /// their neighbours, for the moving thing's edges) become dynamic — unless the change is most of the screen.
    public mutating func learn(from a: BoardFrameFingerprint, to b: BoardFrameFingerprint) {
        guard a.values.count == Self.count, b.values.count == Self.count else { return }
        let changed = (0..<Self.count).filter { abs(Int(a.values[$0]) - Int(b.values[$0])) > Self.cellTolerance }
        guard !changed.isEmpty, Double(changed.count) <= Self.widgetLimit * Double(Self.count) else { return }
        var next = dynamic
        for index in changed {
            let x = index % Self.columns, y = index / Self.columns
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < Self.columns, ny >= 0, ny < Self.rows { next[ny * Self.columns + nx] = true }
            } }
        }
        guard Double(next.lazy.filter { $0 }.count) <= Self.widgetLimit * Double(Self.count) else { return }
        dynamic = next
    }

    /// Like `BoardFrameFingerprint.distance`, over the cells that do not move on their own (all cells when the mask
    /// is empty or not usable).
    public func distance(_ a: BoardFrameFingerprint, _ b: BoardFrameFingerprint) -> Double {
        guard usable, a.values.count == Self.count, b.values.count == Self.count else { return a.distance(to: b) }
        var sum = 0, cells = 0
        for index in 0..<Self.count where !dynamic[index] {
            sum += abs(Int(a.values[index]) - Int(b.values[index])); cells += 1
        }
        return cells > 0 ? Double(sum) / Double(cells * 255) : 0
    }

    /// How much the moving cells differ between two frames (0 when nothing is known to move).
    public func movingDistance(_ a: BoardFrameFingerprint, _ b: BoardFrameFingerprint) -> Double {
        guard usable, a.values.count == Self.count, b.values.count == Self.count else { return 0 }
        var sum = 0, cells = 0
        for index in 0..<Self.count where dynamic[index] {
            sum += abs(Int(a.values[index]) - Int(b.values[index])); cells += 1
        }
        return cells > 0 ? Double(sum) / Double(cells * 255) : 0
    }

    /// Whether a mark (points normalised to the picture, from the top-left) lies on a moving cell, its bounding box
    /// included: a box drawn around a cover counts.
    public func touches(_ stroke: [[Double]]) -> Bool {
        guard usable else { return false }
        let points = stroke.filter { $0.count == 2 }
        guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max() else { return false }
        func column(_ v: Double) -> Int { min(Self.columns - 1, max(0, Int(v * Double(Self.columns)))) }
        func row(_ v: Double) -> Int { min(Self.rows - 1, max(0, Int(v * Double(Self.rows)))) }
        guard maxX >= 0, minX <= 1, maxY >= 0, minY <= 1 else { return false }
        for y in row(minY)...row(maxY) { for x in column(minX)...column(maxX) where dynamic[y * Self.columns + x] { return true } }
        return false
    }
}
