import CoreGraphics
import Foundation

// Deciding, after recording, that two consecutive pages are one document scrolled down — so the review can join them
// into one long picture. A join that only "looks right" would put marks on the wrong content, so both halves of the
// proof are strict and either one alone refuses:
//   1. what the user did between the two captures was only scrolling, and downwards (BoardScrollInput);
//   2. the pixels agree: below the pinned bars, the second picture is the first moved up by exactly one distance,
//      row for row, over a long, detailed stretch, and no other distance comes close (BoardScrollProver).

/// One input the screen feed saw going to another app during recording. Never which key or where: only the kind, the
/// moment, and for the scroll wheel how far it moved the content.
public struct BoardInput: Codable, Equatable {
    public enum Kind: String, Codable { case scroll, click, key }
    public var kind: Kind
    /// session seconds (the same clock as BoardMoment.elapsed)
    public var at: Double
    /// scroll only: points the content moved; negative reveals what is below
    public var dy: Double?
    public init(kind: Kind, at: Double, dy: Double? = nil) { self.kind = kind; self.at = at; self.dy = dy }
}

public enum BoardScrollInput {
    /// Consecutive wheel events closer than this are kept as one entry (a trackpad sends ~60 a second).
    public static let coalesceWindow = 0.15

    /// Appends `input`, folding a scroll into the previous scroll entry when it follows within `coalesceWindow`.
    public static func append(_ input: BoardInput, to inputs: inout [BoardInput]) {
        if input.kind == .scroll, let last = inputs.last, last.kind == .scroll, input.at - last.at <= coalesceWindow {
            inputs[inputs.count - 1].dy = (last.dy ?? 0) + (input.dy ?? 0)
            inputs[inputs.count - 1].at = input.at
            return
        }
        inputs.append(input)
    }

    /// True only when, strictly between the two captures, the wheel was used, nothing else was (no click, no key:
    /// either could have navigated), and the content moved down the document overall.
    public static func onlyScrolledDown(_ inputs: [BoardInput], from start: Double, to end: Double) -> Bool {
        guard end > start else { return false }
        let between = inputs.filter { $0.at > start && $0.at < end }
        guard !between.isEmpty, between.allSatisfy({ $0.kind == .scroll }) else { return false }
        let moved = between.compactMap(\.dy).reduce(0, +)
        return moved <= -1
    }
}

/// A grayscale picture, one byte per pixel, rows from the top.
public struct BoardGrayImage {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: bytes)
    }
}

/// The verified scroll between two pictures of the same size.
public struct BoardScrollProof: Equatable {
    /// pixels the content moved up from the first picture to the second
    public let delta: Int
    /// rows pinned at the top of both (menu bar, browser toolbar, a sticky header)
    public let header: Int
    /// rows pinned at the bottom of both (the Dock, a status bar)
    public let footer: Int
    /// rows of moved content that matched
    public let compared: Int
}

public enum BoardScrollProver {
    /// column blocks per row in the row signatures
    static let blocks = 48
    /// a row is pinned when this share of its blocks is unchanged (a ticking clock or network meter is allowed)
    static let pinnedShare = 0.9
    /// mean block difference (0–255) the best distance may have, and how far every other distance must stay above it
    static let bestLimit: Float = 1.0
    static let runnerUpFloor: Float = 3.0
    static let runnerUpRatio: Float = 4
    /// per-pixel check at the chosen distance: differences above `pixelTolerance` may cover at most `mismatchShare`
    static let pixelTolerance = 24
    static let mismatchShare = 0.002
    static let pixelMeanLimit = 1.0

    public static func prove(previous a: BoardGrayImage, next b: BoardGrayImage) -> BoardScrollProof? {
        guard a.width == b.width, a.height == b.height, a.width >= blocks, a.height >= 96,
              a.pixels.count == a.width * a.height, b.pixels.count == b.width * b.height else { return nil }
        let h = a.height
        let pa = signatures(a), pb = signatures(b)

        // pinned bands: rows unchanged in place, from each edge (a few odd rows inside a bar are tolerated)
        let pinned = (0..<h).map { y -> Bool in
            var same = 0
            for k in 0..<blocks where abs(pa[y * blocks + k] - pb[y * blocks + k]) <= 2 { same += 1 }
            return Double(same) >= pinnedShare * Double(blocks)
        }
        let header = band(pinned, from: 0, step: 1, limit: h / 2)
        let footer = band(pinned, from: h - 1, step: -1, limit: h / 2)
        let content = h - header - footer
        // most of the picture did not move (or it all changed): not a scroll of one document
        guard content >= h / 3 else { return nil }
        let minOverlap = max(content / 4, 48)
        let minDelta = max(8, h / 200)
        let maxDelta = content - minOverlap
        guard maxDelta >= minDelta else { return nil }

        // second picture's row y (below the header) against the first's row y + s, over every distance s ≥ 0
        func score(_ s: Int, step: Int) -> Float {
            var sum: Float = 0
            var count = 0
            var y = header
            while y < h - footer - s {
                let rb = y * blocks, ra = (y + s) * blocks
                for k in 0..<blocks { sum += abs(pb[rb + k] - pa[ra + k]) }
                count += blocks
                y += step
            }
            return count > 0 ? sum / Float(count) : .infinity
        }
        var scores = [Float](repeating: .infinity, count: maxDelta + 1)
        for s in 0...maxDelta { scores[s] = score(s, step: 2) }
        guard let best = scores.indices.min(by: { scores[$0] < scores[$1] }), best >= minDelta else { return nil }
        let runnerUp = scores.indices.filter { abs($0 - best) > 6 }.map { scores[$0] }.min() ?? .infinity
        let exact = score(best, step: 1)
        guard scores[best] <= bestLimit, exact <= bestLimit,
              runnerUp >= max(runnerUpFloor, runnerUpRatio * max(scores[best], exact)) else { return nil }

        // the compared stretch must carry detail, or any distance would "match" a blank page
        let rows = Array(header..<(h - footer - best))
        var detailed = 0
        for y in rows {
            let r = y * blocks
            var low: Float = 255, high: Float = 0, change: Float = 0
            for k in 0..<blocks {
                let v = pb[r + k]
                low = min(low, v); high = max(high, v)
                if y > 0 { change += abs(v - pb[r - blocks + k]) }
            }
            if high - low > 6 || change / Float(blocks) > 3 { detailed += 1 }
        }
        guard detailed >= max(24, rows.count / 10) else { return nil }

        // finally the pixels themselves (every other column) at that distance
        var mismatched = 0, total = 0, sum = 0
        for y in rows {
            let rb = y * b.width, ra = (y + best) * a.width
            var x = 0
            while x < b.width {
                let d = abs(Int(b.pixels[rb + x]) - Int(a.pixels[ra + x]))
                sum += d; total += 1
                if d > pixelTolerance { mismatched += 1 }
                x += 2
            }
        }
        guard total > 0, Double(mismatched) <= mismatchShare * Double(total),
              Double(sum) / Double(total) <= pixelMeanLimit else { return nil }
        return BoardScrollProof(delta: best, header: header, footer: footer, compared: rows.count)
    }

    /// The length of the pinned band starting at `from`: the longest run whose rows are at least 97 % pinned and
    /// that ends on a pinned row.
    private static func band(_ pinned: [Bool], from start: Int, step: Int, limit: Int) -> Int {
        var length = 0, kept = 0, best = 0
        var y = start
        while length < limit, y >= 0, y < pinned.count {
            length += 1
            if pinned[y] { kept += 1 }
            if pinned[y], Double(kept) >= 0.97 * Double(length) { best = length }
            if Double(kept) < 0.9 * Double(length), length > 16 { break }
            y += step
        }
        return best
    }

    /// Each row as `blocks` column means.
    private static func signatures(_ image: BoardGrayImage) -> [Float] {
        let width = image.width / blocks
        var out = [Float](repeating: 0, count: image.height * blocks)
        image.pixels.withUnsafeBufferPointer { p in
            for y in 0..<image.height {
                let row = y * image.width
                for k in 0..<blocks {
                    var sum = 0
                    let start = row + k * width
                    for x in 0..<width { sum += Int(p[start + x]) }
                    out[y * blocks + k] = Float(sum) / Float(width)
                }
            }
        }
        return out
    }
}
