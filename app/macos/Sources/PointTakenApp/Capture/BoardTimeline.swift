import AppKit
import PointTakenCore
import CoreText

/// Keeps only small visual signatures in memory. Unmarked visits never write screenshot files.
final class BoardTimeline {
    var evidence = BoardEvidence()
    private struct Candidate {
        var id: String
        var scene: String
        var title: String
        var fingerprint: BoardFrameFingerprint?
    }
    private var candidates: [Candidate] = []
    private var current: Int?
    private var visit: Int?
    var currentID: String? { current.map { candidates[$0].id } }

    func observe(_ frame: BoardScreenFeed.Frame, boundary: Bool, at time: BoardMoment) {
        observe(scene: frame.scene, app: frame.appName, title: frame.title,
                fingerprint: frame.fingerprint, boundary: boundary, at: time)
    }
    func observe(scene: String, app: String, title: String, fingerprint: BoardFrameFingerprint? = nil,
                 boundary: Bool = false, at time: BoardMoment) {
        let changed = current.map { candidates[$0].scene != scene || candidates[$0].title != title } ?? true
        let audioBegan = visit.map { evidence.visits[$0].start.audio == nil && time.audio != nil } ?? false
        if visit == nil || boundary || changed || audioBegan {
            close(at: time)
            // Require both window identity and a near-identical visual signature. A title alone
            // cannot prove that A → B → A returned to the same content.
            let matches = candidates.indices.filter { index in
                let c = candidates[index]
                guard c.scene == scene, c.title == title, let old = c.fingerprint, let fingerprint else { return false }
                return old.distance(to: fingerprint) < 0.002
            }
            let index: Int
            if audioBegan && !boundary && !changed, let current { index = current }
            else if matches.count == 1 { index = matches[0] }
            else {
                index = candidates.count
                candidates.append(Candidate(id: UUID().uuidString, scene: scene, title: title, fingerprint: fingerprint))
            }
            current = index
            evidence.visits.append(BoardVisit(pageID: candidates[index].id, app: app, title: title, start: time, end: time))
            visit = evidence.visits.count - 1
        } else if let visit { evidence.visits[visit].end = time }
    }
    func touch(at time: BoardMoment) {
        if let visit { evidence.visits[visit].end = time }
    }
    func anchor(_ frame: BoardScreenFeed.Frame) {
        if let current { candidates[current].fingerprint = frame.fingerprint }
    }
    func close(at time: BoardMoment) {
        if let visit { evidence.visits[visit].end = time }
        visit = nil
    }
}

enum BoardEvidenceExport {
    static func text(pages: [BoardSession.Page], transcript: String, evidence: BoardEvidence?, terminal: Bool = false) -> String {
        let selected = pages.filter(\.included).map {
            BoardReadablePage(images: $0.images, contextIDs: $0.contextIDs, marks: $0.markEvidence)
        }
        return BoardReadableExport.text(pages: selected, transcript: transcript, evidence: evidence, terminal: terminal)
    }
}

/// A number badge's diameter in image pixels for a page drawn with `lineWidth` pixel lines.
func boardBadgeDiameter(lineWidth: CGFloat) -> CGFloat { max(22, lineWidth * 6) }

/// Number badges use the same top-left normalized coordinates as the saved ink.
func renderBoardMarked(_ image: CGImage, strokes: [[[Double]]], evidence: [BoardMarkEvidence], lineWidth: CGFloat,
                       thumbnailHeight: Int? = nil) -> CGImage? {
    let scale = thumbnailHeight.map { min(1, CGFloat($0) / CGFloat(image.height)) } ?? 1
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    drawInk(in: context, size: CGSize(width: image.width, height: image.height), strokes: strokes, lineWidth: lineWidth)
    let diameter = boardBadgeDiameter(lineWidth: lineWidth)
    let size = CGSize(width: image.width, height: image.height)
    for (stroke, mark) in zip(strokes, evidence) {
        guard let center = BoardMarkSheet.badgeCenter(stroke, size: size, diameter: diameter) else { continue }
        let x = center.x, y = size.height - center.y            // the context's origin is bottom-left
        let rect = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
        context.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor); context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(max(1, lineWidth / 3)); context.strokeEllipse(in: rect)
        let string = NSAttributedString(string: String(mark.number), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.5, weight: .bold), .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: x - CGFloat(width) / 2, y: y - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }
    return context.makeImage()
}
