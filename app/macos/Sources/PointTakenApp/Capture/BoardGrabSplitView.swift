import AppKit

/// The divider between the picture and what was said, made findable without words: a short rounded grip in the
/// middle of it (the grabber of iOS sheets), darker while the pointer is over the divider, which also shows the
/// up-down resize cursor. A double-click on the divider asks for the automatic height back.
final class BoardGrabSplitView: NSSplitView {
    var onDoubleClick: (() -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { setNeedsDisplay(dividerRect) } } }

    static let grip = NSSize(width: 36, height: 4)
    /// full-size markup: no divider at all (the lower pane is put away)
    var hidesDivider = false { didSet { needsDisplay = true } }
    override var dividerThickness: CGFloat { hidesDivider ? 0 : 9 }

    /// the horizontal divider's rectangle (one divider: picture above, words below)
    var dividerRect: NSRect {
        guard subviews.count == 2 else { return .zero }
        let top = subviews[0].frame
        return NSRect(x: 0, y: top.maxY, width: bounds.width, height: dividerThickness)
    }

    override func drawDivider(in rect: NSRect) {
        guard !hidesDivider else { return }
        // the lower pane's own background, a hairline along the top, the grip in the middle
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        let g = Self.grip
        let grip = NSRect(x: (rect.midX - g.width / 2).rounded(), y: (rect.midY - g.height / 2 + 0.5).rounded(),
                          width: g.width, height: g.height)
        (hovering ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: grip, xRadius: g.height / 2, yRadius: g.height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["grip"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: dividerRect.insetBy(dx: 0, dy: -6),
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: ["grip": true]))
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateTrackingAreas()
    }
    override func adjustSubviews() {
        super.adjustSubviews()
        updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// the user let go of the divider after moving it (the lower pane's new height)
    var onDragged: ((CGFloat) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let onDivider = dividerRect.insetBy(dx: 0, dy: -6).contains(p)
        if event.clickCount == 2, onDivider { onDoubleClick?(); return }
        let before = subviews.count == 2 ? subviews[1].frame.height : 0
        super.mouseDown(with: event)          // AppKit runs the whole drag here
        updateTrackingAreas()
        if onDivider, subviews.count == 2, abs(subviews[1].frame.height - before) >= 1 { onDragged?(subviews[1].frame.height) }
    }
}
