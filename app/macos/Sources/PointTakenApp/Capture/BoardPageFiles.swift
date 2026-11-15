import AppKit
import PointTakenCore

/// A list-sized thumbnail (96 px tall, like BoardSession.thumbnail) read with ImageIO, which scales while it decodes:
/// no full-size bitmap of a multi-megapixel screenshot is made just to shrink it.
func boardThumbnail(_ url: URL, height: CGFloat = 96) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
    let h = max(1, (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1)
    let longest = Int(ceil(Double(height) * max(w, h) / h))
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                                           kCGImageSourceShouldCacheImmediately: true,
                                                           kCGImageSourceThumbnailMaxPixelSize: max(Int(height), longest)] as CFDictionary)
}

enum BoardPageFiles {
    static func encode(_ page: BoardSession.Page) -> [String: Any] {
        ["images": page.images.map(\.lastPathComponent), "original": page.original?.lastPathComponent ?? "",
         "marks": page.marks, "text": page.text, "included": page.included, "scene": page.scene,
         "lineWidth": page.lineWidth, "footerTrim": page.footerTrim,
         "sourceFrames": page.sourceFrames.map(\.lastPathComponent), "retainedFiles": page.retainedFiles.map(\.lastPathComponent),
         "components": page.components.map(encode), "componentOffsets": page.componentOffsets,
         "contextIDs": page.contextIDs, "manuallySaved": page.manuallySaved,
         "imageNeedsRepair": page.imageNeedsRepair || page.images.contains(where: { BoardFileWriter.needsRepair($0) }),
         "markEvidence": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(page.markEvidence))) ?? []]
    }
    static func decode(_ row: [String: Any], directory: URL, depth: Int = 0) -> BoardSession.Page? {
        guard depth < 32 else { return nil }
        func path(_ name: String) -> URL? {
            guard !name.isEmpty, (name as NSString).lastPathComponent == name else { return nil }
            return directory.appendingPathComponent(name)
        }
        func file(_ name: String) -> URL? {
            guard let url = path(name) else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let original = (row["original"] as? String).flatMap(path)
        // A failed/interrupted marked-image write must not erase the editable page. Its clean original and
        // persisted strokes are enough to display and regenerate the marked file when it is next saved.
        let images = (row["images"] as? [String] ?? []).compactMap(path)
        guard !images.isEmpty else { return nil }
        return BoardSession.Page(images: images, text: row["text"] as? String ?? "", thumb: boardThumbnail(images[0]) ?? original.flatMap { boardThumbnail($0) },
                                 original: original, marks: row["marks"] as? [[[Double]]] ?? [],
                                 included: row["included"] as? Bool ?? true, scene: row["scene"] as? String ?? "",
                                 lineWidth: CGFloat(row["lineWidth"] as? Double ?? 4), footerTrim: row["footerTrim"] as? Int ?? 0,
                                 sourceFrames: (row["sourceFrames"] as? [String] ?? []).compactMap(file),
                                 retainedFiles: (row["retainedFiles"] as? [String] ?? []).compactMap(file),
                                 components: (row["components"] as? [[String: Any]] ?? []).compactMap { decode($0, directory: directory, depth: depth + 1) },
                                 componentOffsets: row["componentOffsets"] as? [Int] ?? [],
                                 contextIDs: row["contextIDs"] as? [String] ?? [],
                                 markEvidence: (try? JSONSerialization.data(withJSONObject: row["markEvidence"] ?? [])).flatMap { try? JSONDecoder().decode([BoardMarkEvidence].self, from: $0) } ?? [],
                                 manuallySaved: row["manuallySaved"] as? Bool ?? false,
                                 imageNeedsRepair: row["imageNeedsRepair"] as? Bool ?? false)
    }
    static func split(_ page: BoardSession.Page) throws -> [BoardSession.Page] {
        guard !page.components.isEmpty, page.components.count == page.componentOffsets.count,
              let original = page.original, let image = loadCGImage(original) else {
            throw BoardLongImage.Failure(message: "这张图片没有可拆分的原始页面记录。")
        }
        return try zip(page.components, page.componentOffsets).map { source, offset in
            guard let url = source.original, let frame = loadCGImage(url) else { throw BoardStitchError.renderingFailed }
            var part = source
            // Keep the complete stroke in every viewport it intersects. Rendering clips at the image edge.
            var indices: [Int] = []
            part.marks = page.marks.enumerated().compactMap { index, stroke in
                let points = stroke.map { [$0[0], ($0[1] * Double(image.height) - Double(offset)) / Double(frame.height)] }
                let ys = points.map { $0[1] }
                guard (ys.max() ?? -1) >= 0 && (ys.min() ?? 2) <= 1 else { return nil }
                indices.append(index); return points
            }
            part.markEvidence = indices.compactMap { page.markEvidence.indices.contains($0) ? page.markEvidence[$0] : nil }
            part.contextIDs = page.contextIDs
            part.included = page.included
            let output = url.deletingLastPathComponent().appendingPathComponent("拆分标注-\(UUID().uuidString).png")
            guard let marked = renderBoardMarked(frame, strokes: part.marks, evidence: part.markEvidence, lineWidth: part.lineWidth), writePNG(marked, to: output) else { throw BoardStitchError.renderingFailed }
            part.images = [output]; part.thumb = BoardSession.thumbnail(marked)
            return part
        }
    }
}
