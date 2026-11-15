import AppKit

/// The note box that pops out beside a mark while marking up a picture full-size (like a screenshot tool's
/// callout): the mark's number, a field to type what to change, and what was said around it. Return starts a new
/// line (the box grows); ⌘Return, Esc or a click elsewhere closes it, and the words are kept (⌘Z takes them back).
final class BoardNotePopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let field = NSTextField()
    private let badge = BoardBadgeLabel()
    private let quote = NSTextField(wrappingLabelWithString: "")
    private var number = 0
    private var original = ""
    private var cancelled = false
    /// the mark's number and the words to keep
    var onCommit: ((Int, String) -> Void)?
    /// the trash button in the box: delete this mark
    var onDelete: ((Int) -> Void)?
    private let trash = NSButton()
    private let content = NSViewController()
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        let title = BoardStyle.label("说明", .headline, color: .labelColor)
        // A borderless field in a soft rounded well (like Notes / Reminders), not the system bezel whose thick
        // accent focus ring swallowed the whole popover.
        field.font = BoardStyle.font(.body)
        field.placeholderAttributedString = NSAttributedString(string: "这里要怎么改…", attributes: [
            .font: BoardStyle.font(.body), .foregroundColor: NSColor.placeholderTextColor])
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = self
        field.preferredMaxLayoutWidth = 264
        field.translatesAutoresizingMaskIntoConstraints = false
        let well = BoardFieldWell()
        well.addSubview(field)
        quote.font = BoardStyle.font(.subheadline)
        quote.textColor = .secondaryLabelColor
        quote.maximumNumberOfLines = 3
        quote.lineBreakMode = .byTruncatingTail
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除这个标记")
        trash.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        trash.isBordered = false
        trash.contentTintColor = .secondaryLabelColor
        trash.toolTip = "删除这个标记（可以 ⌘Z 撤销）"
        trash.target = self
        trash.action = #selector(deleteClicked)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [badge, title, gap, trash])
        head.spacing = BoardStyle.inner
        let stack = NSStackView(views: [head, well, quote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20), badge.heightAnchor.constraint(equalToConstant: 20),
            well.widthAnchor.constraint(equalToConstant: 280),
            well.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: well.topAnchor, constant: 7),
            field.bottomAnchor.constraint(lessThanOrEqualTo: well.bottomAnchor, constant: -7),
            quote.widthAnchor.constraint(equalTo: well.widthAnchor),
            head.widthAnchor.constraint(equalTo: well.widthAnchor),
        ])
        content.view = stack
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = !BoardMotion.reduced
        popover.delegate = self
    }

    /// Shows the box beside `rect` (in `view`), for mark `number`, with its note and the speech around it.
    func show(number: Int, note: String, said: String?, at rect: NSRect, in view: NSView) {
        if popover.isShown { popover.close() }
        self.number = number
        original = note
        cancelled = false
        badge.number = number
        field.stringValue = note
        quote.stringValue = said.map { "这时说的：" + $0 } ?? ""
        quote.isHidden = said == nil
        fit()
        popover.show(relativeTo: rect.insetBy(dx: -4, dy: -4), of: view, preferredEdge: .maxX)
        view.window?.makeFirstResponder(field)
        // caret at the end, not the whole note selected (a big accent-coloured block on open)
        field.currentEditor()?.selectedRange = NSRange(location: (note as NSString).length, length: 0)
    }
    func close() { popover.close() }
    @objc private func deleteClicked() {
        cancelled = true
        popover.close()
        onDelete?(number)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { popover.close() }   // ⌘Return: done
            else { textView.insertNewlineIgnoringFieldEditor(nil) }                               // Return: new line
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil); return true
        case #selector(NSResponder.cancelOperation(_:)):               // Esc: close, words kept
            popover.close(); return true
        default: return false
        }
    }
    /// the box grows with the note as lines are added
    func controlTextDidChange(_ obj: Notification) {
        field.validateEditing()
        field.invalidateIntrinsicContentSize()
        fit()
    }
    private func fit() {
        content.view.layoutSubtreeIfNeeded()
        let size = content.view.fittingSize
        if popover.contentSize != size { popover.contentSize = size }
    }
    func popoverWillClose(_ notification: Notification) {
        guard !cancelled, field.stringValue != original else { return }
        onCommit?(number, field.stringValue)
    }
}

/// The soft rounded fill behind the note field; re-resolves its colour when light/dark changes.
private final class BoardFieldWell: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}

/// A round button on glass that floats over the picture (the full-size markup toggle in its bottom-right corner).
final class BoardGlassButton: NSView {
    var onClick: (() -> Void)?
    private let button = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        var holder: NSView = button
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = button
            holder = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 22
            fx.layer?.masksToBounds = true
            fx.addSubview(button)
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: fx.leadingAnchor), button.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                         button.topAnchor.constraint(equalTo: fx.topAnchor), button.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
            holder = fx
        }
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holder)
        NSLayoutConstraint.activate([holder.leadingAnchor.constraint(equalTo: leadingAnchor), holder.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     holder.topAnchor.constraint(equalTo: topAnchor), holder.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 44),
                                     button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44)])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, tip: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
    }
    @objc private func clicked() { onClick?() }
}

/// ‹ 2 / 5 › on glass, under the picture while marking up full-size.
final class BoardPageSwitcher: NSView {
    var onStep: ((Int) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (b, symbol, tip, step) in [(previous, "chevron.left", "上一页（←）", -1), (next, "chevron.right", "下一页（→）", 1)] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.toolTip = tip
            b.tag = step
            b.target = self
            b.action = #selector(step(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        label.font = BoardStyle.digits(.body, .semibold)
        label.alignment = .center
        let row = NSStackView(views: [previous, label, next])
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        var holder: NSView = row
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 20
            glass.contentView = row
            holder = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 20
            fx.layer?.masksToBounds = true
            row.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(row)
            NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: fx.leadingAnchor), row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                         row.topAnchor.constraint(equalTo: fx.topAnchor), row.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
            holder = fx
        }
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holder)
        NSLayoutConstraint.activate([holder.leadingAnchor.constraint(equalTo: leadingAnchor), holder.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     holder.topAnchor.constraint(equalTo: topAnchor), holder.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(page: Int, of count: Int) {
        label.stringValue = "\(page + 1) / \(count)"
        previous.isEnabled = page > 0
        next.isEnabled = page + 1 < count
    }
    @objc private func step(_ sender: NSButton) { onStep?(sender.tag) }
}
