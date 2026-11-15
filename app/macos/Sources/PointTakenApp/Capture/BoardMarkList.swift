import AppKit
import PointTakenCore

/// The shown page's marks, one row each: the number (as on the picture), when it was drawn (or 补画), the sentence
/// said nearest to it, and a field for the note that goes to the AI with it. Selecting a row selects the mark on the
/// picture and the other way round; the window owns the marks, this list only shows them and reports edits.
final class BoardMarkList: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Row: Equatable {
        var number: Int
        /// 0:04, 补画 or 未记录
        var time: String
        /// the nearest sentence, quoted; nil when there is none
        var quote: String?
        var note: String
    }

    var onSelect: ((Int?) -> Void)?
    var onNote: ((Int, String) -> Void)?
    var onDelete: ((Int) -> Void)?
    var editable = true { didSet { table.reloadData() } }

    private(set) var rows: [Row] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private lazy var empty = BoardStyle.emptyState(symbol: "scribble.variable", title: emptyTitle, detail: emptyDetail)
    private var syncing = false
    private var showsPage = false
    private var reloading = false
    /// a note is being committed: a reload now would pull the field out from under its own end-of-editing
    private var committing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mark"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        // one card per mark (the row view draws it), a gap of 8 between cards
        table.rowHeight = BoardMarkCardRow.height
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        for v in [scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -BoardStyle.inner),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows these rows; `selected` is the mark selected on the picture. `page` false: no page is shown.
    func reload(_ rows: [Row], selected: Int?, page: Bool) {
        if committing {
            DispatchQueue.main.async { [weak self] in self?.reload(rows, selected: selected, page: page) }
            return
        }
        // nothing changed: keep the rows (and a note being typed in one of them)
        if rows == self.rows, page == showsPage { select(selected); return }
        let old = self.rows
        self.rows = rows
        let samePage = page == showsPage
        showsPage = page
        // a field losing the keyboard because its row is rebuilt is not the user finishing a note: its text is stale
        syncing = true; reloading = true
        if table.currentEditor() != nil { window?.makeFirstResponder(table) }
        // one card more or one fewer on the same page: that card slides in or fades out, the rest move aside
        if samePage, !BoardMotion.reduced, let change = Self.single(from: old, to: rows) {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.28
                c.timingFunction = BoardMotion.emphasized
                switch change {
                case .inserted(let i): table.insertRows(at: IndexSet(integer: i), withAnimation: [.slideDown, .effectFade])
                case .removed(let i): table.removeRows(at: IndexSet(integer: i), withAnimation: [.effectFade, .slideUp])
                }
            }
            // the other cards' words may have changed too (a note): refresh them in place
            let changed = IndexSet(rows.indices.filter { i in !old.contains(rows[i]) && { if case .inserted(let j) = change { return j != i }; return true }() })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        } else {
            table.reloadData()
        }
        syncing = false; reloading = false
        emptyTitle.stringValue = page ? "这一页还没有标记" : "没有选中的页面"
        emptyDetail.stringValue = page ? "用工具栏的画笔在图上画一笔，再在这里写说明" : "在左边选一页"
        empty.isHidden = !rows.isEmpty
        select(selected)
    }

    private enum Change { case inserted(Int), removed(Int) }
    /// `new` is `old` with exactly one row added or taken away (by mark number), and where.
    private static func single(from old: [Row], to new: [Row]) -> Change? {
        let a = old.map(\.number), b = new.map(\.number)
        if b.count == a.count + 1, let i = b.indices.first(where: { $0 >= a.count || a[$0] != b[$0] }) {
            var rest = b; rest.remove(at: i)
            return rest == a ? .inserted(i) : nil
        }
        if a.count == b.count + 1, let i = a.indices.first(where: { $0 >= b.count || a[$0] != b[$0] }) {
            var rest = a; rest.remove(at: i)
            return rest == b ? .removed(i) : nil
        }
        return nil
    }

    func select(_ number: Int?) {
        let row = number.flatMap { n in rows.firstIndex { $0.number == n } }
        guard row != (table.selectedRow >= 0 ? table.selectedRow : nil) else { return }
        syncing = true
        if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        else { table.deselectAll(nil) }
        syncing = false
    }

    /// Puts the keyboard in this mark's note (a mark just drawn: its note is the next thing to write).
    func focusNote(_ number: Int) {
        guard let row = rows.firstIndex(where: { $0.number == number }), let window, window.canBecomeKey else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? BoardMarkRowView else { return }
        window.makeFirstResponder(cell.noteField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = BoardMarkRowView()
        view.show(rows[row], editable: editable)
        view.noteField.delegate = self
        view.noteField.tag = rows[row].number
        view.deleteButton.tag = rows[row].number
        view.deleteButton.target = self
        view.deleteButton.action = #selector(deleteClicked(_:))
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { BoardMarkCardRow() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        onSelect?(table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].number : nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !reloading, let field = obj.object as? NSTextField else { return }
        committing = true
        onNote?(field.tag, field.stringValue)
        committing = false
    }

    @objc private func deleteClicked(_ sender: NSButton) { onDelete?(sender.tag) }
}

/// One mark as a card (the way Reminders lists its items): the number disc, the note written right in the card, one
/// quiet line under it — when it was drawn and the sentence said nearest — and a delete button that shows only when
/// the pointer is on the card or the card is selected.
///
///     ╭──────────────────────────────────────────────────────╮
///     │ (7)  按钮改成圆角                                 🗑 │
///     │      0:27  “开关的说明看不懂，改成一句话说清楚。”      │
///     ╰──────────────────────────────────────────────────────╯
final class BoardMarkRowView: NSTableCellView {
    let noteField = NSTextField()
    let deleteButton = NSButton()
    private let badge = BoardBadgeLabel()
    private let meta = NSTextField(labelWithString: "")
    private var hovering = false
    var selectedCard = false { didSet { updateDelete() } }
    private var editable = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        noteField.font = BoardStyle.font(.body)
        noteField.isBordered = false
        noteField.drawsBackground = false
        noteField.focusRingType = .none
        noteField.lineBreakMode = .byTruncatingTail
        noteField.cell?.sendsActionOnEndEditing = true
        noteField.cell?.usesSingleLineMode = true
        meta.font = BoardStyle.font(.subheadline)
        meta.lineBreakMode = .byTruncatingTail
        meta.maximumNumberOfLines = 1
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除这个标记")
        deleteButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .accessoryBarAction
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.toolTip = "删除这个标记（可以 ⌘Z 撤销）"
        deleteButton.isHidden = true
        for v in [badge, noteField, meta, deleteButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let s = BoardStyle.self, pad = BoardMarkCardRow.gap / 2
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s.group),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            noteField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: s.group - 2),
            noteField.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -s.inner),
            noteField.topAnchor.constraint(equalTo: topAnchor, constant: pad + 9),
            meta.leadingAnchor.constraint(equalTo: noteField.leadingAnchor, constant: 2),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: noteField.trailingAnchor),
            meta.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 2),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -s.inner),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: BoardStyle.hit),
            deleteButton.heightAnchor.constraint(equalToConstant: BoardStyle.hit),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateDelete() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateDelete() }
    private func updateDelete() { deleteButton.isHidden = !editable || !(hovering || selectedCard) }

    func show(_ row: BoardMarkList.Row, editable: Bool) {
        self.editable = editable
        badge.number = row.number
        noteField.stringValue = row.note
        noteField.isEditable = editable
        noteField.isSelectable = editable
        noteField.placeholderAttributedString = NSAttributedString(
            string: editable ? "添加说明…" : "录音结束后可以写说明",
            attributes: [.font: BoardStyle.font(.body), .foregroundColor: NSColor.tertiaryLabelColor])
        noteField.setAccessibilityLabel("标记 \(row.number) 的说明")
        // the quiet line: when, then what was said near it; a mark with neither a note nor speech says so, briefly
        let quiet: [NSAttributedString.Key: Any] = [.font: BoardStyle.font(.subheadline), .foregroundColor: NSColor.secondaryLabelColor]
        let line = NSMutableAttributedString(string: row.time,
                                             attributes: [.font: BoardStyle.digits(.subheadline), .foregroundColor: NSColor.secondaryLabelColor])
        if let quote = row.quote {
            line.append(NSAttributedString(string: "   " + quote, attributes: quiet))
        } else if row.note.isEmpty {
            var warn = quiet; warn[.foregroundColor] = NSColor.systemOrange
            line.append(NSAttributedString(string: " · ", attributes: quiet))
            line.append(NSAttributedString(string: "还没有说明", attributes: warn))
        }
        let oneLine = NSMutableParagraphStyle(); oneLine.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: oneLine, range: NSRange(location: 0, length: line.length))
        meta.attributedStringValue = line
        meta.toolTip = row.quote == nil && row.note.isEmpty ? "这个标记没有说明，画它的时候和前后几秒也没有说话：AI 只会看到编号" : row.quote
        updateDelete()
    }
}

/// Draws a mark's card: a rounded tile on the content background with a hairline edge; selected, tinted with the
/// accent colour (the text stays in its normal colours, so the card reads as chosen, not as a highlighted line).
final class BoardMarkCardRow: NSTableRowView {
    static let height: CGFloat = 70
    static let gap: CGFloat = BoardStyle.inner

    override var isSelected: Bool {
        didSet { (subviews.first { $0 is BoardMarkRowView } as? BoardMarkRowView)?.selectedCard = isSelected }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    private var card: NSRect { bounds.insetBy(dx: 0, dy: Self.gap / 2) }

    override func drawBackground(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: BoardStyle.cardRadius, yRadius: BoardStyle.cardRadius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: BoardStyle.cardRadius, yRadius: BoardStyle.cardRadius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// The black number disc, as drawn on the picture.
final class BoardBadgeLabel: NSView {
    var number = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
        let text = NSAttributedString(string: String(number), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: bounds.height * 0.5, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
