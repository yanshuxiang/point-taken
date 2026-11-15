import AppKit

/// A column of icon buttons on one glass capsule, floating at the picture's left in the review window: the drawing
/// tools (one chosen at a time) or undo / redo. Kept off the toolbar so the window's top stays uncluttered.
final class BoardSideTools: NSView {
    static let width: CGFloat = 44
    /// a button was pressed (its index)
    var onPick: ((Int) -> Void)?
    private(set) var buttons: [Button] = []
    private let selects: Bool

    /// `selects`: one button stays chosen (the tools); otherwise each press is momentary (undo / redo).
    init(items: [(symbol: String, tip: String)], selects: Bool) {
        self.selects = selects
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for (i, item) in items.enumerated() {
            let b = Button()
            b.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tip)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.imagePosition = .imageOnly
            b.toolTip = item.tip
            b.setAccessibilityLabel(item.tip)
            b.tag = i
            b.target = self
            b.action = #selector(pressed(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: Self.width - 8),
                                         b.heightAnchor.constraint(equalToConstant: 36)])
            stack.addArrangedSubview(b)
            buttons.append(b)
        }
        var holder: NSView = stack
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.width / 2
            glass.contentView = stack
            holder = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = Self.width / 2
            fx.layer?.masksToBounds = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                         stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
            holder = fx
        }
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holder)
        NSLayoutConstraint.activate([holder.leadingAnchor.constraint(equalTo: leadingAnchor), holder.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     holder.topAnchor.constraint(equalTo: topAnchor), holder.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     widthAnchor.constraint(equalToConstant: Self.width)])
        if selects { selectedIndex = 0 }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// the chosen button (tools only)
    var selectedIndex = -1 {
        didSet { for b in buttons { b.chosen = b.tag == selectedIndex } }
    }
    @objc private func pressed(_ sender: NSButton) {
        if selects { selectedIndex = sender.tag }
        onPick?(sender.tag)
    }

    /// An icon button that shows a soft rounded fill while chosen.
    final class Button: NSButton {
        var chosen = false { didSet { needsDisplay = true; contentTintColor = chosen ? .controlAccentColor : nil } }
        override func draw(_ dirtyRect: NSRect) {
            if chosen {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
            }
            super.draw(dirtyRect)
        }
    }
}
