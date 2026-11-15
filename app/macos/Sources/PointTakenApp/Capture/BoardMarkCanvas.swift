import AppKit
import PointTakenCore

/// The review window's drawing surface, laid exactly over a page's picture: every mark with its number badge, the
/// selected one highlighted. Two kinds of tool:
/// - 选择 (the default): a click on a mark (its line or its badge) selects it, ⌫ deletes it, Esc lets go; a drag on
///   empty space pans the picture, as does space-drag with any tool.
/// - a pen shape (自由画 / 矩形 / 圆圈): a drag draws one mark. A plain click draws nothing here (in the review a stray
///   click must never become a numbered mark).
/// The canvas only shows the sheet and reports what the user did; the window owns the pages and the undo.
final class BoardMarkCanvas: NSView {
    enum Tool: Equatable { case select, pen(InkTool) }

    var tool: Tool = .select {
        didSet { stroke = nil; window?.invalidateCursorRects(for: self); needsDisplay = true }
    }
    var sheet = BoardMarkSheet(strokes: [], evidence: [], firstFree: 1) {
        didSet {
            if let s = selected, sheet.index(of: s) == nil { selected = nil }
            needsDisplay = true
        }
    }
    /// the selected mark's number
    var selected: Int? {
        didSet { if oldValue != selected { needsDisplay = true; onSelect?(selected) } }
    }
    /// line width and badge size in this view's points (the page's, scaled to the picture as shown)
    var lineWidth: CGFloat = 4 { didSet { needsDisplay = true } }
    var badgeDiameter: CGFloat = 20 { didSet { needsDisplay = true } }
    var acceptsInk = true

    /// a finished stroke, normalized 0–1 (top-left origin)
    var onDraw: (([[Double]]) -> Void)?
    var onSelect: ((Int?) -> Void)?
    var onDelete: ((Int) -> Void)?
    /// Esc with nothing selected: back to the select tool
    var onEscape: (() -> Void)?
    /// ← / → (no modifiers): the page before or after (−1 / +1)
    var onArrow: ((Int) -> Void)?
    /// a double-click on the picture where there is no mark
    var onEmptyDoubleClick: (() -> Void)?

    /// Where a mark is drawn, in this view (its line and its number badge), for placing things beside it.
    func rect(of number: Int) -> NSRect? {
        guard let i = sheet.index(of: number) else { return nil }
        let mark = sheet.marks[i]
        let pts = points(mark.points)
        guard let first = pts.first else { return nil }
        var r = pts.dropFirst().reduce(NSRect(origin: first, size: .zero)) { $0.union(NSRect(origin: $1, size: .zero)) }
        if pts.count == 1 { r = r.insetBy(dx: -18, dy: -18) }
        if let c = BoardMarkSheet.badgeCenter(mark.points, size: bounds.size, diameter: badgeDiameter) {
            r = r.union(NSRect(x: c.x - badgeDiameter / 2, y: c.y - badgeDiameter / 2, width: badgeDiameter, height: badgeDiameter))
        }
        return r.insetBy(dx: -lineWidth, dy: -lineWidth)
    }

    private var stroke: InkStroke?
    private var panFrom: NSPoint?
    private var spaceDown = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var drawing: Bool { stroke != nil }
    private var selecting: Bool { tool == .select }

    // MARK: drawing

    private func points(_ normalized: [[Double]]) -> [CGPoint] {
        normalized.filter { $0.count == 2 }.map { CGPoint(x: CGFloat($0[0]) * bounds.width, y: CGFloat($0[1]) * bounds.height) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for mark in sheet.marks {
            let path = inkPath(points(mark.points), ring: 18)
            if mark.evidence.number == selected {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(lineWidth + 10)
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor)
                ctx.strokePath()
                ctx.restoreGState()
            }
            ink(path, in: ctx)
        }
        if let stroke { ink(inkPath(stroke.display, ring: 18), in: ctx) }
        for mark in sheet.marks { badge(mark, in: ctx) }
    }

    private func ink(_ path: CGPath, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(BrandColor.markup.cgColor)
        ctx.setShadow(offset: .zero, blur: max(1.2, lineWidth * 0.4), color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func badge(_ mark: BoardMarkSheet.Mark, in ctx: CGContext) {
        let d = badgeDiameter
        guard let c = BoardMarkSheet.badgeCenter(mark.points, size: bounds.size, diameter: d) else { return }
        let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        let chosen = mark.evidence.number == selected
        ctx.saveGState()
        ctx.setFillColor((chosen ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.88)).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
        ctx.restoreGState()
        let text = NSAttributedString(string: String(mark.evidence.number), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: d * 0.5, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
    }

    /// the mark under a point of this view
    func mark(at p: CGPoint) -> Int? {
        sheet.hit(p, size: bounds.size, tolerance: max(6, lineWidth / 2 + 4), ring: 18, badge: badgeDiameter)
    }

    // MARK: the mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selecting ? .arrow : .crosshair)
    }

    override func mouseDown(with e: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let p = convert(e.locationInWindow, from: nil)
        if spaceDown || selecting {
            if !spaceDown, let hit = mark(at: p) {
                if selected == hit { onSelect?(hit) } else { selected = hit }   // a click on the chosen mark asks again
                return
            }
            if !spaceDown, e.clickCount == 2 { onEmptyDoubleClick?(); return }
            if !spaceDown { selected = nil }
            panFrom = e.locationInWindow
            NSCursor.closedHand.push()
            return
        }
        guard acceptsInk, case .pen(let shape) = tool else { return }
        selected = nil
        stroke = InkStroke(at: p, tool: shape)
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if let from = panFrom {
            pan(by: NSPoint(x: e.locationInWindow.x - from.x, y: e.locationInWindow.y - from.y))
            panFrom = e.locationInWindow
            return
        }
        guard let stroke, case .pen(let shape) = tool else { return }
        if stroke.move(to: convert(e.locationInWindow, from: nil), tool: shape) { needsDisplay = true }
    }

    override func mouseUp(with e: NSEvent) {
        if panFrom != nil { panFrom = nil; NSCursor.pop(); return }
        guard let stroke else { return }
        self.stroke = nil
        needsDisplay = true
        guard Self.isMark(stroke.display) else { return }
        let kept = stroke.kept(minGap: 2)
        guard kept.count > 1, bounds.width > 0, bounds.height > 0 else { return }
        onDraw?(kept.map { [Double(min(max(0, $0.x), bounds.width) / bounds.width),
                             Double(min(max(0, $0.y), bounds.height) / bounds.height)] })
    }

    /// A click (or a twitch of a few points) is not a mark here.
    static func isMark(_ shown: [CGPoint]) -> Bool {
        let xs = shown.map(\.x), ys = shown.map(\.y)
        let extent = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        return shown.count > 1 && extent >= 4
    }

    /// Moves the picture under the pointer (a drag of `delta` window points).
    private func pan(by delta: NSPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let m = max(scroll.magnification, 0.01)
        var origin = clip.bounds.origin
        origin.x -= delta.x / m
        origin.y += delta.y / m * (clip.isFlipped ? 1 : -1)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: the keyboard

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(e.keyCode) {
        case 49 where mods.isEmpty:                         // space: hold to pan
            if !spaceDown { spaceDown = true; NSCursor.openHand.push() }
        case 51, 117 where mods.isEmpty:                    // ⌫ / ⌦: delete the selected mark
            if let selected { onDelete?(selected) } else { super.keyDown(with: e) }
        case 123 where mods.isEmpty: onArrow?(-1)          // ←
        case 124 where mods.isEmpty: onArrow?(1)           // →
        case 53:                                            // Esc
            if selected != nil { selected = nil } else { onEscape?() }
        default:
            super.keyDown(with: e)
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49, spaceDown { spaceDown = false; NSCursor.pop() } else { super.keyUp(with: e) }
    }

    override func resignFirstResponder() -> Bool {
        if spaceDown { spaceDown = false; NSCursor.pop() }
        return super.resignFirstResponder()
    }
}
