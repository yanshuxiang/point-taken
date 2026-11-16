import AppKit
import PointTakenCore

/// One marked document, in document pixel coordinates. Screen changes without verified overlap
/// end the chain; originals survive both automatic merging and a later split in the review.
final class BoardLiveScroll {
    private(set) var page: BoardSession.Page
    private(set) var frame: BoardScreenFeed.Frame
    private(set) var offset = 0
    private var furthest = 0
    init(page: BoardSession.Page, frame: BoardScreenFeed.Frame) {
        self.page = page; self.frame = frame
        // the page was just saved from this very frame: its original is this picture (no need to read it back)
        if let url = page.original { cached = (url, frame.image) }
    }
    /// the page's original, decoded once (each stroke used to read and decode the full-screen PNG again)
    private var cached: (url: URL, image: CGImage)?
    /// Alignment works against an immutable snapshot on the worker queue. Only a still-current result is adopted.
    func snapshot() -> BoardLiveScroll {
        let copy = BoardLiveScroll(page: page, frame: frame)
        copy.offset = offset; copy.furthest = furthest; copy.cached = cached
        return copy
    }
    private func original() -> CGImage? {
        guard let url = page.original else { return nil }
        if let c = cached, c.url == url { return c.image }
        BoardFileWriter.flush()             // a write still queued for it lands first
        guard let image = loadCGImage(url) else { return nil }
        cached = (url, image)
        return image
    }
    var viewportMarks: [[[Double]]] {
        guard let image = original() else { return [] }
        return page.marks.map { stroke in stroke.map { [$0[0], ($0[1] * Double(image.height) - Double(offset)) / Double(frame.image.height)] } }
    }
    func add(_ stroke: [[Double]], evidence: BoardMarkEvidence? = nil) throws {
        guard let image = original() else { throw BoardStitchError.renderingFailed }
        let previous = page
        page.marks.append(stroke.map { [$0[0], ($0[1] * Double(frame.image.height) + Double(offset)) / Double(image.height)] })
        if let evidence { page.markEvidence.append(evidence) }
        do { try redraw(image) } catch { page = previous; throw error }
    }
    /// The page takes `next` as its picture, the marks redrawn on it: a part of the page that moves by itself (a
    /// carousel) changed, and a mark is about to be drawn on what is shown now. Only a plain page at its first
    /// viewport, with a picture of the same size; false otherwise (nothing changed then).
    func replacePicture(with next: BoardScreenFeed.Frame) throws -> Bool {
        guard offset == 0, furthest == 0, page.components.isEmpty, let url = page.original,
              next.scene == frame.scene, next.image.width == frame.image.width, next.image.height == frame.image.height else { return false }
        let previous = (page, frame, cached)
        BoardFileWriter.png(next.image, to: url)
        cached = (url, next.image)
        frame = next
        do { try redraw(next.image) } catch {
            (page, frame, cached) = previous
            if let image = previous.2?.image { BoardFileWriter.png(image, to: url) }
            throw error
        }
        return true
    }
    func undo() throws -> Bool {
        guard !page.marks.isEmpty, let image = original() else { return false }
        let previous = page
        page.marks.removeLast()
        if !page.markEvidence.isEmpty { page.markEvidence.removeLast() }
        do { try redraw(image); return true }
        catch { page = previous; throw error }
    }
    private func redraw(_ image: CGImage) throws {
        guard let output = page.images.first, let thumb = renderBoardMarked(image, strokes: page.marks, evidence: page.markEvidence, lineWidth: page.lineWidth, thumbnailHeight: 96)
        else { throw BoardStitchError.renderingFailed }
        BoardFileWriter.marked(image, page: page, to: output)
        page.thumb = thumb
    }
    /// Returns false if it cannot establish a safe mapping. No guessed scroll-wheel multiplier.
    func advance(to next: BoardScreenFeed.Frame, retainNewContent: Bool = true) throws -> Bool {
        guard next.scene == frame.scene, next.image.width == frame.image.width, next.image.height == frame.image.height else { return false }
        if frame.fingerprint.distance(to: next.fingerprint) < 0.001 { frame = next; return true }
        let down = BoardScrollStitcher.alignment(previous: frame.image, next: next.image)
        let up = BoardScrollStitcher.alignment(previous: next.image, next: frame.image)
        let candidates: [(BoardFrameAlignment, Int)] = [(down, 1), (up, -1)].compactMap { match, sign in
            guard let match, match.confidence >= 0.97, match.scrollDelta > 0, self.offset + sign * match.scrollDelta >= 0,
                  match.overlap >= next.image.height / 4 else { return nil }
            return (match, sign)
        }
        guard candidates.count < 2 || abs(candidates[0].0.confidence - candidates[1].0.confidence) > 0.002 else { return false }
        guard let (match, sign) = candidates.max(by: { $0.0.confidence < $1.0.confidence }) else { return false }
        // A mark on an unchanged, detailed toolbar/side panel is not document ink. Break the
        // chain rather than moving that mark with unrelated scrolling content.
        for stroke in viewportMarks {
            let visible = stroke.filter { $0.count == 2 && $0[1] >= 0 && $0[1] <= 1 }
            guard !visible.isEmpty else { continue }
            let xs = visible.map { $0[0] * Double(frame.image.width) }
            let ys = visible.map { $0[1] * Double(frame.image.height) }
            let region = CGRect(x: xs.min()! - 12, y: ys.min()! - 12,
                                width: max(32, xs.max()! - xs.min()! + 24), height: max(32, ys.max()! - ys.min()! + 24))
                .intersection(CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
            if let before = frame.image.cropping(to: region), let after = next.image.cropping(to: region),
               BoardGrayFrame(before).detailScore > 0.005,
               BoardFrameFingerprint(before).distance(to: BoardFrameFingerprint(after)) < 0.002 {
                return false
            }
        }
        let nextOffset = offset + sign * match.scrollDelta
        // Returning within the captured document is supported. Unknown content above its start starts a new page.
        guard nextOffset >= 0 else { return false }
        if retainNewContent && nextOffset > furthest {
            guard let original = page.original, let image = self.original() else { return false }
            let delta = nextOffset - furthest
            let overlap = next.image.height - delta
            guard overlap > next.image.height / 4 else { return false }
            let trim = max(page.footerTrim, match.trailingTrim)
            let keptHeight = image.height - (trim - page.footerTrim)
            // Do not silently clip marks on a pinned footer.
            guard page.marks.flatMap({ $0 }).allSatisfy({ $0[1] * Double(image.height) < Double(keptHeight) }) else { return false }
            let height = keptHeight + delta
            try BoardScrollStitcher.validateOutputSize(width: image.width, height: height)
            guard let head = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: keptHeight)) else { return false }
            let tail = try BoardScrollStitcher.newContentSegment(from: next.image, overlap: overlap, trailingTrim: trim)
            let combined = try BoardScrollStitcher.render(segments: [head, tail])
            let directory = original.deletingLastPathComponent(), id = UUID().uuidString
            let source = directory.appendingPathComponent("滚动原图-\(id).png")
            let result = directory.appendingPathComponent("长图原图-\(id).png")
            let output = directory.appendingPathComponent("长图标注-\(id).png")
            guard writePNG(next.image, to: source), writePNG(combined, to: result) else { throw BoardStitchError.renderingFailed }
            var new = page
            if new.components.isEmpty { new.components = [page]; new.componentOffsets = [0] }
            new.components.append(BoardSession.Page(images: [source], text: "", thumb: nil, original: source,
                                                     scene: page.scene, lineWidth: page.lineWidth, sourceFrames: [source]))
            new.componentOffsets.append(nextOffset)
            new.marks = page.marks.map { stroke in stroke.map { [$0[0], $0[1] * Double(image.height) / Double(height)] } }
            new.original = result; new.images = [output]; new.footerTrim = trim
            new.sourceFrames.append(source)
            new.retainedFiles = Array(Set(page.retainedFiles + page.components.flatMap { Array($0.allFiles) } + [source]))
            guard let marked = renderBoardMarked(combined, strokes: new.marks, evidence: new.markEvidence, lineWidth: new.lineWidth), writePNG(marked, to: output) else { throw BoardStitchError.renderingFailed }
            new.thumb = BoardSession.thumbnail(marked)
            // Keep component originals; obsolete intermediate composite canvases are safe to remove.
            if !page.components.isEmpty {
                (page.images + [original]).filter { !new.allFiles.contains($0) }.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            page = new; furthest = nextOffset
        }
        offset = nextOffset; frame = next
        return true
    }
}

final class BoardDragHandle: NSTextField {
    var onDrag: ((NSPoint) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { onDrag?(NSPoint(x: event.deltaX, y: -event.deltaY)) }
}
