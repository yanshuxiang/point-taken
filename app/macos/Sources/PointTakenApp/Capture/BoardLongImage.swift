import AppKit

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
}
