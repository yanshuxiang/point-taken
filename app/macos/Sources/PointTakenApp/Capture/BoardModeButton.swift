import AppKit

/// One choice in the lower pane's left column (标记 / 按时间 / 全文): a symbol and a short word, the chosen one on a
/// rounded fill the way a sidebar marks its selected row. Stacked vertically, they take no row above the content.
final class BoardModeButton: NSButton {
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; style() } } }
    static let height: CGFloat = 34

    convenience init(title: String, symbol: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        isBordered = false
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        style()
    }

    private func style() {
        let color: NSColor = isOn ? .labelColor : .secondaryLabelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BoardStyle.font(.body, isOn ? .semibold : .regular), .foregroundColor: color])
        contentTintColor = isOn ? .controlAccentColor : .secondaryLabelColor
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: isOn ? .semibold : .regular)
        setAccessibilityValue(isOn ? "已选中" : nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        // the title and symbol, inset from the rounded edge
        let saved = bounds
        cell?.draw(withFrame: saved.insetBy(dx: BoardStyle.inner, dy: 0), in: self)
    }
}
