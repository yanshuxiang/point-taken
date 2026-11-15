import AppKit
import AVFoundation
import PointTakenCore

/// One past recording as the history list shows it: when, how long, its first page, what was said first.
private struct BoardHistoryEntry {
    let directory: URL
    let date: Date?
    let duration: Double?
    let pages: Int
    let firstImage: URL?
    let preview: String
    let hasAudio: Bool

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return f
    }()

    init(_ directory: URL) {
        self.directory = directory
        date = Self.nameFormat.date(from: directory.lastPathComponent)
        let audio = directory.appendingPathComponent("原始录音.wav")
        hasAudio = FileManager.default.fileExists(atPath: audio.path)
        if hasAudio, let file = try? AVAudioFile(forReading: audio), file.fileFormat.sampleRate > 0 {
            duration = Double(file.length) / file.fileFormat.sampleRate
        } else {
            duration = BoardEvidence.load(directory)?.speech.map(\.end).max()
        }
        // only what the row shows: how many pages, and the first one's picture (no image is decoded here)
        let rows = (try? Data(contentsOf: directory.appendingPathComponent("页面.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let firsts = rows.compactMap { ($0["images"] as? [String])?.first }
            .map { directory.appendingPathComponent(($0 as NSString).lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        pages = firsts.count
        firstImage = firsts.first
        let text = BoardDeliveryTranscript.load(from: directory)
        preview = String(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}

/// A history row: the first page (or a waveform when there is none), the time and length, the first words said,
/// what it holds; the record's actions as buttons along its trailing edge (打开, 播放, 重新转写, 在访达中显示,
/// 移到废纸篓), each a full-size target. One click on the row opens the record too; right-click gives the same list.
private final class BoardHistoryRow: NSTableCellView {
    struct Action {
        let title: String
        let symbol: String
        let run: () -> Void
    }
    /// selecting: a checkbox in front of the row, ticked when the record is picked
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let picture = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let length = NSTextField(labelWithString: "")
    private let said = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let bar = NSStackView()
    private var pictureLeading: NSLayoutConstraint!
    private var onCheck: ((Bool) -> Void)?
    private var actions: [Action] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        check.setAccessibilityLabel("选择这条记录")
        check.target = self
        check.action = #selector(checked)
        picture.wantsLayer = true
        picture.layer?.cornerRadius = BoardStyle.thumbRadius
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 1
        picture.layer?.borderColor = NSColor.separatorColor.cgColor
        picture.imageScaling = .scaleProportionallyUpOrDown
        title.font = BoardStyle.font(.title3, .semibold)
        length.font = BoardStyle.digits(.body)
        length.textColor = .secondaryLabelColor
        said.font = BoardStyle.font(.body)
        said.maximumNumberOfLines = 2
        said.lineBreakMode = .byTruncatingTail
        said.cell?.truncatesLastVisibleLine = true
        said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.font = BoardStyle.font(.subheadline)
        bar.spacing = 2
        for view in [check, picture, title, length, said, meta, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        pictureLeading = picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: BoardStyle.hit),
            check.heightAnchor.constraint(equalToConstant: BoardStyle.hit),
            pictureLeading,
            picture.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 112),
            picture.heightAnchor.constraint(equalToConstant: 70),
            title.leadingAnchor.constraint(equalTo: picture.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: picture.topAnchor, constant: -2),
            length.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            length.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            said.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            said.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            said.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -12),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.bottomAnchor.constraint(equalTo: picture.bottomAnchor, constant: 1),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    func configure(_ entry: BoardHistoryEntry, thumb: NSImage?, busy: Bool, actions: [Action], selecting: Bool,
                   picked: Bool, onCheck: @escaping (Bool) -> Void) {
        self.onCheck = onCheck
        self.actions = actions
        check.isHidden = !selecting
        check.state = picked ? .on : .off
        pictureLeading.constant = selecting ? 38 : 8
        picture.image = thumb ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "只有录音")
        picture.symbolConfiguration = thumb == nil ? NSImage.SymbolConfiguration(pointSize: 20, weight: .regular) : nil
        picture.contentTintColor = thumb == nil ? .tertiaryLabelColor : nil
        picture.layer?.backgroundColor = thumb == nil ? NSColor.labelColor.withAlphaComponent(0.04).cgColor : nil
        title.stringValue = entry.date.map(Self.time) ?? entry.directory.lastPathComponent
        length.stringValue = entry.duration.map(boardClock) ?? ""
        said.stringValue = entry.preview.isEmpty ? "没有识别出文字" : entry.preview
        said.textColor = entry.preview.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        var facts = [entry.pages > 0 ? "\(entry.pages) 张截图" : "没有截图", entry.hasAudio ? "有录音" : "没有录音"]
        if busy { facts.append("正在重新转写…") }
        meta.stringValue = facts.joined(separator: " · ")
        meta.textColor = busy ? .controlAccentColor : .tertiaryLabelColor
        while bar.arrangedSubviews.count < actions.count {
            let button = NSButton(title: "", target: self, action: #selector(act(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: BoardStyle.hit + 4).isActive = true
            button.heightAnchor.constraint(equalToConstant: BoardStyle.hit + 4).isActive = true
            bar.addArrangedSubview(button)
        }
        for (index, view) in bar.arrangedSubviews.enumerated() {
            view.isHidden = !actions.indices.contains(index)
            guard let button = view as? NSButton, actions.indices.contains(index) else { continue }
            let action = actions[index]
            button.tag = index
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            button.toolTip = action.title
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func checked() { onCheck?(check.state == .on) }
    @objc private func act(_ sender: NSButton) { if actions.indices.contains(sender.tag) { actions[sender.tag].run() } }

    /// 23:53 (the day is the section's)
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// Archives have no expiry. Only an explicit user action moves a session into the system Trash.
/// The window lists every record by day (newest first), each with what it holds; one click opens it in the review
/// window (检查内容), where its pages, timeline and text can be edited again. Its actions (play, transcribe again,
/// show in Finder, move to Trash) are on each row's ⋯ menu and its right-click menu; a search field filters by
/// what was said.
final class BoardHistoryWindow: NSObject, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate,
                                NSToolbarDelegate {
    static let shared = BoardHistoryWindow()
    static var root: URL { PointTaken.records }
    private var window: NSWindow?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "还没有记录")
    private let search = NSSearchField()
    private var entries: [BoardHistoryEntry] = []
    /// the table's rows: a day header or an entry
    private enum Row { case day(String), entry(Int) }
    private var rows: [Row] = []
    private let thumbs: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var transcribing: Set<URL> = []
    private var player: AVPlayer?
    private var playingFile: URL?
    private var playbackObservation: NSKeyValueObservation?
    private var playbackEnd: NSObjectProtocol?
    private enum ID {
        static let search = NSToolbarItem.Identifier("board.history.search")
        static let select = NSToolbarItem.Identifier("board.history.select")
        static let all = NSToolbarItem.Identifier("board.history.all")
        static let trash = NSToolbarItem.Identifier("board.history.trash")
    }
    /// choosing records to move to the Trash together (a click ticks a record instead of opening it)
    private var selecting = false
    private var picked: Set<URL> = []
    private let selectButton = NSButton(title: "选择", target: nil, action: nil)
    private let allButton = NSButton(title: "全选", target: nil, action: nil)
    private let trashButton = NSButton(title: "移到废纸篓", target: nil, action: nil)
    private var statusToken = 0

    func show() {
        guard !BoardSession.shared.active else { return }
        if window == nil { build() }
        reload()
        BoardHome.prepareForDisplay()
        window?.center()
        if let window { presentWindow(window) }
    }
    private func build() {
        let size = NSSize(width: 720, height: 600)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "历史记录"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 560, height: 400)
        w.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "board.history")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        w.toolbar = toolbar

        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(clicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.autoresizingMask = [.width, .height]
        table.frame = NSRect(origin: .zero, size: scroll.contentSize)
        column.width = scroll.contentSize.width
        table.sizeLastColumnToFit()
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(scroll)
        empty.font = .systemFont(ofSize: 15, weight: .medium)
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                                     empty.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
        w.contentView = root
        window = w
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.all, ID.trash, .flexibleSpace, ID.select, ID.search]
    }
    /// 全选 and 移到废纸篓 show only while choosing records. The whole toolbar item is hidden, not just its button:
    /// on the current system a toolbar item keeps its glass background even with its button hidden.
    private var selectionItems: [NSToolbarItem] = []
    private func hideUntilSelecting(_ item: NSToolbarItem, _ button: NSButton) {
        selectionItems.append(item)
        if #available(macOS 15.0, *) { item.isHidden = !selecting } else { button.isHidden = !selecting }
    }
    private func setSelectionItemsShown(_ shown: Bool) {
        if #available(macOS 15.0, *) { selectionItems.forEach { $0.isHidden = !shown } }
        else { allButton.isHidden = !shown; trashButton.isHidden = !shown }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ b: NSButton, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            b.bezelStyle = .push
            b.target = self; b.action = action; b.toolTip = tip
            item.view = b; item.label = b.title
            return item
        }
        switch id {
        case ID.select: return button(selectButton, #selector(toggleSelecting), "选择多条记录，一起移到废纸篓")
        case ID.all:
            let item = button(allButton, #selector(pickAll), "选中全部记录")
            hideUntilSelecting(item, allButton)
            return item
        case ID.trash:
            trashButton.hasDestructiveAction = true
            let item = button(trashButton, #selector(trashPicked), "把选中的记录移到废纸篓")
            hideUntilSelecting(item, trashButton)
            return item
        default: break
        }
        guard id == ID.search else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: id)
        item.searchField = search
        search.placeholderString = "搜索说过的话"
        search.delegate = self
        search.target = self
        search.action = #selector(filter)
        return item
    }

    private var loading = 0
    /// Reads the records off the main thread (each one's audio header, pages and text), then shows them.
    private func reload(wait: Bool = false) {
        loading += 1
        let token = loading
        let work = {
            let dirs = ((try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            return dirs.map(BoardHistoryEntry.init)
        }
        if wait { entries = work(); filter(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = work()
            DispatchQueue.main.async {
                guard let self, token == self.loading else { return }
                self.entries = loaded
                self.filter()
            }
        }
    }
    private var filterTask: DispatchWorkItem?
    private var filterVersion = 0
    private let searchQueue = DispatchQueue(label: "pointtaken.board.history-search", qos: .userInitiated)
    @objc private func filter() {
        filterVersion += 1
        let version = filterVersion
        filterTask?.cancel()
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let snapshot = entries
        guard !query.isEmpty else { showRows(Array(snapshot.indices)); return }
        // Keep the whole recording searchable without retaining every complete transcript in the window.
        let work = DispatchWorkItem { [weak self] in
            var matches: [Int] = []
            for (index, entry) in snapshot.enumerated() {
                let text = BoardDeliveryTranscript.load(from: entry.directory).replacingOccurrences(of: "\n", with: " ")
                if text.localizedCaseInsensitiveContains(query) { matches.append(index) }
            }
            DispatchQueue.main.async {
                guard let self, self.filterVersion == version else { return }
                self.showRows(matches)
            }
        }
        filterTask = work
        searchQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func showRows(_ matches: [Int]) {
        rows = []
        var day = ""
        for i in matches where entries.indices.contains(i) {
            let d = entries[i].date.map(Self.day) ?? "更早"
            if d != day { rows.append(.day(d)); day = d }
            rows.append(.entry(i))
        }
        table.reloadData()
        empty.stringValue = entries.isEmpty ? "还没有记录" : "没有找到"
        empty.isHidden = !rows.isEmpty
        status(nil)
    }
    func windowWillClose(_ notification: Notification) {
        loading += 1
        filterVersion += 1
        filterTask?.cancel()
        filterTask = nil
        stopPlayback()
        thumbs.removeAllObjects()
        entries.removeAll()
        rows.removeAll()
        table.reloadData()
    }
    /// What just happened, under the title for a few seconds; nothing there at rest.
    private func status(_ text: String?) {
        statusToken += 1
        let token = statusToken
        window?.subtitle = text ?? ""
        guard text != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, token == self.statusToken else { return }
            self.window?.subtitle = ""
        }
    }

    // MARK: choosing several

    @objc private func toggleSelecting() {
        selecting.toggle()
        picked = []
        selectButton.title = selecting ? "完成" : "选择"
        setSelectionItemsShown(selecting)
        updatePicked()
        table.reloadData()
    }
    @objc private func pickAll() {
        let shown = rows.compactMap { row -> URL? in if case .entry(let i) = row { return entries[i].directory }; return nil }
        picked = picked.count == shown.count ? [] : Set(shown)
        updatePicked()
        table.reloadData()
    }
    private func toggle(_ dir: URL, _ on: Bool) {
        if on { picked.insert(dir) } else { picked.remove(dir) }
        updatePicked()
    }
    /// the title says how many are chosen; the buttons follow
    private func updatePicked() {
        window?.title = selecting ? (picked.isEmpty ? "选择记录" : "已选择 \(picked.count) 条") : "历史记录"
        trashButton.isEnabled = !picked.isEmpty
        trashButton.title = picked.isEmpty ? "移到废纸篓" : "移到废纸篓（\(picked.count)）"
        let shown = rows.filter { if case .entry = $0 { return true }; return false }.count
        allButton.title = !shown.isMultiple(of: 1) || picked.count < shown || shown == 0 ? "全选" : "取消全选"
    }
    @objc private func trashPicked() {
        guard !picked.isEmpty, let window else { return }
        let ask = NSAlert()
        ask.messageText = "把 \(picked.count) 条记录移到废纸篓？"
        ask.informativeText = "录音、截图和文字会一起移走。需要时可以在访达的废纸篓里恢复。"
        ask.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
        ask.addButton(withTitle: "取消")
        ask.beginSheetModal(for: window) { [weak self] answer in
            guard let self, answer == .alertFirstButtonReturn else { return }
            var moved = 0, kept = 0
            for dir in self.picked {
                guard !self.transcribing.contains(dir), !BoardSession.shared.isReviewing(dir) else { kept += 1; continue }
                if (try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)) != nil { moved += 1 } else { kept += 1 }
            }
            self.picked = []
            self.selecting = true
            self.toggleSelecting()           // back to the list
            self.reload()
            self.status(kept == 0 ? "已把 \(moved) 条记录移到废纸篓" : "已移走 \(moved) 条；\(kept) 条正在使用或删除失败，保留了")
        }
    }
    /// 今天 / 昨天 / 11月12日 周三 (/ 2025年11月12日)
    private static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 EEE" : "yyyy年M月d日 EEE"
        return f.string(from: d)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .day = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .day = rows[row] { return 30 }; return 94 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .day = rows[row] { return false }; return true }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .day(let d):
            let identifier = NSUserInterfaceItemIdentifier("history.day")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = BoardStyle.font(.callout, .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                                             label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)])
            }
            cell.textField?.stringValue = d
            return cell
        case .entry(let i):
            let e = entries[i]
            let dir = e.directory
            let identifier = NSUserInterfaceItemIdentifier("history.entry")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BoardHistoryRow ?? BoardHistoryRow(frame: .zero)
            cell.identifier = identifier
            cell.configure(e, thumb: thumb(e), busy: transcribing.contains(dir), actions: actions(for: dir),
                           selecting: selecting, picked: picked.contains(dir)) { [weak self] on in self?.toggle(dir, on) }
            return cell
        }
    }
    private var pendingThumbs: Set<URL> = []
    private let thumbQueue = DispatchQueue(label: "pointtaken.board.history-thumbs", qos: .userInitiated)
    private func thumb(_ e: BoardHistoryEntry) -> NSImage? {
        guard let url = e.firstImage else { return nil }
        if let t = thumbs.object(forKey: url as NSURL) { return t }
        guard !pendingThumbs.contains(url) else { return nil }
        pendingThumbs.insert(url)
        thumbQueue.async { [weak self] in
            let image = boardThumbnail(url, height: 132).map { NSImage(cgImage: $0, size: .zero) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingThumbs.remove(url)
                guard let image else { return }
                guard self.entries.contains(where: { $0.firstImage == url }) else { return }
                let cost = Int(max(1, image.size.width) * max(1, image.size.height) * 4)
                self.thumbs.setObject(image, forKey: url as NSURL, cost: cost)
                let rows = self.rows.indices.filter { if case .entry(let i) = self.rows[$0] { return self.entries[i].firstImage == url }; return false }
                self.table.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: IndexSet(integer: 0))
            }
        }
        return nil
    }

    // MARK: actions

    private func entry(at row: Int) -> URL? {
        guard rows.indices.contains(row), case .entry(let i) = rows[row] else { return nil }
        return entries[i].directory
    }
    /// One click opens the record in the review window.
    @objc private func clicked() {
        guard let dir = entry(at: table.clickedRow) else { return }
        table.deselectAll(nil)
        if selecting {
            toggle(dir, !picked.contains(dir))
            table.reloadData(forRowIndexes: IndexSet(integer: table.clickedRow), columnIndexes: IndexSet(integer: 0))
        } else { open(dir) }
    }
    private func open(_ dir: URL) {
        guard !transcribing.contains(dir) else { status("正在重新转写，完成后再打开"); return }
        BoardSession.shared.openArchive(dir)
    }
    /// A record's actions: the row's buttons and its right-click menu.
    private func actions(for dir: URL) -> [BoardHistoryRow.Action] {
        let playing = playingFile == dir.appendingPathComponent("原始录音.wav")
        return [
            .init(title: "打开", symbol: "square.and.pencil") { [weak self] in self?.open(dir) },
            .init(title: playing ? "停止播放" : "播放录音", symbol: playing ? "stop.circle" : "play.circle") { [weak self] in self?.play(dir) },
            .init(title: "重新转写", symbol: "arrow.clockwise") { [weak self] in self?.retranscribe(dir) },
            .init(title: "在访达中显示", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) },
            .init(title: "移到废纸篓", symbol: "trash") { [weak self] in self?.trash(dir) },
        ]
    }
    private func menu(for dir: URL) -> NSMenu {
        let m = NSMenu()
        for (i, a) in actions(for: dir).enumerated() {
            if i == 4 { m.addItem(.separator()) }
            let box = BoardHistoryAction(a.run)
            let item = NSMenuItem(title: a.title, action: #selector(BoardHistoryAction.run), keyEquivalent: "")
            item.target = box
            item.representedObject = box
            item.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
            m.addItem(item)
        }
        return m
    }
    private func refreshPlaybackRows(_ files: [URL?]) {
        let directories = Set(files.compactMap { $0?.deletingLastPathComponent() })
        let changed = rows.indices.filter { row in
            if case .entry(let index) = rows[row] { return directories.contains(entries[index].directory) }
            return false
        }
        table.reloadData(forRowIndexes: IndexSet(changed), columnIndexes: IndexSet(integer: 0))
    }
    private func stopPlayback() {
        let previous = playingFile
        player?.pause()
        player = nil
        playingFile = nil
        playbackObservation = nil
        if let playbackEnd { NotificationCenter.default.removeObserver(playbackEnd) }
        playbackEnd = nil
        refreshPlaybackRows([previous])
    }
    private func play(_ dir: URL) {
        let file = dir.appendingPathComponent("原始录音.wav")
        guard FileManager.default.fileExists(atPath: file.path) else { status("这次记录没有保存录音"); return }
        let same = playingFile == file
        stopPlayback()
        if same { status(nil); return }
        // AVPlayer opens and buffers a local recording asynchronously, even for long original WAV files.
        let item = AVPlayerItem(url: file)
        let next = AVPlayer(playerItem: item)
        player = next
        playingFile = file
        playbackObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.player?.currentItem === item else { return }
                if item.status == .failed { self.stopPlayback(); self.status("录音无法播放") }
                else if item.status == .readyToPlay { self.status("正在播放 · 再点一次停止") }
            }
        }
        playbackEnd = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self, self.player?.currentItem === item else { return }
            self.stopPlayback()
            self.status(nil)
        }
        next.play()
        status("正在打开录音…")
        refreshPlaybackRows([file])
    }
    private func retranscribe(_ selected: URL) {
        guard !transcribing.contains(selected) else { return }
        guard !BoardSession.shared.isReviewing(selected) else { status("请先关闭这次记录的检查窗口，再重新转写"); return }
        let audio = selected.appendingPathComponent("原始录音.wav")
        guard FileManager.default.fileExists(atPath: audio.path) else { status("这次记录没有原始录音"); return }
        transcribing.insert(selected)
        table.reloadData()
        status("正在从原始录音重新转写；已有文字和交付稿会保留")
        let state = (try? Data(contentsOf: selected.appendingPathComponent("转写状态.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let locale = state?["locale"] as? String ?? BoardSession.locale
        var finished = false
        let model = BoardTranscription.selected
        BoardSpeech().transcribeFile(audio, locale) { [weak self] result in
            guard let self, !finished else { return }; finished = true
            self.transcribing.remove(selected)
            do {
                let file = try result.get()
                let text = file.text
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BoardLongImage.Failure(message: "未识别出文字，原转写保持不变。") }
                let destination = selected.appendingPathComponent("完整转写.txt")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: destination, to: selected.appendingPathComponent("转写备份-\(UUID().uuidString).txt"))
                }
                try text.write(to: destination, atomically: true, encoding: .utf8)
                if var evidence = BoardEvidence.load(selected) {
                    evidence.speech = file.segments; evidence.speechTimingSource = "original-audio-file"
                    try evidence.save(selected)
                }
                let data = try JSONSerialization.data(withJSONObject: ["state": "complete", "locale": locale, "model": model, "warning": "", "updatedAt": Date().timeIntervalSince1970])
                try data.write(to: selected.appendingPathComponent("转写状态.json"), options: .atomic)
                self.reload()
                self.status("重新转写已保存；旧转写已备份，手动修改的交付稿保持不变")
            } catch { self.table.reloadData(); self.status("重新转写未完成：" + error.localizedDescription) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard !finished else { return }; finished = true
            self?.transcribing.remove(selected); self?.table.reloadData(); self?.status("重新转写超时，已有录音和文字保持不变")
        }
    }
    private func trash(_ selected: URL) {
        guard !transcribing.contains(selected), !BoardSession.shared.isReviewing(selected) else { status("请先等转写结束并关闭检查窗口，再删除"); return }
        do {
            try FileManager.default.trashItem(at: selected, resultingItemURL: nil)
            reload()
            status("已移到废纸篓，需要时可以在访达里恢复")
        } catch { status("删除失败：\(error.localizedDescription)") }
    }

    // MARK: tests

    /// Exercises the production search and close paths against disposable archives, never the user's records.
    static func runHistoryCheck() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("point-taken-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let a = directory.appendingPathComponent("2026-11-15 10.00.00.000")
            let b = directory.appendingPathComponent("2026-11-15 11.00.00.000")
            for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            try (String(repeating: "完整说明", count: 200) + "结尾搜索\n目标").write(to: a.appendingPathComponent("完整转写.txt"), atomically: true, encoding: .utf8)
            try "另一条记录".write(to: b.appendingPathComponent("完整转写.txt"), atomically: true, encoding: .utf8)
            let h = BoardHistoryWindow()
            h.build()
            h.entries = [BoardHistoryEntry(a), BoardHistoryEntry(b)]
            precondition(h.entries[0].preview.count == 300)
            h.filter()
            precondition(h.rows.count == 3)
            h.search.stringValue = "结尾搜索 目标"
            h.filter()
            let deadline = Date().addingTimeInterval(3)
            while h.rows.count != 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(h.rows.count == 2 && h.entry(at: 1) == a, "Search lost the text after the row preview")
            h.search.stringValue = "不会命中"
            h.filter()
            h.search.stringValue = ""
            h.filter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            precondition(h.rows.count == 3, "A stale search replaced the current results")
            let cell = h.tableView(h.table, viewFor: nil, row: 1) as! BoardHistoryRow
            let subviews = cell.subviews.count
            cell.configure(h.entries[1], thumb: nil, busy: true, actions: h.actions(for: b), selecting: true, picked: true) { _ in }
            precondition(cell.subviews.count == subviews, "Reconfiguration duplicated the row controls")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = 0 }
            var file: AVAudioFile? = try AVAudioFile(forWriting: a.appendingPathComponent("原始录音.wav"), settings: format.settings)
            try file?.write(from: buffer)
            file = nil
            h.play(a)
            precondition(h.playingFile == a.appendingPathComponent("原始录音.wav"))
            h.play(a)
            precondition(h.player == nil && h.playingFile == nil, "Stop while opening must cancel playback")
            h.window?.close()
            precondition(h.entries.isEmpty && h.rows.isEmpty && h.player == nil, "Closing history retained its content")
            print("PASS: history preview, full-text search, stale search, row reuse, asynchronous playback and close cleanup")
            exit(0)
        } catch {
            fputs("History check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Renders the window over a temporary copy of the given records (or the real ones, read-only) to a PNG.
    static func renderPreview(to path: String) {
        let h = BoardHistoryWindow()
        h.build()
        h.reload(wait: true)
        if ProcessInfo.processInfo.environment["POINT_TAKEN_PREVIEW_SELECTING"] == "1" {
            h.toggleSelecting()
            for e in h.entries.prefix(2) { h.toggle(e.directory, true) }
            h.table.reloadData()
        }
        for row in 0..<h.rows.count { _ = h.tableView(h.table, viewFor: nil, row: row) }
        h.thumbQueue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let w = h.window else { return }
        w.orderFront(nil)
        for (suffix, name) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            w.appearance = NSAppearance(named: name)
            let frame = w.contentView!.superview!
            frame.layoutSubtreeIfNeeded(); frame.display()
            if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + suffix + ".png"))
            }
        }
        w.close()
    }
}

extension BoardHistoryWindow: NSMenuDelegate {
    /// The right-click menu: the clicked record's own menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let dir = entry(at: table.clickedRow) else { return }
        for item in self.menu(for: dir).items { item.menu?.removeItem(item); menu.addItem(item) }
    }
}

/// A menu item's closure (the item holds it as its representedObject, so it lives as long as the item).
private final class BoardHistoryAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
