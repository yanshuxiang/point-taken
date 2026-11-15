// How a pen stroke is drawn, shared by the live ink and the mark canvas.
import AppKit
import PointTakenCore

/// A stroke's path, as every renderer draws it: through the midpoints (smooth without lagging behind the hand; a doubled
/// point is a sharp corner), a single point as a ring of radius `ring`.
func inkPath(_ p: [CGPoint], ring: CGFloat) -> CGPath {
    let m = CGMutablePath()
    guard let f = p.first else { return m }
    if p.count == 1 { m.addEllipse(in: CGRect(x: f.x - ring, y: f.y - ring, width: ring * 2, height: ring * 2)); return m }
    m.move(to: f)
    if p.count > 2 {
        for i in 1..<(p.count - 1) {
            m.addQuadCurve(to: CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2), control: p[i])
        }
    }
    m.addLine(to: p[p.count - 1])
    return m
}

/// Sets a stroke's path and its shadow's outline together. A shadow without a `shadowPath` makes Core Animation render
/// the layer off screen to find its shape — on the full-screen pen layer, on every move of the pen (the lag felt while
/// drawing); with the stroked outline given, the shadow is drawn straight from it.
func inkSetPath(_ l: CAShapeLayer, _ path: CGPath) {
    l.path = path
    l.shadowPath = path.copy(strokingWithWidth: l.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// The pen's look on a layer: the markup colour, round ends, a soft dark shadow (reads on light and dark pages).
func styleInk(_ l: CAShapeLayer, width: CGFloat) {
    l.fillColor = nil
    l.strokeColor = BrandColor.Island.markup.cgColor      // BrandColor.markup: one value light and dark
    l.lineWidth = width
    l.lineCap = .round
    l.lineJoin = .round
    l.shadowColor = NSColor.black.cgColor
    l.shadowOpacity = 0.45
    l.shadowRadius = max(1.2, width * 0.4)
    l.shadowOffset = .zero
}

/// The line width for a display (InkStyle: wider on a bigger one).
func inkWidth(for screen: NSScreen?) -> CGFloat {
    let s = (screen ?? NSScreen.main)?.frame.size ?? CGSize(width: 1512, height: 982)
    return InkStyle.width(screenShortSide: min(s.width, s.height))
}


/// Burns the user's strokes (normalized 0–1 point lists) into a copy of the shot → NNN.marked.png.
func renderMarked(_ img: CGImage, strokes: [[[Double]]], lineWidthPx: CGFloat) -> CGImage? {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    drawInk(in: ctx, size: CGSize(width: w, height: h), strokes: strokes, lineWidth: lineWidthPx)
    return ctx.makeImage()
}

/// Draw into an existing image buffer so numbered annotations need only one full-size canvas.
func drawInk(in ctx: CGContext, size: CGSize, strokes: [[[Double]]], lineWidth lineWidthPx: CGFloat) {
    let w = size.width, h = size.height
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidthPx)
    ctx.setStrokeColor(BrandColor.markup.cgColor)        // the pen (same value light and dark)
    ctx.setShadow(offset: .zero, blur: lineWidthPx * 0.4, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    for s in strokes where !s.isEmpty {
        let pts = s.map { CGPoint(x: CGFloat($0[0]) * CGFloat(w), y: (1 - CGFloat($0[1])) * CGFloat(h)) }
        if pts.count == 1 {
            let r = lineWidthPx * 4.5
            ctx.strokeEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            continue
        }
        ctx.beginPath()
        ctx.move(to: pts[0])
        for i in 1..<pts.count - 1 {
            ctx.addQuadCurve(to: CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2), control: pts[i])
        }
        ctx.addLine(to: pts[pts.count - 1])
        ctx.strokePath()
    }
}
