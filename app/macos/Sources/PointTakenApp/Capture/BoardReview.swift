import AppKit
import AVFoundation
import Carbon.HIToolbox
import PointTakenCore

/// Recording-time review never becomes the key window. Text is editable only after recording stops.
private final class BoardReviewPanel: NSPanel {
    var recording = false
    /// ⌘+ / ⌘= / ⌘- / ⌘0 zoom the picture (before the menu bar sees them)
    var onZoomKey: ((String) -> Bool)?
    override var canBecomeKey: Bool { !recording }
    override var canBecomeMain: Bool { !recording }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == .command, let key = event.charactersIgnoringModifiers, ["+", "=", "-", "0"].contains(key),
           onZoomKey?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The page list: ⌘⌫ asks to delete the selected page (a bare ⌫ does nothing here: a stray key must not lose a page).
private final class BoardPageTable: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 51 || event.keyCode == 117) && mods == .command { onDelete?() } else { super.keyDown(with: event) }
    }
}

/// m:ss (h:mm:ss past an hour), the way a player shows a position.
func boardClock(_ seconds: Double) -> String {
    let t = Int(max(0, seconds).rounded(.down))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

/// What was said, in order, grouped by the screen it was said on: a kept page, a screen that wasn't kept, or none.
/// Built from the recording's own timeline (时间线.json): page visits and recognised sentences, both in audio seconds.
struct BoardSpeechBlock: Equatable {
    enum Kind: Equatable { case page(Int), screen(String), none }
    var kind: Kind
    var start: Double
    var end: Double
    var segments: [BoardSpeechSegment]

    static func build(pages: [BoardSession.Page], evidence: BoardEvidence?) -> [BoardSpeechBlock] {
        guard let evidence else { return [] }
        let speech = evidence.speech
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        // the screens, in order (a page seen twice in a row with a short gap is one stretch)
        var blocks: [BoardSpeechBlock] = []
        let visits = evidence.visits.compactMap { v -> (BoardVisit, Double, Double)? in
            guard let a = v.start.audio, let b = v.end.audio, a.isFinite, b.isFinite else { return nil }
            return (v, a, max(a, b))
        }.sorted { $0.1 < $1.1 }
        for (v, a, b) in visits {
            let kind: Kind = pages.firstIndex { $0.contextIDs.contains(v.pageID) }.map { .page($0) }
                ?? .screen([v.app, v.title].filter { !$0.isEmpty }.joined(separator: " · "))
            if let last = blocks.last, last.kind == kind, a - last.end < 1.5 { blocks[blocks.count - 1].end = max(last.end, b) }
            else { blocks.append(BoardSpeechBlock(kind: kind, start: a, end: b, segments: [])) }
        }
        // each sentence goes to the screen it was said on (by its middle); one said on no screen starts a "none" stretch
        var loose: [BoardSpeechBlock] = []
        var lastWasLoose = false
        for s in speech {
            let mid = (s.start + s.end) / 2
            if let i = blocks.firstIndex(where: { mid >= $0.start && mid <= $0.end }) {
                blocks[i].segments.append(s); lastWasLoose = false
            } else if lastWasLoose, !loose.isEmpty {
                loose[loose.count - 1].segments.append(s); loose[loose.count - 1].end = s.end
            } else {
                loose.append(BoardSpeechBlock(kind: .none, start: s.start, end: s.end, segments: [s])); lastWasLoose = true
            }
        }
        // a screen that wasn't kept and had nothing said on it is noise; then join what became neighbours
        var out: [BoardSpeechBlock] = []
        for b in (blocks + loose).sorted(by: { $0.start < $1.start }) where !(b.segments.isEmpty && b.pageIndex == nil) {
            if let last = out.last, last.kind == b.kind {
                out[out.count - 1].end = max(last.end, b.end)
                out[out.count - 1].segments += b.segments
            } else { out.append(b) }
        }
        return out
    }

    var pageIndex: Int? { if case .page(let i) = kind { return i }; return nil }
}

/// The whole recording as one bar: the kept pages' stretches (the selected one in the accent colour), screens that
/// weren't kept (fainter), and a tick under the bar for every sentence. A click picks the page under it.
private final class BoardTimelineStrip: NSView {
    var blocks: [BoardSpeechBlock] = [] { didSet { needsDisplay = true } }
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var selectedPage: Int? { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }

    private func x(_ t: Double) -> CGFloat { duration > 0 ? CGFloat(t / duration) * bounds.width : 0 }

    override func draw(_ dirtyRect: NSRect) {
        guard duration > 0 else { return }
        let track = NSRect(x: 0, y: 4, width: bounds.width, height: 10)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        for b in blocks {
            let r = NSRect(x: x(b.start), y: track.minY, width: max(3, x(b.end) - x(b.start)), height: track.height)
            switch b.kind {
            case .page(let i): (i == selectedPage ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.2)).setFill()
            case .screen: NSColor.labelColor.withAlphaComponent(0.08).setFill()
            case .none: continue
            }
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        NSColor.tertiaryLabelColor.setFill()
        for b in blocks { for s in b.segments { NSRect(x: x(s.start), y: track.maxY + 3, width: 1, height: 4).fill() } }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        ("0:00" as NSString).draw(at: NSPoint(x: 0, y: track.maxY + 9), withAttributes: attrs)
        let end = boardClock(duration) as NSString
        end.draw(at: NSPoint(x: bounds.width - end.size(withAttributes: attrs).width, y: track.maxY + 9), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard duration > 0, let b = blocks.first(where: { x($0.start) - 2 <= p.x && p.x <= x($0.end) + 2 && $0.pageIndex != nil }),
              let i = b.pageIndex else { return }
        onPick?(i)
    }
}

/// The sentences, stretch by stretch: a header (第 2 页 · 0:12 – 0:31, or the screen that wasn't kept), then each
/// sentence with its start time and, when the recording is kept, a button that plays just that sentence. The
/// selected page's stretches are tinted. Laid out by hand: rows of wrapping text at the list's width.
private final class BoardSpeechList: NSView, NSTextFieldDelegate {
    struct Metrics {
        static let inset: CGFloat = 20
        static let play: CGFloat = 16
        static let time: CGFloat = 44
        static let gap: CGFloat = 8
    }
    var onPick: ((Int) -> Void)?
    var onPlay: ((BoardSpeechSegment) -> Void)?
    /// a sentence's words were edited (the sentence as it was, the new words)
    var onEdit: ((BoardSpeechSegment, String) -> Void)?
    var canPlay = false
    var editable = true
    private(set) var blocks: [BoardSpeechBlock] = []
    private var selectedPage: Int?
    private var playing: BoardSpeechSegment?
    private var frames: [(block: Int, rect: NSRect)] = []
    private var rows: [(segment: BoardSpeechSegment, button: NSButton?, time: NSTextField, text: NSTextField)] = []
    private var headers: [(title: NSTextField, detail: NSTextField)] = []
    override var isFlipped: Bool { true }

    func reload(_ blocks: [BoardSpeechBlock], pages: Int) {
        self.blocks = blocks
        subviews.forEach { $0.removeFromSuperview() }
        rows = []; headers = []
        for b in blocks {
            let title = NSTextField(labelWithString: "")
            let detail = NSTextField(labelWithString: "")
            title.font = BoardStyle.font(.body, .semibold)
            detail.font = BoardStyle.digits(.subheadline)
            detail.textColor = .secondaryLabelColor
            switch b.kind {
            case .page(let i): title.stringValue = "第 \(i + 1) 页"
            case .screen(let name): title.stringValue = name.isEmpty ? "没有保存的画面" : name; title.textColor = .secondaryLabelColor
                title.font = BoardStyle.font(.body, .medium)
            case .none: title.stringValue = "没有对应画面"; title.textColor = .secondaryLabelColor
                title.font = BoardStyle.font(.body, .medium)
            }
            detail.stringValue = boardClock(b.start) + " – " + boardClock(b.end)
            if b.segments.isEmpty { detail.stringValue += " · 这段时间没有识别到说话" }
            title.lineBreakMode = .byTruncatingTail
            addSubview(title); addSubview(detail)
            headers.append((title, detail))
            for s in b.segments {
                var button: NSButton?
                if canPlay {
                    let p = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放这一句")!,
                                     target: self, action: #selector(play(_:)))
                    p.isBordered = false
                    p.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    p.contentTintColor = .secondaryLabelColor
                    p.toolTip = "播放这一句"
                    p.imageScaling = .scaleProportionallyDown
                    addSubview(p); button = p
                }
                let time = NSTextField(labelWithString: boardClock(s.start))
                time.font = BoardStyle.digits(.subheadline)
                time.textColor = .secondaryLabelColor
                let text = NSTextField(wrappingLabelWithString: s.text.trimmingCharacters(in: .whitespacesAndNewlines))
                text.font = BoardStyle.font(.body)
                text.isSelectable = true
                // each sentence can be corrected right here (Return or clicking away keeps it)
                text.isEditable = editable
                text.toolTip = editable ? "点一下可以直接改这一句" : nil
                text.delegate = self
                addSubview(time); addSubview(text)
                rows.append((s, button, time, text))
            }
        }
        _ = pages
        relayout()
    }

    func select(_ page: Int?) { selectedPage = page; needsDisplay = true }
    func setPlaying(_ s: BoardSpeechSegment?) {
        playing = s
        for r in rows {
            r.button?.image = NSImage(systemSymbolName: r.segment == s ? "stop.fill" : "play.fill", accessibilityDescription: nil)
            r.button?.contentTintColor = r.segment == s ? .controlAccentColor : .secondaryLabelColor
        }
    }
    /// the top of the first stretch of this page, to scroll to
    func top(of page: Int) -> CGFloat? { frames.first { blocks[$0.block].pageIndex == page }?.rect.minY }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private func relayout() {
        if let clip = superview, clip.bounds.width > 0, frame.width != clip.bounds.width {
            super.setFrameSize(NSSize(width: clip.bounds.width, height: frame.height))
        }
        let w = bounds.width
        guard w > 0 else { return }
        let m = Metrics.self
        let textX = m.inset + (canPlay ? m.play + m.gap : 0) + m.time + m.gap
        var y: CGFloat = 8
        var r = 0
        frames = []
        for (bi, b) in blocks.enumerated() {
            let top = y
            y += 10
            let h = headers[bi]
            let detailW = ceil(h.detail.intrinsicContentSize.width) + 4
            let titleW = min(ceil(h.title.intrinsicContentSize.width) + 4, w - m.inset * 2 - detailW - 8)
            h.title.frame = NSRect(x: m.inset, y: y, width: max(0, titleW), height: 17)
            h.detail.frame = NSRect(x: m.inset + titleW + 8, y: y + 1, width: detailW, height: 16)
            y += 17 + 8
            for _ in b.segments {
                let row = rows[r]; r += 1
                let textW = max(40, w - textX - m.inset)
                row.text.preferredMaxLayoutWidth = textW
                let th = ceil(row.text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 10_000)).height ?? 17)
                if let b = row.button { b.frame = NSRect(x: m.inset, y: y + 1, width: m.play, height: m.play) }
                row.time.frame = NSRect(x: m.inset + (canPlay ? m.play + m.gap : 0), y: y + 1, width: m.time, height: 16)
                row.text.frame = NSRect(x: textX, y: y, width: textW, height: th)
                y += th + 6
            }
            y += 4
            frames.append((bi, NSRect(x: 12, y: top, width: w - 24, height: y - top)))
            y += 4
        }
        let height = max(y + 8, superview?.bounds.height ?? 0)
        if frame.height != height { super.setFrameSize(NSSize(width: w, height: height)) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for f in frames where blocks[f.block].pageIndex != nil && blocks[f.block].pageIndex == selectedPage {
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: f.rect, xRadius: 8, yRadius: 8).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let f = frames.first(where: { $0.rect.contains(p) }), let i = blocks[f.block].pageIndex { onPick?(i) }
    }

    @objc private func play(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.button === sender }) else { return }
        onPlay?(row.segment)
    }
    /// the sentence grows or shrinks while it is typed: re-lay out the rows under it
    func controlTextDidChange(_ obj: Notification) { relayout() }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let row = rows.first(where: { $0.text === field }) else { return }
        onEdit?(row.segment, field.stringValue)
    }
}

final class BoardReviewWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate,
                               NSToolbarDelegate, NSSplitViewDelegate {
    /// The record's timeline. It can arrive after the window opened (the whole recording is still being transcribed
    /// when recording stops), so everything worked out from it — the timeline, and what was said about each mark —
    /// is redone when it does.
    var evidence: BoardEvidence? { didSet { rebuildTimeline(); marksChanged(); startAutoMerge() } }
    /// the timeline after a sentence was edited here (the session saves it with the record)
    var onEvidence: ((BoardEvidence) -> Void)?
    /// the recording (原始录音.wav), when it is kept: each sentence can be played
    var audio: URL? { didSet { rebuildTimeline() } }
    var onExport: (([BoardSession.Page], String) throws -> BoardFolderExport.Bundle)?
    private var lastExportFolder: URL?
    var onSave: (([BoardSession.Page], String?) -> Void)?
    var onClose: (() -> Void)?
    var onDeliver: ((NSRunningApplication, BoardFolderExport.Bundle) -> Void)?
    private var pages: [BoardSession.Page]
    private let recording: Bool
    private let window: BoardReviewPanel

    // the sidebar
    private let table = BoardPageTable()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyPages = NSTextField(labelWithString: "没有截图")
    private var listButtons: [NSButton] = []

    // the page: the picture (its name and times are the window's title; whether it goes to the AI, its sidebar check)
    private let canvas = BoardFlippedView()
    private let imageScroll = NSScrollView()
    private let picture = NSImageView()
    /// the picture's card: rounded, with a soft shadow (the picture itself clips to the same corners)
    private let pictureCard = NSView()
    private let markCanvas = BoardMarkCanvas(frame: .zero)
    /// one undo history for the window: marks, notes, page order and deletions (and typing, through the text views)
    private let undo = UndoManager()
    /// what each page's marked picture (keyed by its file) was last drawn with: a page is redrawn only when it changed
    private var rendered: [URL: RenderedMarks] = [:]
    private struct RenderedMarks: Equatable { var marks: [[[Double]]]; var numbers: [Int] }
    /// originals copied for records that had none (keyed by the marked picture), so an undo never copies a marked one
    private var madeOriginals: [URL: URL] = [:]
    private let emptyTitle = NSTextField(labelWithString: "这次没有截图")
    private let emptyDetail = NSTextField(labelWithString: "录音和文字已经保存")
    private lazy var emptyState = BoardStyle.emptyState(symbol: "photo.on.rectangle.angled", title: emptyTitle, detail: emptyDetail)
    private var shownImage: CGImage?
    private var laidOut = CGSize.zero

    // what was said
    private let mode = NSSegmentedControl(labels: ["标记", "按时间", "全文"], trackingMode: .selectOne, target: nil, action: nil)
    private enum Mode { static let marks = 0, timeline = 1, words = 2 }
    private let markList = BoardMarkList(frame: .zero)
    /// 标记 / 按时间 / 全文 as a column on the lower pane's left (`mode` keeps which one is chosen)
    private var modeButtons: [BoardModeButton] = []
    private let note = NSTextField(labelWithString: "")
    /// 去补: jumps to the first mark that would go to the AI with nothing said about it
    private let fixButton = NSButton(title: "去补", target: nil, action: nil)
    private lazy var status = NSStackView(views: [note, fixButton])
    private let strip = BoardTimelineStrip()
    private let speechList = BoardSpeechList()
    private let speechScroll = NSScrollView()
    private let speechPane = NSView()
    private let wordsScroll = NSTextView.scrollableTextView()
    private var words: NSTextView { wordsScroll.documentView as! NSTextView }
    private var originalTranscript: String
    private var editedTranscript = false
    private var blocks: [BoardSpeechBlock] = []
    private var player: AVAudioPlayer?
    private var playing: BoardSpeechSegment?
    private var playStop: Timer?

    // the drawing tools and undo / redo: two glass columns at the picture's left (undo on top, the tools at the
    // bottom), off the toolbar so the window's top stays uncluttered
    /// 选择 | 自由画 | 矩形 | 圆圈
    private lazy var sideTools = BoardSideTools(items: Self.toolChoices.map { ($0.symbol, $0.tip) }, selects: true)
    private let sideUndo = BoardSideTools(items: [("arrow.uturn.backward", "撤销（⌘Z）"), ("arrow.uturn.forward", "重做（⇧⌘Z）")],
                                          selects: false)
    // the toolbar
    /// 保存并关闭: keeps the changes without copying anything (left of 复制并关闭)
    private var saveButton: NSButton?
    private let more = NSMenu()
    private var deliveryButtons: [NSButton] = []
    private var deliveryItems: [NSMenuItem] = []
    private var primary: NSButton!
    private let detailSplit = BoardGrabSplitView()
    /// the lower pane's height the user chose by dragging the divider (kept for later windows); nil: automatic
    private var chosenLowerHeight: CGFloat?
    /// where the chosen height is kept (nil in self-checks, so they never touch the user's settings)
    var lowerPaneStore: UserDefaults? = .standard { didSet { chosenLowerHeight = Self.storedLowerHeight(lowerPaneStore) } }
    private static let lowerPaneKey = "board.review.lowerPaneHeight"
    private static func storedLowerHeight(_ store: UserDefaults?) -> CGFloat? {
        (store?.object(forKey: lowerPaneKey) as? Double).map { CGFloat($0) }
    }
    /// the window itself is moving the divider (fitting it), not the user
    private var fitting = false

    private var finalizing = false
    private var selected: Int?
    private var closing = false
    /// the automatic long pictures were looked for (once per window, after recording, with the record's inputs)
    private var autoMergeStarted = false
    /// pictures this window wrote (long pictures, split parts): the ones no page uses are removed when it closes
    private var madeFiles: Set<URL> = []
    private let splitItem = NSMenuItem(title: "拆开长图", action: nil, keyEquivalent: "")

    // Layout (Apple HIG: a sidebar split view; the window's commands in its toolbar, the primary one — Copy — on
    // the trailing edge; nothing important along the bottom edge). Sidebar: the pages. Detail: the page (header,
    // picture) over what was said (by time, or the whole editable transcript). One 20 pt content margin; 8 pt steps.
    private static let margin: CGFloat = 20
    private static let sidebarWidth: CGFloat = 292
    private enum ID {
        static let more = NSToolbarItem.Identifier("board.review.more")
        static let history = NSToolbarItem.Identifier("board.review.history")
        static let delete = NSToolbarItem.Identifier("board.review.delete")
        static let settings = NSToolbarItem.Identifier("board.review.settings")
        static let paste = NSToolbarItem.Identifier("board.review.paste")
        static let done = NSToolbarItem.Identifier("board.review.done")
        static let save = NSToolbarItem.Identifier("board.review.save")
    }

    init(pages: [BoardSession.Page], transcript: String, recording: Bool, originalTranscript: String? = nil, warning: String? = nil) {
        self.pages = pages
        self.recording = recording
        self.originalTranscript = originalTranscript ?? transcript
        let size = NSSize(width: 1180, height: 800)
        window = BoardReviewPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: recording ? [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
                                                       : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        super.init()
        // the pictures on disk already show the marks the pages arrive with
        for page in pages {
            if let url = page.images.first, !page.imageNeedsRepair, !BoardFileWriter.needsRepair(url),
               FileManager.default.fileExists(atPath: url.path) { rendered[url] = Self.signature(page) }
        }
        window.recording = recording
        window.onZoomKey = { [weak self] key in self?.zoomKey(key) ?? false }
        window.title = recording ? "回看页面" : "检查内容"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = recording ? .floating : .normal
        window.minSize = NSSize(width: 980, height: 640)
        window.delegate = self
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic

        prepareToolbarControls()
        // The system's split view controller with a real sidebar item: on the current macOS it floats the sidebar on
        // Liquid Glass, puts the title after it and gives the toolbar its show/hide-sidebar button. The detail is a
        // classic split (picture over what was said): the lower pane keeps its size as the window grows.
        let sidebarController = NSViewController()
        sidebarController.view = buildSidebar()
        detailSplit.frame = NSRect(x: 0, y: 0, width: size.width - Self.sidebarWidth, height: size.height)
        let detailController = NSViewController()
        detailController.view = buildDetail(transcript: transcript, warning: warning)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        self.sidebarItem = sidebarItem
        splitController.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: detailController)]
        window.contentViewController = splitController
        window.setContentSize(size)
        splitController.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        mainSplit = splitController.splitView
        // the toolbar comes after the split view: its separator follows the sidebar's edge
        let toolbar = NSToolbar(identifier: "board.review." + (recording ? "live" : "final"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateUndoButtons), name: name, object: undo)
        }
        detailSplit.adjustSubviews()
        chosenLowerHeight = Self.storedLowerHeight(lowerPaneStore)
        fitting = true
        detailSplit.setPosition(detailSplit.bounds.height - 300, ofDividerAt: 0)   // fitted once the content is known
        fitting = false
        detailSplit.onDoubleClick = { [weak self] in self?.useAutomaticLowerPane() }
        detailSplit.onDragged = { [weak self] height in self?.lowerPaneChosen(height) }

        rebuildTimeline()
        reloadList()
        mode.selectedSegment = recording || blocks.isEmpty ? Mode.words : Mode.timeline
        // a record with marks opens on its marks: checking and explaining them is what the window is for
        if !recording, pages.contains(where: { !$0.marks.isEmpty }) { mode.selectedSegment = Mode.marks }
        modeChanged()
        if !pages.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { showPage(nil) }
        updateSubtitle()
        updateUndoButtons()
        appearanceWatch = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.effectiveColors() }
        }
    }

    /// When the record was made (from its folder name); shown in the window's subtitle.
    var recordDate: Date? { didSet { updateSubtitle() } }
    /// what the title bar says about the page shown (第 3 页 / 0:33 – 0:41 · 标记 6、7), or nil with no page
    private var shownTitle: (title: String, detail: String)?
    private weak var mainSplit: NSSplitView?
    /// full-size markup: the sidebar and the lower pane put away, the picture filling the window, a note box beside
    /// each mark drawn or picked, ‹ n / N › under the picture
    private(set) var focusMode = false
    private let notePopover = BoardNotePopover()
    private let pageSwitcher = BoardPageSwitcher()
    /// full-size markup: the pages slide out over the picture's left side when the pointer touches the window's left
    /// edge, and slide back when it leaves them
    private let pageStrip = BoardPageStrip(frame: .zero)
    private let edgeSensor = BoardEdgeSensor(frame: .zero)
    private var stripLeading: NSLayoutConstraint?
    private var stripShown = false
    private var stripHide: DispatchWorkItem?
    private weak var sidebarItem: NSSplitViewItem?
    private weak var lowerPane: NSView?
    private let splitController = NSSplitViewController()
    private var appearanceWatch: NSKeyValueObservation?

    /// The title bar names the page shown and, under it, its times and marks with the record's date:
    /// 第 3 页 / 0:33 – 0:41 · 标记 6、7 · 11月15日 13:16. (There is no separate page header row: the picture gets
    /// that room.) Without a page it names the window and counts what is here.
    private func updateSubtitle() {
        var date: String?
        if let recordDate {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
            date = f.string(from: recordDate)
        }
        if let shownTitle {
            window.title = shownTitle.title
            window.subtitle = [recording ? "录音中，只能查看" : nil, shownTitle.detail.isEmpty ? nil : shownTitle.detail, date]
                .compactMap { $0 }.joined(separator: " · ")
            return
        }
        window.title = recording ? "回看页面" : "检查内容"
        var parts: [String] = []
        if recording { parts.append("录音中，只能查看") } else if let date { parts.append(date) }
        if !pages.isEmpty { parts.append("\(pages.count) 页") }
        window.subtitle = parts.joined(separator: " · ")
    }

    // MARK: building

    private func prepareToolbarControls() {
        more.autoenablesItems = false
        let copyOnly = NSMenuItem(title: "仅复制，不关闭", action: #selector(copyWords), keyEquivalent: "")
        let image = NSMenuItem(title: "复制当前图片", action: #selector(copyImage), keyEquivalent: "")
        let folder = NSMenuItem(title: "打开导出文件夹", action: #selector(openExportFolder), keyEquivalent: "")
        let restore = NSMenuItem(title: "恢复原始转写", action: #selector(restoreWords), keyEquivalent: "")
        copyOnly.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        image.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        restore.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        splitItem.action = #selector(splitLongImage)
        splitItem.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: nil)
        splitItem.isEnabled = false
        for item in [copyOnly, image, folder, restore, splitItem] { item.target = self }
        more.items = recording ? [image] : [copyOnly, image, splitItem, folder, .separator(), restore]
        deliveryItems = [copyOnly, folder, restore]

        // the one primary action, on the trailing edge: 复制并关闭 (or 完成 while recording); Return presses it
        primary = recording ? NSButton(title: "完成", target: self, action: #selector(saveClose))
                            : NSButton(title: "复制并关闭", target: self, action: #selector(copyAndClose))
        primary.bezelStyle = .push
        if #available(macOS 26.0, *) {
            primary.bezelStyle = .glass
            primary.tintProminence = .primary
        }
        primary.keyEquivalent = "\r"
        primary.toolTip = recording ? "保存并回到录音" : "复制完整说明和图片路径（直接粘贴给 AI），然后关闭窗口"
        if !recording { deliveryButtons.append(primary) }
        if !recording {
            let save = NSButton(title: "保存并关闭", target: self, action: #selector(saveClose))
            save.bezelStyle = .push
            if #available(macOS 26.0, *) { save.bezelStyle = .glass }
            save.toolTip = "保存修改，不复制，关闭窗口"
            saveButton = save
        }
    }

    // Toolbar (HIG): the title over the content, the secondary commands in a menu, 保存并关闭 then the one primary
    // command last. (The drawing tools and undo / redo float at the picture's left.)
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        recording
            ? [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, ID.delete, ID.more, ID.done]
            : [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, ID.delete, ID.history, ID.settings, ID.more,
               ID.save, ID.paste]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.delete:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除标记")
            item.label = "删除"
            item.toolTip = "删除选中的标记（⌫，可以 ⌘Z 撤销）"
            item.target = self
            item.action = #selector(deleteSelectedMark)
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = markCanvas.selected != nil
            deleteItem = item
            return item
        case ID.history, ID.settings:
            let isHistory = id == ID.history
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: isHistory ? "clock.arrow.circlepath" : "gearshape",
                                 accessibilityDescription: isHistory ? "历史" : "设置")
            item.label = isHistory ? "历史" : "设置"
            item.toolTip = isHistory ? "历史记录" : "设置"
            item.target = self
            item.action = isHistory ? #selector(openHistory) : #selector(openSettings)
            item.isBordered = true
            return item
        case ID.more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多")
            item.label = "更多"; item.toolTip = "更多操作"; item.menu = more; item.showsIndicator = false
            return item
        case ID.save:
            guard let saveButton else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = saveButton; item.label = saveButton.title
            return item
        case ID.paste, ID.done:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = primary; item.label = primary.title
            return item
        default: return nil
        }
    }
    @objc private func openHistory() { BoardHistoryWindow.shared.show() }
    private weak var deleteItem: NSToolbarItem?
    @objc private func deleteSelectedMark() {
        if let number = markCanvas.selected { notePopover.close(); deleteMark(number) } else { NSSound.beep() }
    }
    /// The round glass button in the picture's bottom-right corner: full-size markup on / off.
    private let focusButton = BoardGlassButton()
    private func updateFocusItem() {
        focusButton.isHidden = recording || shownImage == nil
        sideTools.isHidden = shownImage == nil
        sideUndo.isHidden = shownImage == nil
        focusButton.set(symbol: focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        tip: focusMode ? "退出放大标注（Esc）" : "放大图片来标注：画完旁边直接写说明，‹ › 切换页面（双击图片空白处也可以）")
    }
    @objc private func toggleFocus() { setFocus(!focusMode) }

    /// Full-size markup on and off. The sidebar folds away (animated by the split view), the lower pane and its
    /// divider go, the picture takes the whole window; ‹ n / N › appears under it when there is more than one page.
    func setFocus(_ on: Bool) {
        guard on != focusMode, !on || shownImage != nil else { return }
        notePopover.close()
        focusMode = on
        if let sidebarItem {
            if BoardMotion.reduced { sidebarItem.isCollapsed = on }
            else {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.3
                    c.timingFunction = BoardMotion.emphasized
                    c.allowsImplicitAnimation = true
                    sidebarItem.animator().isCollapsed = on
                }
            }
        }
        lowerPane?.isHidden = on
        detailSplit.hidesDivider = on
        edgeSensor.isHidden = !on
        if on { pageStrip.reload(pages.map(\.thumb), selected: selected) } else { concealStrip(after: 0) }
        detailSplit.adjustSubviews()
        if !on { fitLowerPane() }
        updateSwitcher()
        if shownImage != nil { imageScroll.magnification = 1; layoutPicture() }
        if on, !BoardMotion.reduced, !pageSwitcher.isHidden {
            pageSwitcher.wantsLayer = true
            pageSwitcher.layer?.add(BoardMotion.spring("transform.translation.y", from: -18, to: 0,
                                                       response: BoardMotion.snappy.response, damping: BoardMotion.snappy.damping), forKey: "in")
            BoardMotion.fade(pageSwitcher.layer, from: 0, to: 1, duration: 0.2)
        }
        updateFocusItem()
        window.makeFirstResponder(markCanvas)
    }
    private func updateSwitcher() {
        pageSwitcher.isHidden = !focusMode || pages.count < 2
        if let selected { pageSwitcher.show(page: selected, of: pages.count) }
        if focusMode { pageStrip.select(selected) }
    }

    /// The pages slide out from the left edge over the picture (they go again unless the pointer comes onto them).
    private func revealStrip() {
        guard focusMode, !pages.isEmpty else { return }
        stripHide?.cancel()
        concealStrip(after: 1.2)               // touched the edge but went elsewhere: back in after a moment
        guard !stripShown else { return }
        stripShown = true
        pageStrip.reload(pages.map(\.thumb), selected: selected)
        pageStrip.isHidden = false
        moveStrip(to: 12)
    }
    /// The pages slide back out of view after `delay` seconds (nothing happens if they were brought back meanwhile).
    private func concealStrip(after delay: TimeInterval) {
        stripHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stripShown else { return }
            self.stripShown = false
            self.moveStrip(to: -(BoardPageStrip.width + 24)) { [weak self] in
                if self?.stripShown == false { self?.pageStrip.isHidden = true }
            }
        }
        stripHide = work
        if delay <= 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }
    private func moveStrip(to x: CGFloat, done: (() -> Void)? = nil) {
        guard let stripLeading else { return }
        if BoardMotion.reduced {
            stripLeading.constant = x
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = x > 0 ? 0.34 : 0.22
            c.timingFunction = x > 0 ? BoardMotion.emphasized : BoardMotion.exit
            c.allowsImplicitAnimation = true
            stripLeading.animator().constant = x
            pageStrip.superview?.layoutSubtreeIfNeeded()
        }, completionHandler: done)
    }
    /// The page before (−1) or after (+1) the one shown.
    func step(_ delta: Int) {
        guard let s = selected, pages.indices.contains(s + delta) else { NSSound.beep(); return }
        notePopover.close()
        table.selectRowIndexes(IndexSet(integer: s + delta), byExtendingSelection: false)
        table.scrollRowToVisible(s + delta)
        if focusMode { window.makeFirstResponder(markCanvas) }
    }
    /// The note box beside a mark (full-size markup).
    private func showNote(_ number: Int) {
        guard focusMode, let s = selected, pages.indices.contains(s), let rect = markCanvas.rect(of: number),
              window.isVisible else { return }
        let marks = sheet(of: s).evidence
        guard let mark = marks.first(where: { $0.number == number }) else { return }
        let said = evidence?.said(about: marks, onPage: pages[s].contextIDs)[number]
        notePopover.show(number: number, note: mark.note ?? "", said: Self.quoted(said ?? []), at: rect, in: markCanvas)
    }
    @objc private func openSettings() { BoardHome.openSettings() }
    private func undoRedo(_ index: Int) {
        if index == 1 { if undo.canRedo { undo.redo() } } else { undoLast() }
    }
    @objc private func updateUndoButtons() {
        let b = sideUndo.buttons
        guard b.count == 2 else { return }
        b[0].isEnabled = undo.canUndo
        b[1].isEnabled = undo.canRedo
        b[0].toolTip = undo.canUndo ? "撤销" + undo.undoActionName + "（⌘Z）" : "撤销（⌘Z）"
        b[1].toolTip = undo.canRedo ? "重做" + undo.redoActionName + "（⇧⌘Z）" : "重做（⇧⌘Z）"
    }

    // Sidebar (HIG source list): a small section header, one row per page — thumbnail, title, a detail line — and
    // the list's own commands in a bar along its foot, as in Finder or Mail.
    private func buildSidebar() -> NSView {
        let side = NSView()

        let title = BoardStyle.label("页面", .subheadline, .semibold, color: .secondaryLabelColor)
        countLabel.font = BoardStyle.digits(.subheadline)
        countLabel.textColor = .tertiaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        // the selection is drawn by the row (BoardPageSelectionRow): a soft rounded highlight with readable text,
        // the same in every appearance (the source list's own selection material does not keep the row's text legible)
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: BoardStyle.tight)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.onDelete = { [weak self] in self?.askRemove() }
        let menu = NSMenu()
        menu.addItem(withTitle: "删除这一页…", action: #selector(askRemove), keyEquivalent: "").target = self
        table.menu = menu
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.drawsBackground = false
        list.documentView = table

        emptyPages.font = BoardStyle.font(.callout)
        emptyPages.textColor = .tertiaryLabelColor

        let rule = NSBox(); rule.boxType = .separator
        listButtons = [Self.icon("trash", "删除这一页（⌘⌫）", self, #selector(askRemove))]
        let foot = NSStackView(views: listButtons)
        foot.spacing = 2

        for v in [title, countLabel, list, emptyPages, rule, foot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(v)
        }
        let m = BoardStyle.margin, safe = side.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // below the title bar the sidebar runs up under
            title.topAnchor.constraint(equalTo: safe.topAnchor, constant: BoardStyle.group),
            title.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: m),
            countLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            countLabel.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -m),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: BoardStyle.tight),
            list.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: rule.topAnchor),
            emptyPages.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyPages.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -40),
            foot.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: BoardStyle.inner),
            foot.centerYAnchor.constraint(equalTo: side.bottomAnchor, constant: -20),
        ])
        return side
    }

    // Detail: the page (a header bar, then the picture on the under-page background) over what was said (a bar with
    // the 标记 | 按时间 | 全文 switch centred and the status on the right, then that view). Both bars are one height.
    private func buildDetail(transcript: String, warning: String?) -> NSView {
        let m = BoardStyle.margin
        let detail = detailSplit
        detail.isVertical = false
        detail.dividerStyle = .thin

        // ── the page
        let top = NSView()
        imageScroll.hasVerticalScroller = true
        imageScroll.hasHorizontalScroller = true
        imageScroll.autohidesScrollers = true
        // pinch or ⌘+ / ⌘- to look closer at small things; ⌘0 back to the whole width
        imageScroll.allowsMagnification = true
        imageScroll.minMagnification = 1
        imageScroll.maxMagnification = 6
        imageScroll.drawsBackground = true
        imageScroll.backgroundColor = .underPageBackgroundColor
        imageScroll.documentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pictureCard.wantsLayer = true
        pictureCard.layer?.cornerRadius = BoardStyle.pictureRadius
        pictureCard.layer?.cornerCurve = .continuous
        pictureCard.layer?.shadowOpacity = 0.16
        pictureCard.layer?.shadowRadius = 12
        pictureCard.layer?.shadowOffset = CGSize(width: 0, height: -3)
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.cornerRadius = BoardStyle.pictureRadius
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 1
        canvas.addSubview(pictureCard)
        canvas.addSubview(picture)
        canvas.addSubview(markCanvas)
        markCanvas.onDraw = { [weak self] points in self?.addMark(points) }
        markCanvas.onDelete = { [weak self] number in self?.deleteMark(number) }
        markCanvas.onSelect = { [weak self] number in self?.markSelected(number) }
        markCanvas.onEscape = { [weak self] in
            guard let self else { return }
            if self.markCanvas.tool != .select { self.setTool(0) } else if self.focusMode { self.setFocus(false) }
        }
        markCanvas.onArrow = { [weak self] step in self?.step(step) }
        markCanvas.onEmptyDoubleClick = { [weak self] in guard let self else { return }; self.setFocus(!self.focusMode) }
        notePopover.onCommit = { [weak self] number, text in self?.setNote(text, mark: number) }
        pageSwitcher.onStep = { [weak self] step in self?.step(step) }
        pageSwitcher.isHidden = true
        focusButton.onClick = { [weak self] in self?.toggleFocus() }
        focusButton.isHidden = true
        sideTools.onPick = { [weak self] i in self?.setTool(i) }
        sideUndo.onPick = { [weak self] i in self?.undoRedo(i) }
        sideTools.isHidden = true
        sideUndo.isHidden = true
        notePopover.onDelete = { [weak self] number in self?.deleteMark(number) }
        pageStrip.isHidden = true
        edgeSensor.isHidden = true
        edgeSensor.onTouch = { [weak self] in self?.revealStrip() }
        pageStrip.onEnter = { [weak self] in self?.stripHide?.cancel() }
        pageStrip.onLeave = { [weak self] in self?.concealStrip(after: 0.3) }
        pageStrip.onPick = { [weak self] index in
            guard let self, index != self.selected else { return }
            self.step(index - (self.selected ?? 0))
        }
        imageScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.frameDidChangeNotification, object: imageScroll.contentView)
        emptyState.identifier = NSUserInterfaceItemIdentifier("empty")
        for v in [imageScroll, emptyState, sideUndo, sideTools, pageSwitcher, focusButton, pageStrip, edgeSensor] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(v)
        }
        let bar = BoardStyle.barHeight
        let topSafe = top.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            imageScroll.topAnchor.constraint(equalTo: topSafe.topAnchor),
            imageScroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            imageScroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            imageScroll.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: imageScroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: imageScroll.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: imageScroll.widthAnchor, constant: -m * 2),
            pageSwitcher.centerXAnchor.constraint(equalTo: top.centerXAnchor),
            pageSwitcher.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -16),
            focusButton.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -16),
            focusButton.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -16),
            sideUndo.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 16),
            sideUndo.topAnchor.constraint(equalTo: topSafe.topAnchor, constant: 16),
            sideTools.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 16),
            sideTools.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -16),
            pageStrip.widthAnchor.constraint(equalToConstant: BoardPageStrip.width),
            pageStrip.topAnchor.constraint(equalTo: topSafe.topAnchor, constant: 12),
            pageStrip.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -12),
            edgeSensor.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            edgeSensor.widthAnchor.constraint(equalToConstant: 10),
            edgeSensor.topAnchor.constraint(equalTo: topSafe.topAnchor),
            edgeSensor.bottomAnchor.constraint(equalTo: top.bottomAnchor),
        ])
        let leading = pageStrip.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: -(BoardPageStrip.width + 24))
        leading.isActive = true
        stripLeading = leading

        // ── what was said
        let bottom = NSView()
        mode.target = self
        mode.action = #selector(modeClicked)
        mode.segmentStyle = .automatic
        mode.controlSize = .regular
        for (i, width) in [(Mode.marks, 72), (Mode.timeline, 72), (Mode.words, 72)] { mode.setWidth(CGFloat(width), forSegment: i) }
        mode.setToolTip("这一页的每个标记和它的说明", forSegment: Mode.marks)
        mode.setToolTip("全文", forSegment: Mode.words)
        note.font = BoardStyle.font(.callout)
        note.textColor = warning != nil ? .systemOrange : .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.alignment = .right
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.stringValue = warning ?? (recording ? "录音结束后可以修改文字" : "")

        strip.onPick = { [weak self] i in self?.pick(page: i) }
        speechList.onPick = { [weak self] i in self?.pick(page: i) }
        speechList.onPlay = { [weak self] s in self?.play(s) }
        speechList.onEdit = { [weak self] old, text in self?.edit(old, to: text) }
        speechScroll.hasVerticalScroller = true
        speechScroll.autohidesScrollers = true
        speechScroll.drawsBackground = false
        speechScroll.documentView = speechList
        speechList.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        speechList.autoresizingMask = [.width]

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = BoardStyle.inner
        let body = NSFont.systemFont(ofSize: 15)
        wordsScroll.drawsBackground = false
        wordsScroll.hasVerticalScroller = true
        wordsScroll.autohidesScrollers = true
        words.isRichText = false
        words.drawsBackground = false
        words.font = body
        words.textColor = .labelColor
        words.defaultParagraphStyle = paragraph
        words.typingAttributes = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        words.textContainerInset = NSSize(width: m - 5, height: BoardStyle.group)
        words.isEditable = !recording
        words.isSelectable = !recording
        words.string = transcript
        words.delegate = self

        for v in [strip, speechScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; speechPane.addSubview(v) }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: speechPane.topAnchor, constant: BoardStyle.group),
            strip.leadingAnchor.constraint(equalTo: speechPane.leadingAnchor, constant: m),
            strip.trailingAnchor.constraint(equalTo: speechPane.trailingAnchor, constant: -m),
            speechScroll.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: BoardStyle.tight),
            speechScroll.leadingAnchor.constraint(equalTo: speechPane.leadingAnchor),
            speechScroll.trailingAnchor.constraint(equalTo: speechPane.trailingAnchor),
            speechScroll.bottomAnchor.constraint(equalTo: speechPane.bottomAnchor),
        ])

        markList.onSelect = { [weak self] number in self?.markCanvas.selected = number }
        markList.onNote = { [weak self] number, text in self?.setNote(text, mark: number) }
        markList.onDelete = { [weak self] number in self?.deleteMark(number) }
        markList.editable = !recording
        fixButton.bezelStyle = .inline
        fixButton.controlSize = .small
        fixButton.target = self
        fixButton.action = #selector(goToUnexplained)
        fixButton.toolTip = "跳到还没有说明的标记"
        fixButton.isHidden = true
        status.spacing = BoardStyle.inner
        status.setHuggingPriority(.defaultLow, for: .horizontal)
        // the left column: the three views stacked, the status (with 去补) under them
        modeButtons = [(Mode.marks, "标记", "number.circle", "这一页的每个标记和它的说明"),
                       (Mode.timeline, "按时间", "clock", "按时间看每一页说了什么"),
                       (Mode.words, "全文", "text.alignleft", "完整转写，可以修改")]
            .sorted { $0.0 < $1.0 }
            .map { _, title, symbol, tip in
                let b = BoardModeButton(title: title, symbol: symbol, target: self, action: #selector(modeButtonClicked(_:)))
                b.toolTip = tip
                return b
            }
        let choices = NSStackView(views: modeButtons)
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 2
        modeButtons.forEach { $0.widthAnchor.constraint(equalTo: choices.widthAnchor).isActive = true }
        note.font = BoardStyle.font(.callout)
        note.alignment = .left
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 4
        note.cell?.wraps = true
        note.cell?.truncatesLastVisibleLine = true
        status.orientation = .vertical
        status.alignment = .leading
        status.spacing = BoardStyle.tight
        let column = NSView()
        var choicesBox: NSView = choices
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            let inset = NSView()
            choices.translatesAutoresizingMaskIntoConstraints = false
            inset.addSubview(choices)
            NSLayoutConstraint.activate([
                choices.topAnchor.constraint(equalTo: inset.topAnchor, constant: 4),
                choices.bottomAnchor.constraint(equalTo: inset.bottomAnchor, constant: -4),
                choices.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 4),
                choices.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -4),
            ])
            glass.contentView = inset
            choicesBox = glass
        }
        for v in [choicesBox, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; column.addSubview(v) }
        let rule = NSBox(); rule.boxType = .separator
        for v in [column, rule, speechPane, wordsScroll, markList] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottom.addSubview(v)
        }
        let s = BoardStyle.self
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: bottom.topAnchor),
            column.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: s.group),
            column.widthAnchor.constraint(equalToConstant: Self.modeColumn),
            choicesBox.topAnchor.constraint(equalTo: column.topAnchor, constant: s.inner + s.tight),
            choicesBox.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            choicesBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            status.topAnchor.constraint(greaterThanOrEqualTo: choicesBox.bottomAnchor, constant: s.inner),
            status.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: s.inner),
            status.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -s.group),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: Self.modeColumn - s.inner),
            rule.topAnchor.constraint(equalTo: bottom.topAnchor, constant: s.inner),
            rule.bottomAnchor.constraint(equalTo: bottom.bottomAnchor, constant: -s.inner),
            rule.leadingAnchor.constraint(equalTo: column.trailingAnchor, constant: s.group),
            rule.widthAnchor.constraint(equalToConstant: 1),
            speechPane.topAnchor.constraint(equalTo: bottom.topAnchor),
            speechPane.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            speechPane.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            speechPane.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            wordsScroll.topAnchor.constraint(equalTo: bottom.topAnchor),
            wordsScroll.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            wordsScroll.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            wordsScroll.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            // the cards fill the rest, from the top
            markList.topAnchor.constraint(equalTo: bottom.topAnchor, constant: s.tight),
            markList.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: s.group),
            markList.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -m),
            markList.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
        ])

        detail.delegate = self
        top.frame = NSRect(x: 0, y: 0, width: detail.bounds.width, height: detail.bounds.height - 301)
        bottom.frame = NSRect(x: 0, y: detail.bounds.height - 300, width: detail.bounds.width, height: 300)
        detail.addSubview(top)
        detail.addSubview(bottom)
        lowerPane = bottom
        return detail
    }

    /// A small borderless symbol button (the sidebar's foot bar).
    private static func icon(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: BoardStyle.hit + 2).isActive = true
        b.heightAnchor.constraint(equalToConstant: BoardStyle.hit).isActive = true
        return b
    }

    // MARK: state

    private func reloadList() {
        rebuildTimeline()
        table.reloadData()
        countLabel.stringValue = pages.isEmpty ? "" : "\(pages.count) 页"
        emptyPages.isHidden = !pages.isEmpty
        listButtons.forEach { $0.isEnabled = !pages.isEmpty }
        if focusMode { pageStrip.reload(pages.map(\.thumb), selected: selected) }
        updateSubtitle()
    }

    private func rebuildTimeline() {
        blocks = BoardSpeechBlock.build(pages: pages, evidence: evidence)
        // no sentences yet (the words are still being transcribed, or none were recognised): no timeline to show
        if !blocks.contains(where: { !$0.segments.isEmpty }) { blocks = [] }
        let canPlay = audio.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        speechList.canPlay = canPlay
        speechList.editable = !recording && !finalizing
        speechList.reload(blocks, pages: pages.count)
        speechList.select(selected)
        table.reloadData()                  // the rows' times come from the timeline
        updateReference()                   // and so does the page header's
        strip.blocks = blocks
        strip.duration = max(blocks.map(\.end).max() ?? 0, evidence?.speech.map(\.end).max() ?? 0)
        strip.selectedPage = selected
        mode.setEnabled(!blocks.isEmpty, forSegment: 0)
        mode.setToolTip(blocks.isEmpty ? (finalizing ? "文字整理好后，可以按时间看每一页说了什么" : "这次录音没有分句时间，只能看全文")
                                       : "按时间看每一页说了什么", forSegment: 0)
        // by time when there is a timeline (after recording); the whole text otherwise, or once the user picked one
        if blocks.isEmpty, mode.selectedSegment == Mode.timeline { mode.selectedSegment = Mode.words; modeChanged() }
        else if !blocks.isEmpty, !recording, !modeChosen, mode.selectedSegment == Mode.words { mode.selectedSegment = Mode.timeline; modeChanged() }
    }

    /// the page's stretches as text: 0:12 – 0:31, or 0:12 – 0:31 等 2 段
    private func times(of page: Int) -> String {
        let mine = blocks.filter { $0.pageIndex == page }
        guard let first = mine.first, let last = mine.last else { return "" }
        return boardClock(first.start) + " – " + boardClock(last.end) + (mine.count > 1 ? "（\(mine.count) 段）" : "")
    }

    // MARK: split views: the sidebar 200–340 pt; the picture at least 260 pt, what was said at least 120 pt
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        260
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        splitView.bounds.height - Self.lowestPane
    }
    private static let lowestPane: CGFloat = 132   // the column's three choices and a line of status

    /// The lower pane takes the room its content needs — the marks' cards, or a reading height for the timeline and
    /// the whole text — and never more than 45 % of the height; the picture gets the rest. Redone when the cards,
    /// the tab or the window size change (a divider dragged by hand holds until then).
    private func fitLowerPane() {
        let total = detailSplit.bounds.height
        guard total > 0, detailSplit.subviews.count == 2, !focusMode else { return }
        var want: CGFloat = 300
        if let chosenLowerHeight {
            // the user's own height wins, kept within what the window can give
            want = min(max(chosenLowerHeight, Self.lowestPane), total - 260 - detailSplit.dividerThickness)
        } else {
            if mode.selectedSegment == Mode.marks {
                let cards = CGFloat(markList.rows.count) * BoardMarkCardRow.height
                want = BoardStyle.tight + (markList.rows.isEmpty ? 132 : cards + BoardStyle.inner)
            }
            want = min(max(want, Self.lowestPane), (total * 0.45).rounded())
        }
        let position = (total - want - detailSplit.dividerThickness).rounded()
        guard abs(detailSplit.subviews[0].frame.height - position) > 0.5 else { return }
        fitting = true
        detailSplit.setPosition(position, ofDividerAt: 0)
        fitting = false
    }
    /// The divider was dragged by hand: that height is the lower pane's from now on (and in later windows).
    func lowerPaneChosen(_ height: CGFloat) {
        chosenLowerHeight = height.rounded()
        lowerPaneStore?.set(Double(height.rounded()), forKey: Self.lowerPaneKey)
    }
    /// A double-click on the divider: back to fitting the lower pane to its content.
    func useAutomaticLowerPane() {
        chosenLowerHeight = nil
        lowerPaneStore?.removeObject(forKey: Self.lowerPaneKey)
        fitLowerPane()
    }
    func windowDidResize(_ notification: Notification) { fitLowerPane() }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: 0, dy: -6)
    }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== splitView.subviews.last
    }

    @objc private func modeClicked() { modeChosen = true; modeChanged() }
    @objc private func modeButtonClicked(_ sender: BoardModeButton) {
        guard let i = modeButtons.firstIndex(of: sender) else { return }
        mode.selectedSegment = i
        modeClicked()
    }
    private static let modeColumn: CGFloat = 104
    private var modeChosen = false
    @objc private func modeChanged() {
        let panes: [(NSView, Int)] = [(speechPane, Mode.timeline), (wordsScroll, Mode.words), (markList, Mode.marks)]
        for (pane, which) in panes {
            let show = mode.selectedSegment == which
            // the pane coming in fades up, quickly (a cross-fade between the three views)
            if show, pane.isHidden { pane.wantsLayer = true; BoardMotion.fade(pane.layer, from: 0, to: 1, duration: 0.2) }
            pane.isHidden = !show
        }
        for (i, b) in modeButtons.enumerated() { b.isOn = i == mode.selectedSegment }
        fitLowerPane()
    }

    private func pick(page: Int) {
        guard pages.indices.contains(page), page != selected else { return }
        table.selectRowIndexes(IndexSet(integer: page), byExtendingSelection: false)
        table.scrollRowToVisible(page)
    }

    private func focus(page: Int?) {
        speechList.select(page)
        strip.selectedPage = page
        guard let page, let y = speechList.top(of: page) else { return }
        speechScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - 4)))
        speechScroll.reflectScrolledClipView(speechScroll.contentView)
    }

    /// A sentence edited in the timeline: the timeline keeps the new words, and the same sentence in the whole text
    /// (what is copied) is changed too.
    private func edit(_ old: BoardSpeechSegment, to text: String) {
        guard !recording, !finalizing else { return }
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != old.text.trimmingCharacters(in: .whitespacesAndNewlines), var e = evidence,
              let i = e.speech.firstIndex(of: old) else { return }
        e.speech[i].text = new
        let whole = words.string as NSString
        let range = whole.range(of: old.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if range.location != NSNotFound {
            words.string = whole.replacingCharacters(in: range, with: new)
            editedTranscript = true
            note.stringValue = "已改这一句，全文也一起改了"
        } else {
            note.stringValue = "已改这一句；全文里没找到原句（可能已经在全文里改过），全文没有变"
        }
        editingSentence = true
        evidence = e
        editingSentence = false
        onEvidence?(e)
    }
    private var editingSentence = false

    private func play(_ s: BoardSpeechSegment) {
        playStop?.invalidate(); playStop = nil
        if playing == s { player?.stop(); playing = nil; speechList.setPlaying(nil); return }
        guard let audio else { return }
        if player?.url != audio { player = try? AVAudioPlayer(contentsOf: audio) }
        guard let player else { note.stringValue = "这次记录的录音无法播放"; return }
        player.currentTime = max(0, s.start - 0.15)
        player.play()
        playing = s
        speechList.setPlaying(s)
        playStop = Timer.scheduledTimer(withTimeInterval: max(0.3, s.end - s.start + 0.3), repeats: false) { [weak self] _ in
            self?.player?.stop(); self?.playing = nil; self?.speechList.setPlaying(nil)
        }
    }

    func show() {
        startAutoMerge()
        window.center()
        if recording { window.orderFrontRegardless() }
        else { BoardHome.prepareForDisplay(); presentWindow(window) }
    }
    func setFinalizing(_ value: Bool) {
        finalizing = value
        words.isEditable = !recording && !value
        speechList.editable = !recording && !value
        speechList.reload(blocks, pages: pages.count)
        deliveryButtons.forEach { $0.isEnabled = !value }
        deliveryItems.forEach { $0.isEnabled = !value }
        if value {
            note.stringValue = "正在整理文字…"
            note.toolTip = "正在从原始录音整理文字，可以先检查图片"
            note.textColor = .secondaryLabelColor
        }
    }
    func finishTranscript(_ transcript: String, warning: String?) {
        originalTranscript = transcript
        if !editedTranscript { reveal.reset(); words.string = transcript }
        setFinalizing(false)
        note.stringValue = warning ?? "文字已整理好"
        note.toolTip = warning == nil ? "文字已整理好；在「全文」里修改不会覆盖原始转写" : warning
        note.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
    }
    func deliveryStatus(_ text: String, failed: Bool) {
        note.stringValue = text
        if failed { show() }
    }
    func hideForDelivery() { window.orderOut(nil) }
    func updateTranscript(_ transcript: String) {
        guard recording || (finalizing && !editedTranscript) else { return }
        // while recording, only the newly said words come in (Apple Intelligence style); otherwise set as before
        if recording { reveal.set(transcript) } else { reveal.reset(); words.string = transcript }
        originalTranscript = transcript
    }
    private lazy var reveal = BoardWordsReveal(words)
    func textDidChange(_ notification: Notification) { if !recording && !finalizing { editedTranscript = true } }
    @objc private func restoreWords() {
        guard !finalizing else { return }
        words.string = originalTranscript
        editedTranscript = true
        mode.selectedSegment = Mode.words; modeChanged()
    }

    // MARK: the page list

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { BoardPageSelectionRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("board.page")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BoardPageRowView ?? BoardPageRowView()
        cell.identifier = identifier
        let page = pages[row]
        let missing = BoardReadableExport.unexplained(page.markEvidence, onPage: page.contextIDs, evidence: evidence).count
        cell.show(number: row + 1, thumb: page.thumb, time: times(of: row), marks: page.marks.count, unexplained: missing,
                  included: page.included)
        cell.check.tag = row
        cell.check.target = self
        cell.check.action = #selector(rowChecked(_:))
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring else { return }
        let next = table.selectedRow >= 0 ? table.selectedRow : nil
        guard next != selected else { return }
        // the page being left gets its marked picture redrawn now (its marks are already kept in `pages`)
        if let selected { render(selected) }
        showPage(next)
    }
    private var restoring = false
    private func showPage(_ index: Int?) {
        notePopover.close()
        selected = index
        splitItem.isEnabled = !recording && index.map { pages.indices.contains($0) && !pages[$0].components.isEmpty } == true
        defer { updateSwitcher() }
        focus(page: index)
        markCanvas.selected = nil
        let empty = imageScroll.superview?.subviews.first { $0.identifier?.rawValue == "empty" }
        guard let index, pages.indices.contains(index),
              let image = pages[index].original.flatMap({ loadCGImage($0) ?? BoardFileWriter.recoveryImage($0) })
                ?? pages[index].images.first.flatMap(loadCGImage) else {
            shownImage = nil
            updateFocusItem()
            picture.image = nil
            pictureCard.frame = .zero
            markCanvas.sheet = BoardMarkSheet(strokes: [], evidence: [], firstFree: 1)
            markCanvas.isHidden = true
            shownTitle = pages.isEmpty ? nil : ("第 \((index ?? 0) + 1) 页", "图片找不到了")
            updateSubtitle()
            empty?.isHidden = false
            emptyTitle.stringValue = pages.isEmpty ? "这次没有截图" : "图片找不到了"
            emptyDetail.stringValue = pages.isEmpty ? "录音和文字已经保存，可以在下方查看" : "截图文件可能被移动或删除了"
            marksChanged()
            return
        }
        empty?.isHidden = true
        updateReference()
        shownImage = image
        updateFocusItem()
        imageScroll.magnification = 1
        layoutPicture()
        imageScroll.contentView.scroll(to: .zero)
        imageScroll.reflectScrolledClipView(imageScroll.contentView)
        markCanvas.sheet = sheet(of: index)
        markCanvas.isHidden = false
        marksChanged()
    }
    /// Fits the shown picture to the viewport: whole when it is wide, the full width (scrolling) when it is tall.
    private func layoutPicture() {
        guard let image = shownImage, let index = selected, pages.indices.contains(index) else { return }
        let viewport = imageScroll.contentSize
        laidOut = viewport
        let pad = BoardStyle.picturePad
        // full-size markup with ‹ n / N › under the picture: keep the picture clear of it
        let below: CGFloat = focusMode && !pageSwitcher.isHidden ? 64 : 0
        // the tool columns at the left (and the zoom button at the right) stay clear of the picture
        let side = max(pad, 16 + BoardSideTools.width + 12)
        let available = CGSize(width: max(80, viewport.width - side * 2), height: max(80, viewport.height - pad * 2 - below))
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = h > w ? available.width / w : min(available.width / w, available.height / h)
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        canvas.setFrameSize(CGSize(width: viewport.width, height: max(viewport.height, size.height + pad * 2)))
        let rect = CGRect(x: ((canvas.bounds.width - size.width) / 2).rounded(), y: ((canvas.bounds.height - below - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        picture.frame = rect
        pictureCard.frame = rect
        effectiveColors()
        picture.image = NSImage(cgImage: image, size: size)
        markCanvas.frame = rect
        markCanvas.lineWidth = max(1.5, scale * pages[index].lineWidth)
        // numbers stay readable however small the picture is shown
        markCanvas.badgeDiameter = max(18, boardBadgeDiameter(lineWidth: pages[index].lineWidth) * scale)
        markCanvas.needsDisplay = true
    }
    /// Layer colours are not dynamic: set for the current light or dark appearance.
    private func effectiveColors() {
        picture.effectiveAppearance.performAsCurrentDrawingAppearance {
            picture.layer?.borderColor = NSColor.separatorColor.cgColor
            pictureCard.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            pictureCard.layer?.shadowColor = NSColor.shadowColor.cgColor
        }
    }
    /// The window was resized: the picture follows; the marks are kept normalized, so they just redraw.
    @objc private func viewportChanged() {
        guard shownImage != nil, !markCanvas.drawing, imageScroll.contentSize != laidOut else { return }
        imageScroll.magnification = 1
        layoutPicture()
    }

    // MARK: zoom

    @objc func boardZoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func boardZoomOut(_ sender: Any?) { zoom(by: 0.8) }
    @objc func boardZoomFit(_ sender: Any?) { zoom(to: 1) }
    private func zoomKey(_ key: String) -> Bool {
        guard shownImage != nil else { return false }
        switch key { case "+", "=": boardZoomIn(nil); case "-": boardZoomOut(nil); default: boardZoomFit(nil) }
        return true
    }
    private func zoom(by factor: CGFloat) { zoom(to: imageScroll.magnification * factor) }
    /// Zooms about the middle of what is in view, so the thing being looked at stays put.
    private func zoom(to value: CGFloat) {
        guard shownImage != nil else { return }
        let m = min(max(value, imageScroll.minMagnification), imageScroll.maxMagnification)
        let visible = imageScroll.documentVisibleRect
        imageScroll.setMagnification(m, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    }
    /// The title bar's page: its name, when it was on screen, and its marks.
    private func updateReference() {
        guard let selected, pages.indices.contains(selected) else { shownTitle = nil; updateSubtitle(); return }
        let marks = pages[selected].markEvidence.map { String($0.number) }.joined(separator: "、")
        let time = times(of: selected)
        shownTitle = ("第 \(selected + 1) 页", [time, marks.isEmpty ? "" : "标记 " + marks].filter { !$0.isEmpty }.joined(separator: " · "))
        updateSubtitle()
    }

    // MARK: marks and the undo history

    private static let toolChoices: [(symbol: String, label: String, tip: String, tool: BoardMarkCanvas.Tool)] = [
        ("cursorarrow", "选择", "选择：点标记选中，⌫ 删除；拖动空白处移动图片（Esc）", .select),
        ("scribble", "自由画", "自由画", .pen(.free)),
        ("rectangle", "矩形", "矩形", .pen(.box)),
        ("circle", "圆圈", "圆圈", .pen(.ellipse)),
    ]
    private func setTool(_ index: Int) {
        let i = Self.toolChoices.indices.contains(index) ? index : 0
        if sideTools.selectedIndex != i { sideTools.selectedIndex = i }
        markCanvas.tool = Self.toolChoices[i].tool
    }

    private var nextNumber: Int { (pages.flatMap(\.markEvidence).map(\.number).max() ?? 0) + 1 }
    private func sheet(of i: Int) -> BoardMarkSheet {
        BoardMarkSheet(strokes: pages[i].marks, evidence: pages[i].markEvidence, firstFree: nextNumber)
    }
    private static func signature(_ page: BoardSession.Page) -> RenderedMarks {
        RenderedMarks(marks: page.marks, numbers: page.markEvidence.map(\.number))
    }

    /// A stroke drawn on the shown page: the next free number, flagged as drawn in review; it is selected at once so
    /// its note can be written.
    func addMark(_ points: [[Double]]) {
        guard let s = selected else { return }
        let number = nextNumber
        edit(page: s, "画标记") { $0.add(points, number: number) }
        markCanvas.selected = number
        if !focusMode { markList.focusNote(number) }
    }
    func deleteMark(_ number: Int) {
        guard let s = selected else { return }
        edit(page: s, "删除标记 \(number)") { $0.remove(number: number) }
    }
    func setNote(_ text: String, mark number: Int) {
        guard let s = selected, sheet(of: s).index(of: number) != nil else { return }
        var probe = sheet(of: s)
        guard probe.setNote(text, number: number) else { return }
        edit(page: s, "修改说明") { $0.setNote(text, number: number) }
    }
    private func markSelected(_ number: Int?) {
        marksSelectionChanged(number)
        if focusMode, let number { showNote(number) }
    }

    /// Every change to a page's marks is one undo step. A page gains the AI's check with its first mark and loses it
    /// with its last; otherwise the user's choice stays.
    private func edit(page i: Int, _ name: String, _ body: (inout BoardMarkSheet) -> Void) {
        guard pages.indices.contains(i) else { return }
        _ = ensureOriginal(i)            // before the undo snapshot, so an undo never forgets a copied original
        var sheet = self.sheet(of: i)
        let before = pages[i].marks.count
        body(&sheet)
        change(name) {
            pages[i].marks = sheet.strokes
            pages[i].markEvidence = sheet.evidence
            pages[i].included = BoardPageInclusion.after(change: before, to: sheet.marks.count, included: pages[i].included)
        }
    }
    private struct Snapshot { var pages: [BoardSession.Page]; var selected: Int? }
    /// One undoable step over the pages (marks, notes, checks, order, deletions): an undo puts the pages, and the
    /// page shown, back as they were; a redo puts them forward again.
    private func change(_ name: String, structural: Bool = false, _ body: () -> Void) {
        let before = Snapshot(pages: pages, selected: selected)
        body()
        remember(before, name)
        refresh(structural: structural)
    }
    private func remember(_ state: Snapshot, _ name: String) {
        let grouped = !undo.groupsByEvent && !undo.isUndoing && !undo.isRedoing
        if grouped { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { me in
            let now = Snapshot(pages: me.pages, selected: me.selected)
            let structural = me.pages.map(\.images) != state.pages.map(\.images) || me.selected != state.selected
            me.pages = state.pages
            me.selected = state.selected
            me.remember(now, name)
            me.refresh(structural: structural)
        }
        undo.setActionName(name)
        if grouped { undo.endUndoGrouping() }
    }
    /// Shows the pages as they now are. The same page with changed marks keeps its zoom and scroll.
    private func refresh(structural: Bool) {
        let target = selected.flatMap { pages.indices.contains($0) ? $0 : nil } ?? (pages.isEmpty ? nil : 0)
        restoring = true
        reloadList()
        if let target { table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false) } else { table.deselectAll(nil) }
        restoring = false
        if structural || target != selected { showPage(target); return }
        guard let s = selected else { return }
        let keep = markCanvas.selected
        markCanvas.sheet = sheet(of: s)
        markCanvas.selected = keep
        updateReference()
        marksChanged()
    }
    @objc private func undoLast() { if undo.canUndo { undo.undo() } }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    /// Redraws a page's marked picture when its marks changed since it was last drawn. False when that failed.
    @discardableResult private func render(_ i: Int) -> Bool {
        guard pages.indices.contains(i), let url = pages[i].images.first else { return false }
        let signature = Self.signature(pages[i])
        guard rendered[url] != signature else { return true }
        guard let original = ensureOriginal(i), let image = loadCGImage(original) ?? BoardFileWriter.recoveryImage(original),
              let output = renderBoardMarked(image, strokes: pages[i].marks, evidence: pages[i].markEvidence, lineWidth: pages[i].lineWidth),
              writePNG(output, to: url) else { return false }
        rendered[url] = signature
        BoardFileWriter.acceptWritten(url)
        pages[i].imageNeedsRepair = false
        pages[i].thumb = BoardSession.thumbnail(output)
        table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
        return true
    }
    /// The clean picture marks are drawn over. A record from before originals were kept has only its marked picture:
    /// the first edit copies it as the original (its old marks stay burnt in; new ones go over them).
    private func ensureOriginal(_ index: Int) -> URL? {
        if let original = pages[index].original { return original }
        guard let image = pages[index].images.first else { return nil }
        if let made = madeOriginals[image] { pages[index].original = made; return made }
        let copy = image.deletingLastPathComponent().appendingPathComponent("原图-\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: image, to: copy)) != nil else { return nil }
        madeOriginals[image] = copy
        pages[index].original = copy
        return copy
    }
    /// Hands the pages to the session, every marked picture brought up to date first. The review never drops a page
    /// on its own: one whose marks were all removed stays (unchecked); only the user deletes pages.
    private func publish() -> Bool {
        window.makeFirstResponder(nil)       // a note still being typed is kept
        let failed = pages.indices.filter { !render($0) }.map { String($0 + 1) }
        onSave?(pages, editedTranscript ? words.string : nil)
        guard failed.isEmpty else {
            note.stringValue = "第 \(failed.joined(separator: "、")) 页的标注图片没能更新；标记已保存，请重试"
            note.textColor = .systemOrange
            return false
        }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing || publish() { return true }
        let alert = NSAlert()
        alert.messageText = "有标注图片没能更新"
        alert.informativeText = note.stringValue + "。标记和说明已经保存在记录里，图片会在下次修改这一页时重画。"
        alert.addButton(withTitle: "仍然关闭")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        let used = pages.reduce(into: Set<URL>()) { $0.formUnion($1.allFiles) }
        madeFiles.subtracting(used).forEach { try? FileManager.default.removeItem(at: $0) }
        player?.stop(); playStop?.invalidate()
        undo.removeAllActions()
        onClose?()
    }
    @discardableResult func closeSaving() -> Bool {
        guard publish() else { return false }
        closing = true
        window.close()
        return true
    }
    @objc private func saveClose() { window.performClose(nil) }
    @objc private func rowChecked(_ sender: NSButton) { setIncluded(sender.state == .on, page: sender.tag) }
    func setIncluded(_ on: Bool, page row: Int) {
        guard pages.indices.contains(row) else { return }
        change(on ? "勾选交给 AI" : "取消交给 AI") { pages[row].included = on }
    }
    @objc private func up() { move(-1) }
    @objc private func down() { move(1) }
    private func move(_ delta: Int) {
        guard let s = selected, pages.indices.contains(s + delta) else { return }
        change("移动页面", structural: true) {
            pages.swapAt(s, s + delta)
            selected = s + delta
        }
    }
    /// Deleting a page asks first; even then ⌘Z brings it back until the window closes.
    @objc private func askRemove() {
        guard let s = selected, pages.indices.contains(s) else { return }
        let alert = NSAlert()
        alert.messageText = "删除第 \(s + 1) 页？"
        let marks = pages[s].marks.count
        alert.informativeText = (marks > 0 ? "这一页的截图和 \(marks) 个标记会从记录里删除" : "这一页的截图会从记录里删除")
            + "；录音和文字不受影响。关闭窗口前可以用 ⌘Z 撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove() }
        }
    }
    @objc private func remove() {
        guard let s = selected else { return }
        change("删除第 \(s + 1) 页", structural: true) {
            pages.remove(at: s)
            selected = pages.isEmpty ? nil : min(s, pages.count - 1)
        }
    }

    // MARK: long pictures

    /// After recording, pages the record proves are one document scrolled down become one long picture
    /// (BoardAutoMerge). It runs once, off the main thread, and lands as one undoable step — and only if the pages are
    /// still exactly as they were when it started.
    private func startAutoMerge() {
        guard !recording, !autoMergeStarted, pages.count > 1, let inputs = evidence?.inputs, !inputs.isEmpty else { return }
        autoMergeStarted = true
        let before = pages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = BoardAutoMerge.run(before, inputs: inputs)
            DispatchQueue.main.async {
                guard let self, !self.closing, !result.joined.isEmpty,
                      self.pages.map(\.images) == before.map(\.images), self.pages.map(\.marks) == before.map(\.marks) else {
                    result.made.forEach { try? FileManager.default.removeItem(at: $0) }
                    return
                }
                self.applyAutoMerge(result)
            }
        }
    }
    private func applyAutoMerge(_ result: BoardAutoMerge.Result) {
        madeFiles.formUnion(result.made)
        let first = result.origin.firstIndex { $0.count > 1 }
        change("合成长图", structural: true) {
            pages = result.pages
            selected = first ?? selected.map { min($0, pages.count - 1) }
        }
        let names = result.joined.map { group in group.count == 2 ? "第 \(group[0])、\(group[1]) 页" : "第 \(group[0])–\(group.last!) 页" }
        note.stringValue = names.joined(separator: "，") + " 是同一页面往下滚动，已合成长图；不要的话按 ⌘Z 撤销，或在「…」里拆开"
        note.textColor = .secondaryLabelColor
    }
    /// The shown long picture back into the screen pictures it was made from; they are never joined automatically again.
    @objc private func splitLongImage() {
        guard let s = selected, pages.indices.contains(s), !pages[s].components.isEmpty else { return }
        let parts: [BoardSession.Page]
        do { parts = try BoardPageFiles.split(pages[s]).map { var part = $0; part.keepApart = true; return part } }
        catch { note.stringValue = "拆开失败：" + error.localizedDescription; note.textColor = .systemOrange; return }
        madeFiles.formUnion(parts.flatMap(\.images))
        change("拆开长图", structural: true) {
            pages.replaceSubrange(s...s, with: parts)
            selected = s
        }
        note.stringValue = "已拆开成 \(parts.count) 页"
        note.textColor = .secondaryLabelColor
    }

    // MARK: the marks list

    /// The shown page's marks as rows of the 标记 tab (and its count on the tab).
    private func marksChanged() {
        var rows: [BoardMarkList.Row] = []
        if let s = selected, pages.indices.contains(s) {
            // what was said from the mark before to the mark after (BoardEvidence.said)
            let marks = sheet(of: s).evidence
            let around = evidence?.said(about: marks, onPage: pages[s].contextIDs) ?? [:]
            rows = marks.map { mark in
                let time: String
                if let a = mark.start?.audio { time = boardClock(a) }
                else if mark.isAdded { time = "补画" }
                else if let e = mark.start?.elapsed { time = "会话 " + boardClock(e) }
                else { time = "未记录" }
                return BoardMarkList.Row(number: mark.number, time: time,
                                         quote: Self.quoted(around[mark.number] ?? []),
                                         note: mark.note ?? "")
            }
        }
        markList.reload(rows, selected: markCanvas.selected, page: selected != nil && shownImage != nil)
        fitLowerPane()
        if !fixButton.isHidden, unexplainedMarks().isEmpty {
            fixButton.isHidden = true
            note.stringValue = "所有标记都有说明了"; note.textColor = .secondaryLabelColor
        }
    }
    /// Sentences as one line of quotes: “…” “…”; nil when nothing was said.
    private static func quoted(_ said: [BoardSpeechSegment]) -> String? {
        let parts = said.map { "“" + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) + "”" }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    /// A mark picked on the picture: its row comes up in the 标记 tab.
    private func marksSelectionChanged(_ number: Int?) {
        deleteItem?.isEnabled = number != nil
        markList.select(number)
        if number != nil, mode.selectedSegment != Mode.marks { mode.selectedSegment = Mode.marks; modeChanged() }
    }

    // MARK: delivery

    private func prepareExport() -> BoardFolderExport.Bundle? {
        guard !finalizing, publish() else { return nil }
        guard let onExport else { note.stringValue = "导出暂不可用，请重新打开这条记录。"; return nil }
        do {
            let export = try onExport(pages, words.string)
            lastExportFolder = export.directory
            return export
        } catch {
            note.stringValue = "图片导出失败，未复制或粘贴：" + error.localizedDescription
            return nil
        }
    }
    /// 仅复制: the whole description with the pictures' paths, ready to paste to an AI; the window stays.
    @discardableResult @objc private func copyWords() -> Bool {
        guard let export = prepareExport() else { return false }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(export.text, forType: .string) else {
            note.stringValue = "图片已导出，但复制失败，请打开导出文件夹查看"; return false
        }
        let missing = unexplainedMarks().count
        note.stringValue = missing == 0 ? "已复制说明和图片路径" : "已复制；有 \(missing) 个标记没有说明"
        note.textColor = missing == 0 ? .secondaryLabelColor : .systemOrange
        fixButton.isHidden = missing == 0
        return true
    }
    /// 复制并关闭 (the toolbar's primary action): copy, then close (it has just been saved). Marks that would reach
    /// the AI as bare numbers are pointed out first; copying is still the default.
    @objc private func copyAndClose() {
        window.makeFirstResponder(nil)          // a note still being typed counts
        let missing = unexplainedMarks()
        guard !missing.isEmpty else { if copyWords() { closeSaving() }; return }
        let alert = NSAlert()
        alert.messageText = "有 \(missing.count) 个标记还没有说明"
        alert.informativeText = "标记 " + missing.map { String($0.number) }.joined(separator: "、")
            + " 既没有写说明，附近也没有说话。AI 只会看到编号，不知道这里要改什么。"
        alert.addButton(withTitle: "仍然复制并关闭")
        alert.addButton(withTitle: "去补说明")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { if self.copyWords() { self.closeSaving() } }
            else { self.goToUnexplained() }
        }
    }
    /// Checked pages' marks with no note and no sentence said near them, in page order.
    func unexplainedMarks() -> [(page: Int, number: Int)] {
        pages.indices.filter { pages[$0].included }.flatMap { i in
            BoardReadableExport.unexplained(pages[i].markEvidence, onPage: pages[i].contextIDs, evidence: evidence)
                .map { (page: i, number: $0.number) }
        }
    }
    /// Shows the first unexplained mark, selected, with the keyboard in its note.
    @objc func goToUnexplained() {
        guard let first = unexplainedMarks().first else { fixButton.isHidden = true; return }
        if selected != first.page { table.selectRowIndexes(IndexSet(integer: first.page), byExtendingSelection: false) }
        markCanvas.selected = first.number
        markList.focusNote(first.number)
    }
    @objc private func openExportFolder() {
        guard !finalizing else { return }
        if let lastExportFolder, FileManager.default.fileExists(atPath: lastExportFolder.path) {
            NSWorkspace.shared.open(lastExportFolder)
        } else if let export = prepareExport() { NSWorkspace.shared.open(export.directory) }
    }
    @objc private func copyImage() {
        guard let selected, render(selected), let url = pages[selected].images.first,
              let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        note.stringValue = "已复制当前图片"
    }
}

extension BoardReviewWindow {
    /// Renders a saved record's review window to a PNG, read-only (nothing is saved: the window is closed directly).
    static func renderArchive(_ directory: URL, to path: String, page: Int = 1, size: NSSize? = nil, dark: Bool = false) {
        _ = NSApplication.shared
        let rows = (try? Data(contentsOf: directory.appendingPathComponent("页面.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let started = CACurrentMediaTime()
        let pages = rows.compactMap { BoardPageFiles.decode($0, directory: directory) }
        let text = (try? String(contentsOf: directory.appendingPathComponent("完整转写.txt"), encoding: .utf8)) ?? ""
        let w = BoardReviewWindow(pages: pages, transcript: text, recording: false)
        w.evidence = BoardEvidence.load(directory)
        w.audio = directory.appendingPathComponent("原始录音.wav")
        emit(["event": "review_archive_preview", "open_ms": Int((CACurrentMediaTime() - started) * 1000),
              "blocks": w.blocks.map { ["page": $0.pageIndex ?? -1, "sentences": $0.segments.count] }])
        w.lowerPaneStore = nil
        if dark { w.window.appearance = NSAppearance(named: .darkAqua) }
        if let size { w.window.setContentSize(size) }
        if w.pages.indices.contains(page - 1) { w.table.selectRowIndexes(IndexSet(integer: page - 1), byExtendingSelection: false) }
        w.window.orderFront(nil)
        w.fitLowerPane()
        if ProcessInfo.processInfo.environment["POINT_TAKEN_PREVIEW_FOCUS"] == "1" {
            w.setFocus(true)
            w.sidebarItem?.isCollapsed = true          // no animation in a still
            w.window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if ProcessInfo.processInfo.environment["POINT_TAKEN_PREVIEW_STRIP"] == "1" {
                w.revealStrip()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            }
        }
        let frame = w.window.contentView!.superview!
        frame.layoutSubtreeIfNeeded(); frame.display()
        if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        w.window.close()
    }

    /// Uses generated pixels and temporary files only: no microphone, screen stream or clipboard.
    static func runWorkflowCheck() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("point-taken-workflow-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [String: Bool] = [:]
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 100, y: 150, width: 240, height: 90))
        let source = context.makeImage()!
        let raw = directory.appendingPathComponent("raw.png"), marked = directory.appendingPathComponent("marked.png")
        _ = writePNG(source, to: raw); _ = writePNG(source, to: marked)
        let page = BoardSession.Page(images: [marked], text: "页面说明", thumb: source, original: raw,
                                     included: false, scene: "test", sourceFrames: [raw])
        let live = BoardReviewWindow(pages: [page], transcript: "开场背景", recording: true)
        checks["live_review_never_key"] = !live.window.canBecomeKey && !live.window.canBecomeMain
        live.updateTranscript("开场背景。后来补充的要求。")
        checks["live_transcript_keeps_growing"] = live.words.string.contains("后来补充") && !live.words.isEditable
        live.window.close()
        let review = BoardReviewWindow(pages: [page, page], transcript: "开场背景。最后补充。", recording: false)
        checks["speech_only_requires_confirmation"] = !review.pages[0].included
        checks["final_text_editable"] = review.words.isEditable && review.window.canBecomeKey
        review.undo.groupsByEvent = false       // no run loop here: one undo step per change
        let first: [[Double]] = [[0.05, 0.05], [0.2, 0.2]], second: [[Double]] = [[0.5, 0.5], [0.7, 0.6]]
        review.addMark(first)
        checks["ink_round_trip"] = review.render(0) && review.pages[0].marks == [first]
        checks["new_mark_selected_for_its_note"] = review.markCanvas.selected == review.pages[0].markEvidence.first?.number
        checks["first_mark_checks_page"] = review.pages[0].included && review.window.title == "第 1 页"
        checks["review_mark_flagged_added"] = review.pages[0].markEvidence.map(\.isAdded) == [true]
        checks["click_is_not_a_mark"] = !BoardMarkCanvas.isMark([CGPoint(x: 10, y: 10)]) && !BoardMarkCanvas.isMark([CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)])
            && BoardMarkCanvas.isMark([CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)])
        do {
            let n1 = review.pages[0].markEvidence[0].number
            review.addMark(second)
            review.deleteMark(n1)
            checks["delete_one_mark_keeps_others"] = review.pages[0].marks == [second] && review.pages[0].markEvidence.map(\.number) == [n1 + 1]
            review.undo.undo()
            checks["undo_restores_deleted_mark"] = review.pages[0].marks == [first, second] && review.pages[0].markEvidence.map(\.number) == [n1, n1 + 1]
            review.undo.redo()
            checks["redo_deletes_again"] = review.pages[0].markEvidence.map(\.number) == [n1 + 1]
            review.setNote("  改成圆角 ", mark: n1 + 1)
            checks["note_saved_with_its_mark"] = review.pages[0].markEvidence.first?.note == "改成圆角"
            checks["marks_tab_lists_the_page"] = review.markList.rows.map(\.number) == [n1 + 1]
                && review.markList.rows.first?.time == "补画" && review.markList.rows.first?.note == "改成圆角"
                && review.mode.selectedSegment == Mode.marks
            review.markList.onNote?(n1 + 1, "改成 8pt 圆角")
            checks["list_note_edits_its_mark"] = review.pages[0].markEvidence.first?.note == "改成 8pt 圆角"
            review.markCanvas.selected = nil
            review.markList.onSelect?(n1 + 1)
            checks["list_selects_on_picture"] = review.markCanvas.selected == n1 + 1
            review.undo.undo()          // the list's note edit
            review.deleteMark(n1 + 1)
            checks["last_mark_unchecks_but_keeps_page"] = review.pages.count == 2 && !review.pages[0].included && review.pages[0].marks.isEmpty
            review.undo.undo(); review.undo.undo(); review.undo.undo()   // the delete, the note, the redone delete
            checks["undo_walks_back"] = review.pages[0].markEvidence.map(\.number) == [n1, n1 + 1] && review.pages[0].markEvidence[1].note == nil
            review.deleteMark(n1 + 1)
            review.remove()
            let afterRemove = review.pages.count
            review.undo.undo()
            checks["undo_restores_deleted_page"] = afterRemove == 1 && review.pages.count == 2 && review.pages[0].marks == [first] && review.selected == 0
            review.window.setContentSize(NSSize(width: 1180, height: 800))
            review.boardZoomIn(nil); review.boardZoomIn(nil)
            let zoomed = review.imageScroll.magnification
            review.boardZoomFit(nil)
            do {
                // page 0 now has mark n1 (no note, no time): it is pointed out, and 去补 goes to it
                review.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                checks["unexplained_found"] = review.unexplainedMarks().map(\.number) == [n1]
                review.goToUnexplained()
                checks["go_to_unexplained"] = review.selected == 0 && review.markCanvas.selected == n1
                review.setNote("这里去掉", mark: n1)
                checks["noted_mark_explained"] = review.unexplainedMarks().isEmpty
                review.undo.undo()
            }
            do {
                review.lowerPaneStore = nil
                review.mode.selectedSegment = Mode.marks; review.modeChanged()
                let auto = review.detailSplit.subviews[1].frame.height
                review.lowerPaneChosen(260)
                review.fitLowerPane()
                review.marksChanged()
                let held = review.detailSplit.subviews[1].frame.height
                review.useAutomaticLowerPane()
                checks["lower_pane_user_height_holds"] = abs(held - 260) < 1
                    && abs(review.detailSplit.subviews[1].frame.height - auto) < 1
            }
            do {
                let before = review.selected
                review.setFocus(true)
                let entered = review.focusMode && review.lowerPane?.isHidden == true && !review.pageSwitcher.isHidden
                review.step(1)
                let stepped = review.selected == (before ?? 0) + 1
                review.notePopover.onCommit?(review.pages[1].markEvidence.first?.number ?? -1, "全屏里写的说明")
                let stripHiddenAtFirst = review.pageStrip.isHidden && !review.edgeSensor.isHidden
                review.revealStrip()
                let stripOut = !review.pageStrip.isHidden && review.stripShown
                review.pageStrip.onPick?(0)
                let picked = review.selected == 0
                review.step(1)
                checks["focus_page_strip_from_left_edge"] = stripHiddenAtFirst && stripOut && picked
                review.setFocus(false)
                checks["focus_markup_enters_steps_and_leaves"] = entered && stepped && !review.focusMode
                    && review.lowerPane?.isHidden == false && review.pageSwitcher.isHidden
                review.step(-1)
            }
            checks["zoom_in_and_back"] = zoomed > 1.5 && abs(review.imageScroll.magnification - 1) < 0.001
        }
        do {
            // the review opens before the whole recording is transcribed: when the sentences arrive, each mark's card
            // must pick up what was said around it (it stayed at 还没有说明 before)
            let t0 = BoardMoment(elapsed: 3.7, audio: 3.7), t1 = BoardMoment(elapsed: 5.2, audio: 5.2)
            let spoken = BoardSession.Page(images: [marked], text: "", thumb: source, original: raw, marks: [[[0.2, 0.2], [0.4, 0.3]]],
                                           scene: "test", sourceFrames: [raw], contextIDs: ["p"],
                                           markEvidence: [BoardMarkEvidence(number: 1, start: t0, end: t1)])
            let early = BoardReviewWindow(pages: [spoken], transcript: "", recording: false)
            early.evidence = BoardEvidence()
            let before = early.markList.rows.first?.quote == nil && early.unexplainedMarks().count == 1
            var arrived = BoardEvidence()
            arrived.visits = [BoardVisit(pageID: "p", app: "", title: "", start: .init(elapsed: 0.2, audio: 0.2), end: .init(elapsed: 8.9, audio: 8.9))]
            arrived.speech = [BoardSpeechSegment(start: 0.37, end: 7.21, text: "Like you can see here, we should replace them.")]
            early.evidence = arrived
            checks["marks_pick_up_late_transcript"] = before && early.markList.rows.first?.quote?.contains("replace them") == true
                && early.unexplainedMarks().isEmpty
            early.closing = true; early.window.close()
        }
        do {
            // a record from before originals were kept: the first edit copies the marked picture as the original
            let legacyImage = directory.appendingPathComponent("legacy.png")
            _ = writePNG(source, to: legacyImage)
            let legacy = BoardReviewWindow(pages: [BoardSession.Page(images: [legacyImage], text: "", thumb: source)],
                                           transcript: "", recording: false)
            legacy.addMark(first)
            let original = legacy.pages[0].original
            legacy.undo.undo()
            checks["legacy_page_editable"] = legacy.render(0) && original.map { FileManager.default.fileExists(atPath: $0.path) } == true
                && legacy.pages[0].original == original
            legacy.closing = true; legacy.window.close()
        }
        review.down()
        checks["reorder_carries_ink"] = review.selected == 1 && review.pages[1].marks.count == 1 && review.pages[0].marks.isEmpty
        review.setIncluded(true, page: 1)
        checks["confirm_selects_image"] = review.pages[1].included
        var saved: [BoardSession.Page] = [], text = "开场背景。最后补充。"
        var untouched = false
        review.onSave = { saved = $0; untouched = $1 == nil; if let edit = $1 { text = edit } }
        review.remove()
        review.remove()
        _ = review.publish()
        checks["delete_images_preserves_all_words"] = saved.isEmpty && text == "开场背景。最后补充。"
        checks["untouched_review_does_not_override_transcript"] = untouched
        review.words.string = ""
        review.textDidChange(Notification(name: NSText.didChangeNotification, object: review.words))
        _ = review.publish()
        checks["explicit_text_edit_saved_separately"] = !untouched && text.isEmpty
        review.restoreWords()
        _ = review.publish()
        checks["restore_full_original_transcript"] = text == "开场背景。最后补充。"
        let clipboardVersion = NSPasteboard.general.changeCount
        review.onExport = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        review.copyWords()
        checks["export_failure_leaves_clipboard_unchanged"] = NSPasteboard.general.changeCount == clipboardVersion && review.note.stringValue.contains("导出失败")
        review.onExport = { pages, transcript in
            try BoardSession.exportFolder(pages: pages, transcript: transcript, evidence: nil, root: directory.appendingPathComponent("exports"))
        }
        let handoff = review.prepareExport()
        checks["review_export_preserves_complete_text"] = handoff?.text.contains("开场背景。最后补充。") == true
        let finalizingReview = BoardReviewWindow(pages: [page], transcript: "实时文字", recording: false)
        finalizingReview.setFinalizing(true)
        checks["finalizing_text_locked"] = !finalizingReview.words.isEditable && finalizingReview.deliveryButtons.allSatisfy { !$0.isEnabled }
        checks["finalizing_sentences_locked"] = !finalizingReview.speechList.editable
        _ = finalizingReview.closeSaving()
        finalizingReview.finishTranscript("从原始录音还原的完整文字", warning: nil)
        checks["closed_review_not_reopened_by_transcription"] = !finalizingReview.window.isVisible
        checks["full_transcript_replaces_live_text"] = finalizingReview.words.string == "从原始录音还原的完整文字" && finalizingReview.words.isEditable
        // Exercise the adapter, not just the vendor algorithm: three pages, editable ink, source retention.
        do {
            let w = 320, h = 1000
            let drawing = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            var noise: UInt64 = 7
            for y in 0..<h { for x in stride(from: 0, to: w, by: 8) {
                noise = noise &* 6364136223846793005 &+ 1
                drawing.setFillColor(CGColor(gray: CGFloat(noise >> 56) / 255, alpha: 1))
                drawing.fill(CGRect(x: x, y: y, width: 8, height: 1))
            } }
            let document = drawing.makeImage()!
            var input: [BoardSession.Page] = []
            for index in 0..<3 {
                let image = document.cropping(to: CGRect(x: 0, y: index * 200, width: w, height: 400))!
                let url = directory.appendingPathComponent("source-\(index).png")
                _ = writePNG(image, to: url)
                input.append(BoardSession.Page(images: [url], text: "", thumb: nil, original: url,
                                                marks: [[[0.2, index == 0 ? 0.1 : 0.8]]], scene: "same-window", sourceFrames: [url]))
            }
            let two = try BoardLongImage.merge(input[0], input[1])
            let three = try BoardLongImage.merge(two, input[2])
            let output = loadCGImage(three.original!)!
            checks["long_image_three_pages"] = output.height == 800 && output.width == w
            checks["long_image_ink_coordinates"] = abs(three.marks[0][0][1] - 0.05) < 0.001
                && abs(three.marks[1][0][1] - 0.65) < 0.001 && abs(three.marks[2][0][1] - 0.9) < 0.001
            checks["long_image_originals_retained"] = input.allSatisfy { three.allFiles.contains($0.original!) && FileManager.default.fileExists(atPath: $0.original!.path) }
            let frame0 = BoardScreenFeed.Frame(image: loadCGImage(input[0].original!)!, displayID: 1, bounds: CGRect(x: 0, y: 0, width: w, height: 400), scene: "same-window")
            let frame1 = BoardScreenFeed.Frame(image: loadCGImage(input[1].original!)!, displayID: 1, bounds: frame0.bounds, scene: frame0.scene)
            let frame2 = BoardScreenFeed.Frame(image: loadCGImage(input[2].original!)!, displayID: 1, bounds: frame0.bounds, scene: frame0.scene)
            let following = BoardLiveScroll(page: input[0], frame: frame0)
            let filesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            let followed = try following.advance(to: frame1, retainNewContent: false)
            let filesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            checks["unmarked_scroll_tracks_ink_without_saving"] = followed && following.offset == 200
                && following.page.images == input[0].images && following.page.sourceFrames == input[0].sourceFrames
                && filesBefore == filesAfter
            let scroll = BoardLiveScroll(page: input[0], frame: frame0)
            let advanced = try scroll.advance(to: frame1)
            checks["scroll_follows_document_pixels"] = advanced && scroll.offset == 200 && abs(scroll.viewportMarks[0][0][1] + 0.4) < 0.001
            try scroll.add([[0.4, 0.5]])
            checks["new_scroll_mark_maps_to_document"] = abs(scroll.page.marks.last![0][1] - (400.0 / 600.0)) < 0.001
            let markCount = scroll.page.marks.count
            checks["scroll_undo_updates_saved_document"] = try scroll.undo() && scroll.page.marks.count == markCount - 1
            try scroll.add([[0.4, 0.5]])
            checks["scroll_extends_automatically"] = try scroll.advance(to: frame2)
            checks["scroll_reverse_keeps_long_image"] = try scroll.advance(to: frame1)
            checks["reverse_offset_correct"] = scroll.offset == 200 && loadCGImage(scroll.page.original!)!.height == 800
            let restored = BoardPageFiles.decode(BoardPageFiles.encode(scroll.page), directory: directory)!
            let parts = try BoardPageFiles.split(restored)
            checks["auto_long_image_split_after_reload"] = parts.count == 3 && parts[0].marks.count >= 1 && parts[1].marks.contains { abs($0[0][1] - 0.5) < 0.001 }
            let unrelated = BoardScreenFeed.Frame(image: frame1.image, displayID: 1, bounds: frame0.bounds, scene: "another-page")
            checks["live_scroll_refuses_other_page"] = try !scroll.advance(to: unrelated)
            var different = input[1]; different.scene = "other-window"
            do { _ = try BoardLongImage.merge(input[0], different); checks["long_image_refuses_other_windows"] = false }
            catch { checks["long_image_refuses_other_windows"] = true }
            var overlapInk = input[1]; overlapInk.marks = [[[0.3, 0.1]]]
            do { _ = try BoardLongImage.merge(input[0], overlapInk); checks["long_image_never_discards_overlap_ink"] = false }
            catch { checks["long_image_never_discards_overlap_ink"] = true }
        } catch { checks["long_image_adapter"] = false }
        // Automatic long pictures: two screens of one document under pinned bars (a toolbar, a Dock), the second
        // scrolled 150 px down. Only a proven downward scroll joins them; everything weaker keeps them apart.
        do {
            let w = 480, h = 600, bar = 40, dock = 30
            func document(_ seed: UInt64) -> CGImage {
                let ctx = CGContext(data: nil, width: w, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                var noise = seed
                for y in 0..<2000 { for x in stride(from: 0, to: w, by: 8) {
                    noise = noise &* 6364136223846793005 &+ 1
                    ctx.setFillColor(CGColor(gray: CGFloat(noise >> 56) / 255, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: 8, height: 1))
                } }
                return ctx.makeImage()!
            }
            func screen(_ doc: CGImage, at offset: Int) -> CGImage {
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(doc.cropping(to: CGRect(x: 0, y: offset, width: w, height: h - bar - dock))!,
                         in: CGRect(x: 0, y: dock, width: w, height: h - bar - dock))
                ctx.setFillColor(CGColor(gray: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - bar, width: w, height: bar))
                ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: dock))
                return ctx.makeImage()!
            }
            func page(_ image: CGImage, _ name: String, at time: Double, marks: [([Double], Int)]) -> BoardSession.Page {
                let url = directory.appendingPathComponent("scroll-\(name).png")
                _ = writePNG(image, to: url)
                return BoardSession.Page(images: [url], text: "", thumb: nil, original: url, marks: marks.map { [$0.0] },
                                         scene: "safari-window", sourceFrames: [url],
                                         markEvidence: marks.map { BoardMarkEvidence(number: $0.1) }, capturedAt: time)
            }
            let doc = document(11)
            let top = page(screen(doc, at: 0), "top", at: 10, marks: [([0.3, 0.3], 1)])
            // the second page carries mark 1 (still on screen after the scroll, now on the toolbar) and adds mark 2,
            // drawn on content both screens show
            let lower = page(screen(doc, at: 150), "lower", at: 14, marks: [([0.3, 0.05], 1), ([0.6, 0.5], 2)])
            let scrolled = [BoardInput(kind: .scroll, at: 12, dy: -150)]
            let joined = BoardAutoMerge.run([top, lower], inputs: scrolled)
            let long = joined.pages.first
            checks["auto_long_image_joins_proven_scroll"] = joined.pages.count == 1 && joined.joined == [[1, 2]]
                && long.flatMap { $0.original.flatMap(loadCGImage)?.height } == h - dock + 150
            checks["auto_long_image_keeps_marks_on_their_content"] = long.map {
                $0.markEvidence.map(\.number) == [1, 2] && $0.marks.count == 2
                    && abs($0.marks[0][0][1] - 180.0 / 720) < 0.002 && abs($0.marks[1][0][1] - 450.0 / 720) < 0.002
            } ?? false
            checks["auto_long_image_splits_back"] = long.map { (try? BoardPageFiles.split($0))?.count == 2 } ?? false
            func stays(_ a: BoardSession.Page, _ b: BoardSession.Page, _ inputs: [BoardInput]) -> Bool {
                BoardAutoMerge.run([a, b], inputs: inputs).pages.count == 2
            }
            checks["auto_long_image_needs_scroll_input"] = stays(top, lower, [])
                && stays(top, lower, [BoardInput(kind: .scroll, at: 20, dy: -150)])
            checks["auto_long_image_refuses_click_or_key_between"] = stays(top, lower, scrolled + [BoardInput(kind: .click, at: 13)])
                && stays(top, lower, scrolled + [BoardInput(kind: .key, at: 11)])
            checks["auto_long_image_refuses_upward_scroll"] = stays(top, lower, [BoardInput(kind: .scroll, at: 12, dy: 150)])
            var apart = lower; apart.keepApart = true
            var otherWindow = lower; otherWindow.scene = "another-window"
            checks["auto_long_image_respects_split_and_window"] = stays(top, apart, scrolled) && stays(top, otherWindow, scrolled)
            checks["auto_long_image_refuses_unproven_pixels"] = stays(top, page(screen(document(99), at: 150), "other", at: 14, marks: []), scrolled)
                && stays(top, page(screen(doc, at: 0), "same", at: 14, marks: []), scrolled)
            checks["auto_long_image_refuses_ink_on_pinned_bar"] = stays(top, page(screen(doc, at: 150), "bar", at: 14, marks: [([0.5, 0.03], 3)]), scrolled)
            // in the window: it happens by itself after opening, ⌘Z takes it back, and a split stays split
            let window = BoardReviewWindow(pages: [top, lower], transcript: "", recording: false)
            window.lowerPaneStore = nil
            var record = BoardEvidence(); record.inputs = scrolled
            window.evidence = record
            let deadline = Date().addingTimeInterval(15)
            while window.pages.count != 1, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            checks["review_joins_scrolled_pages_by_itself"] = window.pages.count == 1 && window.note.stringValue.contains("合成长图")
            window.undo.undo()
            checks["review_long_image_undo"] = window.pages.count == 2
            window.undo.redo()
            window.splitLongImage()
            checks["review_split_long_image_stays_apart"] = window.pages.count == 2 && window.pages.allSatisfy(\.keepApart)
                && BoardAutoMerge.run(window.pages, inputs: scrolled).pages.count == 2
            window.closing = true; window.window.close()
        }
        // Synthetic UI rendering for visual QA, never the user's desktop.
        // three pages, each with its time on screen, and the sentences said: the timeline groups them by page
        var shown: [BoardSession.Page] = []
        var evidence = BoardEvidence()
        let spans: [(Double, Double)] = [(0, 21.4), (21.4, 47.8), (47.8, 80)]
        for (i, span) in spans.enumerated() {
            let shot = BoardPreview.sampleScreen(CGSize(width: 1440, height: 900), hue: [0.58, 0.35, 0.08][i])
            let url = directory.appendingPathComponent("page-\(i).png")
            _ = writePNG(shot, to: url)
            let id = "page-\(i)"
            shown.append(BoardSession.Page(images: [url], text: "", thumb: BoardSession.thumbnail(shot), original: url,
                                           marks: [[[0.3, 0.3], [0.5, 0.45]]], included: i != 1, scene: "test",
                                           sourceFrames: [url], contextIDs: [id],
                                           markEvidence: [BoardMarkEvidence(number: i + 1, start: .init(elapsed: span.0 + 6, audio: span.0 + 6),
                                                                            end: .init(elapsed: span.0 + 8, audio: span.0 + 8))]))
            evidence.visits.append(BoardVisit(pageID: id, app: "Safari", title: "页面 \(i + 1)",
                                              start: BoardMoment(elapsed: span.0, audio: span.0), end: BoardMoment(elapsed: span.1, audio: span.1)))
        }
        let said = ["先说一下背景：这是给老人用的。", "首页的字太小了，按钮也不好点。", "这里的搜索框最好放在最上面。",
                    "第二页是设置。", "开关的说明看不懂，改成一句话说清楚。", "这个蓝色太亮了，换成柔和一点的颜色。",
                    "最后这一页是结算。", "价格要大一点，按钮放在右下角。", "其他的保持原来的样子就行。"]
        let at: [(Double, Double)] = [(1.2, 5.8), (6.4, 12.9), (14, 20.1), (22.3, 24.9), (25.6, 33.2), (34, 45.5),
                                      (49, 52.4), (53.1, 63.8), (66, 71.5)]
        evidence.speech = zip(said, at).map { BoardSpeechSegment(start: $1.0, end: $1.1, text: $0) }
        evidence.speechTimingSource = "original-audio-file"
        // hold-to-draw keys: labels, and which modifiers alone hold which tool (the defaults; nothing is saved)
        checks["hold_key_labels"] = BoardHoldKey(mods: [.option]).label == "⌥" && BoardHoldKey(mods: [.shift, .option]).label == "⌥⇧"
            && BoardHoldKey(mods: [.control], code: kVK_ANSI_D).label == "⌃D" && BoardHoldKey(mods: [], code: kVK_F5).label == "F5"
            && BoardHoldKey(mods: [], code: kVK_ANSI_D).takesTyping && !BoardHoldKey(mods: [.command], code: kVK_ANSI_D).takesTyping
        let holdKeys = BoardHoldKeys()
        checks["hold_key_defaults"] = holdKeys.tool(for: [.option]) == .free && holdKeys.tool(for: [.option, .shift]) == .box
            && holdKeys.tool(for: [.command]) == nil && holdKeys.tool(for: []) == nil
        let blocks = BoardSpeechBlock.build(pages: shown, evidence: evidence)
        checks["timeline_groups_sentences_by_page"] = blocks.map(\.pageIndex) == [0, 1, 2] && blocks.map(\.segments.count) == [3, 3, 3]
        let preview = BoardReviewWindow(pages: shown, transcript: said.joined(), recording: false)
        preview.evidence = evidence
        preview.audio = raw
        preview.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        preview.window.setContentSize(NSSize(width: 1180, height: 800))
        preview.window.orderFront(nil)
        for (path, appearance) in [("/tmp/point-taken-review-preview.png", NSAppearance.Name.aqua), ("/tmp/point-taken-review-preview-dark.png", .darkAqua)] {
            preview.window.appearance = NSAppearance(named: appearance)
            let frame = preview.window.contentView!.superview!
            frame.layoutSubtreeIfNeeded()
            frame.display()
            if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            }
        }
        emit(["event": "review_preview_layout", "window": NSStringFromRect(preview.window.frame),
              "content": NSStringFromRect(preview.window.contentView!.frame),
              "panes": (preview.window.contentView as? NSSplitView)?.arrangedSubviews.map { NSStringFromRect($0.frame) } ?? [],
              "detail": preview.detailSplit.arrangedSubviews.map { NSStringFromRect($0.frame) }])
        preview.window.close(); review.window.close()
        let ok = checks.values.allSatisfy { $0 }
        emit(["event": "board_workflow_check", "ok": ok, "checks": checks])
        exit(ok ? 0 : 1)
    }
}

/// While recording, newly said words come in like Apple Intelligence's text: one character a quick beat after the
/// other, left to right, each floating up a few points out of a soft glow of its own colour. A second pass that
/// rewrites words already shown swaps them in place, without the animation. Only what changed is touched: the text before it keeps its place. Reduce Motion: the words just appear.
/// The characters are drawn by BoardRevealLayoutManager (each arriving one carries its start time as an attribute),
/// so the animation never re-lays out the text.
final class BoardWordsReveal {
    private weak var view: NSTextView?
    private var manager: BoardRevealLayoutManager?
    /// the first character that may still be coming in
    private var scanFrom = Int.max
    private var animEnd: CFTimeInterval = 0
    private var timer: Timer?
    static let duration = 0.42
    static let step = 0.016
    static let spread = 0.3

    init(_ view: NSTextView) { self.view = view }

    /// The text without animation from here on (it was set wholesale).
    func reset() {
        timer?.invalidate(); timer = nil
        scanFrom = .max; animEnd = 0
    }

    func set(_ text: String) {
        guard let v = view else { return }
        if manager == nil, let tc = v.textContainer {
            let m = BoardRevealLayoutManager()
            tc.replaceLayoutManager(m)
            manager = m
        }
        guard let ts = v.textStorage else { return }
        let old = ts.string as NSString, new = text as NSString
        var common = 0
        let n = min(old.length, new.length)
        while common < n, old.character(at: common) == new.character(at: common) { common += 1 }
        if common < new.length { common = min(common, new.rangeOfComposedCharacterSequence(at: common).location) }
        if common < old.length { common = min(common, old.rangeOfComposedCharacterSequence(at: common).location) }
        guard common < old.length || common < new.length else { return }
        let added = NSMutableAttributedString(string: new.substring(from: common), attributes: v.typingAttributes)
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if motion, added.length > 0 {
            let now = CACurrentMediaTime()
            var units: [NSRange] = []
            (added.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: added.length),
                                                           options: .byComposedCharacterSequences) { _, r, _, _ in units.append(r) }
            // only what goes past the end of what was shown is new speech; a second pass rewriting words already
            // shown swaps them in place, quietly
            let tail = units.filter { common + $0.location >= old.length }
            let gap = min(Self.step, Self.spread / Double(max(1, tail.count - 1)))
            for (i, r) in tail.enumerated() { added.addAttribute(.boardReveal, value: now + Double(i) * gap, range: r) }
            if !tail.isEmpty {
                animEnd = max(animEnd, now + Double(tail.count - 1) * gap + Self.duration)
                scanFrom = min(scanFrom, common)
            }
        }
        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: common, length: old.length - common), with: added)
        ts.endEditing()
        if motion, timer == nil, animEnd > CACurrentMediaTime() {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        guard let v = view, let ts = v.textStorage, let m = manager else { return reset() }
        let from = min(scanFrom, ts.length)
        let r = NSRange(location: from, length: ts.length - from)
        guard CACurrentMediaTime() < animEnd else {
            // all in: drop the marks (the text is drawn plainly again) and stop
            ts.beginEditing(); ts.removeAttribute(.boardReveal, range: r); ts.endEditing()
            m.invalidateDisplay(forCharacterRange: r)
            return reset()
        }
        m.invalidateDisplay(forCharacterRange: r)
        // the glow and the float reach a little past the characters' own boxes
        v.setNeedsDisplay(v.visibleRect)
    }
}

extension NSAttributedString.Key {
    /// when this character starts coming in (CACurrentMediaTime seconds)
    static let boardReveal = NSAttributedString.Key("pointtaken.board.reveal")
}

/// Draws an arriving character (one marked `.boardReveal`) where its reveal is: floating up from 3 pt below, its
/// opacity rising, with a soft glow of its own colour that swells and fades. Everything else is drawn as usual.
final class BoardRevealLayoutManager: NSLayoutManager {
    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count: Int, font: NSFont,
                               textMatrix: CGAffineTransform, attributes: [NSAttributedString.Key: Any] = [:], in ctx: CGContext) {
        guard let born = attributes[.boardReveal] as? Double, count > 0 else {
            return super.showCGGlyphs(glyphs, positions: positions, count: count, font: font, textMatrix: textMatrix,
                                      attributes: attributes, in: ctx)
        }
        let now = CACurrentMediaTime()
        let p = (now - born) / BoardWordsReveal.duration
        guard p < 1 else {
            return super.showCGGlyphs(glyphs, positions: positions, count: count, font: font, textMatrix: textMatrix,
                                      attributes: attributes, in: ctx)
        }
        guard p > 0 else { return }                                  // not started: nothing yet
        let k = CGFloat(p)
        let rise = 1 - pow(1 - k, 3)                                 // floats up, slowing as it lands
        let opacity = 1 - pow(1 - min(1, k / 0.6), 2)
        let base = (attributes[.foregroundColor] as? NSColor ?? .labelColor).usingColorSpace(.sRGB) ?? .labelColor
        let glow = min(1, k * 4) * (1 - rise)
        var moved = (0..<count).map { CGPoint(x: positions[$0].x, y: positions[$0].y + 3 * (1 - rise)) }
        let fill = base.withAlphaComponent(base.alphaComponent * opacity)
        var attrs = attributes
        attrs[.foregroundColor] = fill
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2 + 5 * (1 - rise), color: base.withAlphaComponent(0.55 * glow).cgColor)
        ctx.setFillColor(fill.cgColor)
        super.showCGGlyphs(glyphs, positions: &moved, count: count, font: font, textMatrix: textMatrix, attributes: attrs, in: ctx)
        ctx.restoreGState()
    }
}
