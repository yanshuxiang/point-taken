import AppKit
import PointTakenCore

/// Conservative adapter: preserve all source files and refuse alignments that could discard ink.
enum BoardLongImage {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func merge(_ first: BoardSession.Page, _ second: BoardSession.Page) throws -> BoardSession.Page {
        guard !first.scene.isEmpty, first.scene == second.scene,
              second.sourceFrames.count <= 1,
              let firstURL = first.original, let secondURL = second.original,
              let firstImage = loadCGImage(firstURL), let secondImage = loadCGImage(secondURL),
              let lastURL = first.sourceFrames.last ?? first.original, let last = loadCGImage(lastURL),
              let match = BoardScrollStitcher.alignment(previous: last, next: secondImage),
              match.confidence >= 0.97, match.scrollDelta > 2,
              match.overlap >= secondImage.height / 4 else {
            throw Failure(message: "没有找到足够可靠的向下滚动重叠区域，已保留两张原图。")
        }
        let trim = max(first.footerTrim, match.trailingTrim)
        let extraTrim = trim - first.footerTrim
        let keptHeight = firstImage.height - extraTrim
        let newHeight = keptHeight + match.scrollDelta
        // A mark inside a clipped fixed toolbar or uncertain overlap must never silently move/disappear.
        guard first.marks.flatMap({ $0 }).allSatisfy({ $0.count == 2 && $0[1] * Double(firstImage.height) < Double(keptHeight) }),
              second.marks.flatMap({ $0 }).allSatisfy({ $0.count == 2 && $0[1] * Double(secondImage.height) >= Double(match.overlap - trim) }) else {
            throw Failure(message: "标记位于固定栏或重叠区域，暂不自动移动这些标记；请保留分图，或先拼原图再标注。")
        }
        try BoardScrollStitcher.validateOutputSize(width: firstImage.width, height: newHeight)
        guard let head = firstImage.cropping(to: CGRect(x: 0, y: 0, width: firstImage.width, height: keptHeight)) else {
            throw BoardStitchError.renderingFailed
        }
        let tail = try BoardScrollStitcher.newContentSegment(from: secondImage, overlap: match.overlap, trailingTrim: trim)
        let combined = try BoardScrollStitcher.render(segments: [head, tail])
        let marks = first.marks.map { stroke in stroke.map { [$0[0], $0[1] * Double(firstImage.height) / Double(newHeight)] } }
            + second.marks.map { stroke in stroke.map { [$0[0], (Double(firstImage.height + first.footerTrim - match.overlap) + $0[1] * Double(secondImage.height)) / Double(newHeight)] } }
        let id = UUID().uuidString
        let original = firstURL.deletingLastPathComponent().appendingPathComponent("长图原图-\(id).png")
        let output = original.deletingLastPathComponent().appendingPathComponent("长图标注-\(id).png")
        guard let marked = renderBoardMarked(combined, strokes: marks, evidence: first.markEvidence + second.markEvidence, lineWidth: first.lineWidth),
              writePNG(combined, to: original), writePNG(marked, to: output) else {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: output)
            throw BoardStitchError.renderingFailed
        }
        return BoardSession.Page(images: [output], text: [first.text, second.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                                 thumb: BoardSession.thumbnail(marked), original: original, marks: marks,
                                 included: first.included || second.included, scene: first.scene, lineWidth: first.lineWidth, footerTrim: trim,
                                 sourceFrames: (first.sourceFrames.isEmpty ? [firstURL] : first.sourceFrames) + [secondURL],
                                 retainedFiles: Array(first.allFiles.union(second.allFiles)),
                                 components: (first.components.isEmpty ? [first] : first.components) + [second],
                                 componentOffsets: (first.components.isEmpty ? [0] : first.componentOffsets) + [firstImage.height + first.footerTrim - match.overlap],
                                 contextIDs: Array(Set(first.contextIDs + second.contextIDs)).sorted(),
                                 markEvidence: first.markEvidence + second.markEvidence,
                                 manuallySaved: first.manuallySaved || second.manuallySaved)
    }

    /// Joins `second` under `first` at a verified scroll (`proof`, measured from first's last screen picture to
    /// second's). Unlike `merge`, marks on content both pictures show are kept — the proof says exactly where that
    /// content is — but a mark on second's pinned bars (which do not belong to the document) refuses the join.
    /// Marks second only carried over from first (the same numbers, drawn before the scroll) are not doubled.
    static func join(_ first: BoardSession.Page, _ second: BoardSession.Page, proof: BoardScrollProof,
                     firstImage: CGImage, last: CGImage, secondImage: CGImage) throws -> BoardSession.Page {
        guard !first.scene.isEmpty, first.scene == second.scene, second.components.isEmpty,
              let firstURL = first.original, let secondURL = second.original,
              last.width == secondImage.width, last.height == secondImage.height, firstImage.width == secondImage.width else {
            throw Failure(message: "两页不是同一窗口里的同尺寸截图。")
        }
        let h = secondImage.height
        let overlap = h - proof.delta
        let trim = max(first.footerTrim, proof.footer)
        let keptHeight = firstImage.height - (trim - first.footerTrim)
        let newHeight = keptHeight + proof.delta
        guard proof.delta > 0, overlap > 0, overlap - trim >= proof.header else {
            throw Failure(message: "滚动距离不足以拼接。")
        }
        let known = Set(first.markEvidence.map(\.number))
        let fresh = zip(second.marks, second.markEvidence).filter { !known.contains($0.1.number) }
        let extra = second.marks.count > second.markEvidence.count ? Array(second.marks[second.markEvidence.count...]) : []
        let secondMarks = fresh.map(\.0) + extra
        let firstLimit = Double(keptHeight) / Double(firstImage.height)
        let secondTop = Double(proof.header) / Double(h), secondBottom = Double(h - trim) / Double(h)
        let firstFits = first.marks.joined().allSatisfy { (point: [Double]) -> Bool in point.count == 2 && point[1] < firstLimit }
        let secondFits = secondMarks.joined().allSatisfy { (point: [Double]) -> Bool in
            point.count == 2 && point[1] >= secondTop && point[1] < secondBottom
        }
        guard firstFits, secondFits else {
            throw Failure(message: "有标记画在固定栏上，已保留分页。")
        }
        try BoardScrollStitcher.validateOutputSize(width: firstImage.width, height: newHeight)
        guard let head = firstImage.cropping(to: CGRect(x: 0, y: 0, width: firstImage.width, height: keptHeight)) else {
            throw BoardStitchError.renderingFailed
        }
        let tail = try BoardScrollStitcher.newContentSegment(from: secondImage, overlap: overlap, trailingTrim: trim)
        let combined = try BoardScrollStitcher.render(segments: [head, tail])
        let shift = Double(firstImage.height + first.footerTrim - overlap)
        let marks = first.marks.map { stroke in stroke.map { [$0[0], $0[1] * Double(firstImage.height) / Double(newHeight)] } }
            + secondMarks.map { stroke in stroke.map { [$0[0], (shift + $0[1] * Double(h)) / Double(newHeight)] } }
        let evidence = first.markEvidence + fresh.map(\.1)
        let id = UUID().uuidString
        let original = firstURL.deletingLastPathComponent().appendingPathComponent("长图原图-\(id).png")
        let output = original.deletingLastPathComponent().appendingPathComponent("长图标注-\(id).png")
        guard let marked = renderBoardMarked(combined, strokes: marks, evidence: evidence, lineWidth: first.lineWidth),
              writePNG(combined, to: original), writePNG(marked, to: output) else {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: output)
            throw BoardStitchError.renderingFailed
        }
        return BoardSession.Page(images: [output], text: [first.text, second.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                                 thumb: BoardSession.thumbnail(marked), original: original, marks: marks,
                                 included: first.included || second.included, scene: first.scene, lineWidth: first.lineWidth, footerTrim: trim,
                                 sourceFrames: (first.sourceFrames.isEmpty ? [firstURL] : first.sourceFrames) + [secondURL],
                                 retainedFiles: Array(first.allFiles.union(second.allFiles)),
                                 components: (first.components.isEmpty ? [first] : first.components) + [second],
                                 componentOffsets: (first.components.isEmpty ? [0] : first.componentOffsets) + [Int(shift)],
                                 contextIDs: Array(Set(first.contextIDs + second.contextIDs)).sorted(),
                                 markEvidence: evidence,
                                 manuallySaved: first.manuallySaved || second.manuallySaved,
                                 capturedAt: second.capturedAt)
    }
}

/// The review's automatic long pictures. Two neighbouring pages become one only when the record proves the second
/// is the first scrolled down: same window, nothing but downward scrolling between the two captures (no click, no
/// key), and the pixels line up at exactly one distance (BoardScrollProver). Anything less keeps them apart.
enum BoardAutoMerge {
    struct Result {
        var pages: [BoardSession.Page]
        /// for each page out, the page numbers (1-based, before joining) it was made from
        var origin: [[Int]]
        /// the long pictures made: their page numbers before joining
        var joined: [[Int]] { origin.filter { $0.count > 1 } }
        /// files written for the long pictures
        var made: Set<URL>
    }

    static func run(_ pages: [BoardSession.Page], inputs: [BoardInput]) -> Result {
        var out: [BoardSession.Page] = []
        var groups: [[Int]] = []
        var made: Set<URL> = []
        for (index, page) in pages.enumerated() {
            if let previous = out.last, let joined = try? join(previous, page, inputs: inputs) {
                out[out.count - 1] = joined
                groups[groups.count - 1].append(index + 1)
                made.formUnion(joined.images + [joined.original].compactMap { $0 })
            } else {
                out.append(page)
                groups.append([index + 1])
            }
        }
        return Result(pages: out, origin: groups, made: made)
    }

    /// `second` under `first` when the record proves the scroll; nil (or a thrown refusal) otherwise.
    static func join(_ first: BoardSession.Page, _ second: BoardSession.Page, inputs: [BoardInput]) throws -> BoardSession.Page? {
        guard !first.keepApart, !second.keepApart, second.components.isEmpty,
              !first.scene.isEmpty, first.scene == second.scene,
              let from = first.capturedAt, let to = second.capturedAt,
              BoardScrollInput.onlyScrolledDown(inputs, from: from, to: to),
              let firstURL = first.original, let secondURL = second.original,
              let lastURL = first.sourceFrames.last ?? first.original,
              let firstImage = loadCGImage(firstURL), let secondImage = loadCGImage(secondURL),
              let last = lastURL == firstURL ? firstImage : loadCGImage(lastURL),
              let lastGray = BoardGrayImage(last), let secondGray = BoardGrayImage(secondImage),
              let proof = BoardScrollProver.prove(previous: lastGray, next: secondGray) else { return nil }
        return try BoardLongImage.join(first, second, proof: proof, firstImage: firstImage, last: last, secondImage: secondImage)
    }
}
