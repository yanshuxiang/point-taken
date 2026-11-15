import AppKit

/// The pages while marking up full-size: a glass panel that floats over the picture's left side, hidden until the
/// pointer touches the window's left edge (like a full-screen app's sidebar), gone again soon after the pointer
/// leaves it. One thumbnail per page with its number; the page shown is highlighted; a click shows that page.
final class BoardPageStrip: NSView {
    static let width: CGFloat = 176
    var onPick: ((Int) -> Void)?
    /// the pointer left the panel (the window hides it after a moment unless it comes back)
    var onLeave: (() -> Void)?
    var onEnter: (() -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var items: [BoardStripItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = BoardStyle.inner
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        let document = BoardFlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        var holder: NSView = scroll
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = scroll
            holder = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 18
            fx.layer?.masksToBounds = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(scroll)
            NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                         scroll.topAnchor.constraint(equalTo: fx.topAnchor), scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
            holder = fx
        }
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holder)
        NSLayoutConstraint.activate([holder.leadingAnchor.constraint(equalTo: leadingAnchor), holder.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     holder.topAnchor.constraint(equalTo: topAnchor), holder.bottomAnchor.constraint(equalTo: bottomAnchor)])
        wantsLayer = true
        shadow = {
            let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.22); s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -4); return s
        }()
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ thumbs: [CGImage?], selected: Int?) {
        items.forEach { $0.removeFromSuperview() }
        items = thumbs.enumerated().map { i, thumb in
            let item = BoardStripItem(number: i + 1, thumb: thumb)
            item.target = self
            item.action = #selector(picked(_:))
            item.tag = i
            return item
        }
        stack.setViews(items, in: .top)
        items.forEach { $0.widthAnchor.constraint(equalToConstant: Self.width - 20).isActive = true }
        select(selected)
    }
    func select(_ index: Int?) {
        for (i, item) in items.enumerated() { item.isOn = i == index }
        if let index, items.indices.contains(index) { items[index].scrollToVisible(items[index].bounds) }
    }
    @objc private func picked(_ sender: NSButton) { onPick?(sender.tag) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onLeave?() }
}

/// One page in the strip: its thumbnail, 第 N 页 under it; the page shown on a soft highlight.
private final class BoardStripItem: NSButton {
    var isOn = false { didSet { needsDisplay = true; caption.textColor = isOn ? .labelColor : .secondaryLabelColor } }
    private let picture = NSImageView()
    private let caption: NSTextField

    init(number: Int, thumb: CGImage?) {
        caption = BoardStyle.label("第 \(number) 页", .callout, .medium, color: .secondaryLabelColor)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        picture.image = thumb.map { NSImage(cgImage: $0, size: .zero) }
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = BoardStyle.thumbRadius
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 1
        picture.layer?.borderColor = NSColor.separatorColor.cgColor
        for v in [picture, caption] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 10.0 / 16.0),
            caption.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityLabel("第 \(number) 页")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isOn else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        ring.lineWidth = 2
        ring.stroke()
    }
}

/// An invisible strip along the window's left edge while marking up full-size: touching it brings the pages out.
/// It never takes clicks (drawing right at the edge still works) — only the pointer's arrival is watched.
final class BoardEdgeSensor: NSView {
    var onTouch: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onTouch?() }
}
