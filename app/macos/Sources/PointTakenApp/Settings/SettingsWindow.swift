// The Settings window (⌘, from the menu; pointtaken://settings/<pane>[/<row>]): one resizable window, a sidebar and a page.
//   Sidebar  the search field on top (⌘F focuses it, Esc clears it, ↓ / ↑ walk the results, ↩ opens one), then the
//            panes in three small groups — Preferences: General, Dictation, Copy Text from Screen, Speech, Shortcuts ·
//            Work: Projects, Agents ·
//            This Mac: Privacy, Storage (SettingsCatalog.panes) — in an NSOutlineView like the main window's sidebar:
//            the brand-tint selection (BrandRowView), ↑ / ↓ move between panes. While searching, the panes with
//            matches show how many; the others are dimmed (with no match anywhere, none are).
//   Page     the pane (SwiftUI, SettingsKit's SettingsPage), or the search results (SettingsSearch.swift). Each pane's
//            page is kept once made, so switching back doesn't reload it.
// State (pane, query) lives in SettingsNavigator, the row to scroll to in SettingsFlash. The last pane is remembered
// (app.settings_pane).
// show(pane:) takes "speech" or "speech/dictation" (a row or section of that pane: scrolled to and flashed); nil opens
// the last pane, a name that isn't a pane (a stale link) opens General — never an unrelated pane from last time. A pane
// that moved (SettingsCatalog.moved: the old Export pane) opens where its settings went: Agents, at "Ask your agent".
import AppKit
import Combine
import ObjectiveC
import SwiftUI
import PointTakenCore

enum SettingsPane: String, CaseIterable {
    // the sidebar's order (SettingsCatalog.panes)
    case general, speech, shortcuts, privacy

    var available: Bool { true }
    var info: SettingsPaneInfo? { SettingsCatalog.pane(rawValue) }
    var title: String {
        if self == .privacy { return boardSettingText("权限", "Permissions") }
        if self == .speech { return boardSettingText("模型与 API", "Models & API") }
        return info.flatMap { SettingsCatalog.text($0.title) } ?? rawValue
    }
    var symbol: String { info?.symbol ?? "gearshape" }

    @MainActor
    func makeController() -> NSViewController {
        let view: AnyView
        switch self {
        case .general: view = AnyView(BoardGeneralPane())
        case .shortcuts: view = AnyView(ShortcutsPane())
        case .speech: view = AnyView(SpeechPane())
        case .privacy: view = AnyView(BoardPermissionsPane())
        }
        let vc = NSHostingController(rootView: view)
        vc.sizingOptions = []           // the window sizes the page, not the other way round
        vc.title = title
        return vc
    }
}

/// ⌘F (and the menu's Find) focuses the search field, wherever the focus is.
final class SettingsWindow: NSWindow {
    var onFind: (() -> Void)?
    /// Tests (`settingskeylook on`): draw as the key window while another app has the focus — the switches in the
    /// accent, the sidebar's selection in the brand tint — for screenshots taken without taking the focus.
    static var keyLook = false
    override var isKeyWindow: Bool { Self.keyLook || super.isKeyWindow }
    override var isMainWindow: Bool { Self.keyLook || super.isMainWindow }
    // AppKit's controls ask the window for its key / active *appearance* (the switch's accent track): answered here
    // while keyLook is on, else as NSWindow answers
    @objc(_hasActiveAppearance) func testHasActiveAppearance() -> Bool { Self.keyLook || superBool("_hasActiveAppearance") }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) func testHasActiveAppearanceIgnoringKeyFocus() -> Bool {
        Self.keyLook || superBool("_hasActiveAppearanceIgnoringKeyFocus")
    }
    @objc(_hasKeyAppearance) func testHasKeyAppearance() -> Bool { Self.keyLook || superBool("_hasKeyAppearance") }
    @objc(_hasMainAppearance) func testHasMainAppearance() -> Bool { Self.keyLook || superBool("_hasMainAppearance") }
    @objc(hasKeyAppearance) func testHasKeyAppearancePublic() -> Bool { Self.keyLook || superBool("hasKeyAppearance") }
    @objc(hasMainAppearance) func testHasMainAppearancePublic() -> Bool { Self.keyLook || superBool("hasMainAppearance") }
    private func superBool(_ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard let imp = class_getMethodImplementation(NSWindow.self, sel), NSWindow.instancesRespond(to: sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: F.self)(self, sel)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "f" {
            onFind?()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
    @objc func mFind() { onFind?() }
}

final class SettingsController: NSObject, SettingsHosting, NSWindowDelegate {
    static let shared = SettingsController()
    private var window: SettingsWindow?
    private var sidebar: SettingsSidebarController?
    private var detail: SettingsDetailController?
    private var subs: Set<AnyCancellable> = []

    @MainActor
    private func build() {
        let nav = SettingsNavigator.shared
        let side = SettingsSidebarController()
        let page = SettingsDetailController()
        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: side)
        // Lianbiao has four panes: a narrower sidebar leaves the room to the page
        sideItem.minimumThickness = BoardHome.enabled ? 160 : 190
        sideItem.maximumThickness = BoardHome.enabled ? 200 : 260
        sideItem.canCollapse = false
        sideItem.allowsFullHeightLayout = true          // the source list runs to the top, under the window's buttons
        let pageItem = NSSplitViewItem(viewController: page)
        pageItem.minimumThickness = 540
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(pageItem)

        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        w.contentViewController = split
        // the pane's name is the window's title, in the toolbar beside the window's buttons (System Settings): the
        // sidebar runs full height under them and the page starts right below
        w.title = T("settings.window.title")
        w.toolbar = NSToolbar(identifier: "PointTakenSettings")
        w.toolbarStyle = .unified
        w.titleVisibility = .visible
        w.titlebarAppearsTransparent = true
        w.minSize = BoardHome.enabled ? NSSize(width: 700, height: 480) : NSSize(width: 760, height: 520)
        w.setContentSize(BoardHome.enabled ? NSSize(width: 760, height: 560) : NSSize(width: 860, height: 620))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.onFind = { [weak side] in side?.focusSearch() }
        w.setFrameAutosaveName(BoardHome.enabled ? "BoardSettingsWindow" : "PointTakenSettingsWindow")
        // an ordinary window: screenshots (yours or ours) can show it; our own recordings leave it out by their filter
        window = w
        sidebar = side
        detail = page
        // the last pane, for next time (a pane chosen while the window is open counts, not only the one at closing)
        nav.$pane.removeDuplicates().sink { p in Config.shared.set("app.settings_pane", p.rawValue) }.store(in: &subs)
        // while searching, the query is the page's title ("“short”"): the results page doesn't say it twice
        nav.$pane.combineLatest(nav.$query.map { $0.trimmingCharacters(in: .whitespaces) }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak w] p, q in w?.title = q.isEmpty ? p.title : T("settings.search.title_query", q) }
            .store(in: &subs)
    }

    func show(pane: String?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let nav = SettingsNavigator.shared
                // "speech" or "speech/dictation": the pane, then a row or section of it; a pane that moved: where it went
                let link = SettingsCatalog.redirect(pane ?? "")
                if link != (pane ?? "") { emit(["event": "settings_moved_pane", "from": pane ?? "", "to": link]) }
                let parts = link.split(separator: "/", maxSplits: 1).map(String.init)
                let asked = parts.first.flatMap(SettingsPane.init(rawValue:))
                // no pane named: the last one picked; a name that isn't a pane (a stale link): General, never an
                // unrelated pane from last time
                if asked == nil, let p = parts.first, !p.isEmpty { emit(["event": "settings_unknown_pane", "pane": p]) }
                let last = SettingsCatalog.redirect(Config.shared["app.settings_pane"] as? String ?? "").split(separator: "/").first
                let want = asked ?? (parts.first?.isEmpty == false ? .general
                    : last.flatMap { SettingsPane(rawValue: String($0)) } ?? .general)
                nav.go(want)                    // before the window is made: only the pane asked for is built
                if window == nil { build() }
                if parts.count > 1 { nav.reveal(parts[1].contains(".") ? parts[1] : "\(want.rawValue).\(parts[1])") }
                activateApp()
                if window?.isVisible != true { window?.center() }
                window?.makeKeyAndOrderFront(nil)
                // ⌘, (or any open without a row to show): the cursor in the search field, ready to type, as Claude Code's
                // settings do; a link to a row keeps the list's focus (the row is what it came for)
                if parts.count > 1 || BoardHome.enabled { sidebar?.focusList() } else { sidebar?.focusSearch() }
                // in front even when macOS doesn't hand Point Taken the focus (the permission guide brings it back from
                // System Settings without a click on Point Taken)
                window?.orderFrontRegardless()
                emit(["event": "settings", "pane": want.rawValue])
            }
        }
    }

    var visiblePane: String? {
        guard window?.isVisible == true else { return nil }
        return MainActor.assumeIsolated { SettingsNavigator.shared.pane.rawValue }
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    /// Tests (`settingsscroll top|bottom|N`): scroll the visible page, for a screenshot of its lower part.
    @MainActor
    func scrollPane(_ to: String) -> Bool {
        guard let root = detail?.view else { return false }
        var queue = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let s = v as? NSScrollView, let doc = s.documentView {
                // under the transparent toolbar the page's top is at minus the top inset: "top" and offsets count from
                // there, and a page shorter than the window never moves
                let minY = -s.contentView.contentInsets.top
                let maxY = max(minY, doc.frame.height - s.contentView.bounds.height)
                let y = to == "bottom" ? maxY : to == "top" ? minY : min(maxY, minY + (Double(to) ?? 0))
                s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : maxY - y))
                s.reflectScrolledClipView(s.contentView)
                return true
            }
            queue += v.subviews
        }
        return false
    }

    /// Tests (`settingskeylook on|off`): see SettingsWindow.keyLook.
    @MainActor
    func testKeyLook(_ on: Bool) {
        SettingsWindow.keyLook = on
        guard let w = window else { return }
        NotificationCenter.default.post(name: on ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: w)
        NotificationCenter.default.post(name: on ? NSWindow.didBecomeMainNotification : NSWindow.didResignMainNotification, object: w)
        for name in on ? ["acquireMainAppearance", "acquireKeyAppearance"] : ["resignKeyAppearance", "resignMainAppearance"] {
            let sel = NSSelectorFromString(name)
            if w.responds(to: sel) { w.perform(sel) }
        }
        func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
        w.contentView.map(redraw)
    }

    /// Tests (`settingssearch TEXT`): type into the search field as a person would.
    @MainActor
    func testSearch(_ text: String) { sidebar?.setSearch(text) }

    func windowWillClose(_ notification: Notification) {
        ShortcutField.active?.stop()
        if let p = visiblePane { Config.shared.set("app.settings_pane", p) }
    }
}

// MARK: - The page

/// The right side: the pane's page or the search results. Pages are made once and kept (their models keep what they
/// loaded), as the old tab view did.
final class SettingsDetailController: NSViewController {
    private var pages: [SettingsPane: NSViewController] = [:]
    private lazy var results: NSViewController = {
        let vc = NSHostingController(rootView: SettingsSearchResults())
        vc.sizingOptions = []
        return vc
    }()
    private var current: NSViewController?
    private var subs: Set<AnyCancellable> = []

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 620)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nav = SettingsNavigator.shared
        nav.$pane.combineLatest(nav.$query.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] pane, searching in MainActor.assumeIsolated { self?.show(searching ? nil : pane) } }
            .store(in: &subs)
    }

    @MainActor
    private func show(_ pane: SettingsPane?) {
        let vc: NSViewController
        if let p = pane {
            if let made = pages[p] { vc = made } else { vc = p.makeController(); pages[p] = vc }
        } else { vc = results }
        guard vc !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.width, .height]
        view.addSubview(vc.view)
        current = vc
    }
}

// MARK: - The sidebar

final class SettingsNode: NSObject {
    let title: String
    let pane: SettingsPane?          // nil = a group's label
    var children: [SettingsNode] = []
    init(_ title: String, pane: SettingsPane?, children: [SettingsNode] = []) {
        self.title = title; self.pane = pane; self.children = children
    }
}

final class SettingsSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField()
    let outline = NSOutlineView()
    private var roots: [SettingsNode] = []
    private var syncing = false
    private var subs: Set<AnyCancellable> = []

    override func loadView() {
        search.placeholderString = T("settings.search.placeholder")
        search.setAccessibilityLabel(T("settings.search.placeholder"))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.isHidden = BoardHome.enabled
        search.controlSize = .regular
        (search.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: .init("pane"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel(T("settings.window.title"))
        scroll.documentView = outline

        let root = NSView()
        // dark mode: a neutral ground under the source list, so the sidebar's material doesn't carry the wallpaper's
        // blue next to the page's neutral grey (§2.4: neutrals never tint); light mode keeps the material as it is
        let ground = NeutralSidebarGround()
        for v in [ground, search, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: root.topAnchor),
            ground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // under the window's buttons (the titlebar is transparent; the sidebar runs to the top)
            search.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        if BoardHome.enabled { search.heightAnchor.constraint(equalToConstant: 0).isActive = true }
        view = root
        view.frame = NSRect(x: 0, y: 0, width: BoardHome.enabled ? 172 : 210, height: 620)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        roots = SettingsCatalog.groups.map { g in
            SettingsNode(SettingsCatalog.text(g.title) ?? g.id, pane: nil,
                         children: SettingsPane.allCases.filter { $0.available && $0.info?.group == g.id }.map { SettingsNode($0.title, pane: $0) })
        }
        if BoardHome.enabled {
            roots = [SettingsNode(boardSettingText(PointTaken.nameZh, PointTaken.nameEn), pane: nil,
                                  children: SettingsPane.allCases.filter(\.available).map { SettingsNode($0.title, pane: $0) })]
        }
        outline.reloadData()
        for r in roots { outline.expandItem(r) }
        let nav = SettingsNavigator.shared
        nav.$pane.receive(on: RunLoop.main).sink { [weak self] p in MainActor.assumeIsolated { self?.reflect(pane: p) } }.store(in: &subs)
        nav.$hits.receive(on: RunLoop.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.reflectSearch() } }.store(in: &subs)
        nav.$query.receive(on: RunLoop.main).sink { [weak self] q in
            guard let self = self, self.search.stringValue != q else { return }
            self.search.stringValue = q
        }.store(in: &subs)
    }

    @MainActor func focusSearch() {
        if BoardHome.enabled { focusList(); return }
        view.window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }
    @MainActor func focusList() { view.window?.makeFirstResponder(outline) }
    @MainActor func setSearch(_ text: String) {
        search.stringValue = text
        SettingsNavigator.shared.query = text
    }

    /// The selected row follows the pane; while searching nothing is selected (the page shows the results).
    @MainActor private func reflect(pane: SettingsPane) {
        syncing = true
        defer { syncing = false }
        if SettingsNavigator.shared.searching { outline.deselectAll(nil); return }
        for r in roots { for c in r.children where c.pane == pane {
            let row = outline.row(forItem: c)
            if row >= 0, outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } }
    }

    @MainActor private func reflectSearch() {
        syncing = true
        if SettingsNavigator.shared.searching { outline.deselectAll(nil) }
        syncing = false
        for r in roots { for c in r.children { outline.reloadItem(c) } }
        if !SettingsNavigator.shared.searching { reflect(pane: SettingsNavigator.shared.pane) }
    }

    // MARK: search field

    func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated { SettingsNavigator.shared.query = search.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        MainActor.assumeIsolated {
            let nav = SettingsNavigator.shared
            switch sel {
            case #selector(NSResponder.moveDown(_:)):
                if nav.searching { nav.moveSelection(1) } else { focusList() }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if nav.searching { nav.moveSelection(-1); return true }
                return false
            case #selector(NSResponder.insertNewline(_:)):
                guard nav.searching else { return false }
                // "Show 9 more" stays in the search (the field keeps the keys); anything else opens its pane
                if nav.openSelected() { focusList() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if search.stringValue.isEmpty { return false }
                setSearch("")
                return true
            default:
                return false
            }
        }
    }

    // MARK: outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SettingsNode)?.children.count ?? roots.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SettingsNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SettingsNode)?.pane == nil }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SettingsNode)?.pane == nil }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SettingsNode)?.pane != nil }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SettingsNode else { return nil }
        guard let pane = n.pane else {
            let id = NSUserInterfaceItemIdentifier("SettingsHeader")
            let v = o.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let t = NSTextField(labelWithString: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                             t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                return c
            }()
            v.textField?.stringValue = n.title
            return v
        }
        let id = NSUserInterfaceItemIdentifier("SettingsPaneCell")
        let v = o.makeView(withIdentifier: id, owner: self) as? SettingsPaneCell ?? SettingsPaneCell(id: id)
        let nav = SettingsNavigator.shared
        v.set(title: n.title, symbol: pane.symbol, count: nav.sidebarCount(pane))
        return v
    }

    /// The brand selection (a rounded tint, text stays `labelColor`), like the main window's sidebar.
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { BrandRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let p = (outline.item(atRow: outline.selectedRow) as? SettingsNode)?.pane else { return }
        MainActor.assumeIsolated { SettingsNavigator.shared.go(p) }
    }
}

/// The sidebar's ground in dark mode: neutral grey (#262626) over the material, nearly opaque, so the wallpaper's hue
/// doesn't show through next to the neutral page; clear in light mode.
final class NeutralSidebarGround: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark ? NSColor(srgbRed: 0.149, green: 0.149, blue: 0.149, alpha: 0.92).cgColor : NSColor.clear.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A pane in the sidebar: its symbol, its name, and while searching how many of its settings match (dimmed at none).
/// Like the main window's sidebar (system.md §3.3): the name and symbol are not the cell's textField / imageView, which
/// a source list repaints in the accent when selected — the selected pane reads in ink on its highlight, never green
/// text. The symbol has no description of its own (the cell's label says the pane once).
final class SettingsPaneCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let badge = CountPill()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        for v in [icon, title, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        // not wired as imageView / textField: the source list would repaint them in the accent when selected — the
        // name stays labelColor on the brand tint, as in the main window's sidebar (system.md §3.3)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// count: nil = not searching; 0 = no match here (dimmed)
    func set(title t: String, symbol: String, count: Int?) {
        title.stringValue = t
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.setAccessibilityElement(false)
        title.setAccessibilityElement(false)
        let dim = count == 0
        title.textColor = dim ? .tertiaryLabelColor : .labelColor
        icon.contentTintColor = dim ? .tertiaryLabelColor : .secondaryLabelColor
        badge.text = count.map { $0 > 0 ? Loc.number($0) : "" } ?? ""
        badge.mint = false
        setAccessibilityLabel([t, badge.text.isEmpty ? nil : badge.text].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A count at the end of a settings sidebar row (search matches).
final class CountPill: NSView {
    var text = "" { didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var mint = false { didSet { if mint != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mint ? pillFont : font,
                                                      .foregroundColor: mint ? BrandColor.on : NSColor.secondaryLabelColor])
    }
    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return NSSize(width: 0, height: 16) }
        let w = ceil(attributed.size().width)
        return NSSize(width: mint ? max(18, w + 10) : w, height: 16)
    }
    override var allowsVibrancy: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        guard !text.isEmpty else { return }
        let s = attributed, ts = s.size()
        if mint {
            BrandColor.fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        s.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2))
    }
    override func isAccessibilityElement() -> Bool { false }      // the row says the count
}

/// The settings sidebar's selection: a rounded brand-tint wash (r 6), a neutral 6 % wash when the window isn't key.
class BrandRowView: NSTableRowView {
    /// The table still tells us when its window gains or loses key (it sets this): redraw the selection then.
    override var isEmphasized: Bool { get { false } set { if isSelected { needsDisplay = true } } }
    private var keyObservers: [NSObjectProtocol] = []
    /// Screenshots of a test build launched in the background (test commands only): POINT_TAKEN_TEST_KEY_LOOK=1 draws the
    /// selection as in a key window.
    static let testKeyLook = ProcessInfo.processInfo.environment["POINT_TAKEN_TEST_COMMANDS"] == "1"
        && ProcessInfo.processInfo.environment["POINT_TAKEN_TEST_KEY_LOOK"] == "1"

    /// The part of the row the selection covers (a row with a section header above it keeps the header unwashed).
    var selectionBand: NSRect { bounds }
    /// false when the next row starts a section (its header sits between them): the band stops at this row
    var nextOwnsBand = true

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let key = window?.isKeyWindow == true && NSApp.isActive || BrandRowView.testKeyLook
        (key ? BrandColor.tint : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        // the inset / source-list styles inset the row itself; a row as wide as its table keeps a margin like theirs
        let pad: CGFloat = frame.minX < 1 && abs(frame.width - (superview?.bounds.width ?? 0)) < 1 ? 10 : 0
        // adjacent selected rows read as one band (Finder, Mail): the wash runs into the gap between them and only the
        // band's outer ends are rounded
        // a row whose top band holds a section header starts a band of its own
        let own = selectionBand == bounds
        let up = isPreviousRowSelected && own, down = isNextRowSelected && nextOwnsBand
        var r = selectionBand.insetBy(dx: pad, dy: 0)
        let gap = Self.gap(self)
        if up { r.origin.y -= isFlipped ? gap : 0; r.size.height += gap }
        if down { r.origin.y -= isFlipped ? 0 : gap; r.size.height += gap }
        Self.band(r, top: !up, bottom: !down, flipped: isFlipped).fill()
    }

    /// The space between two rows' views (the inset style leaves one): half of it is this row's to fill.
    static func gap(_ v: NSTableRowView) -> CGFloat {
        guard let t = v.superview as? NSTableView ?? v.superview?.superview as? NSTableView else { return 0 }
        return max(0, (t.rowHeight + t.intercellSpacing.height - v.frame.height) / 2) + 0.5
    }

    /// A rectangle rounded (r 6) at its top and / or bottom only.
    static func band(_ r: NSRect, top: Bool, bottom: Bool, flipped: Bool) -> NSBezierPath {
        // in view coordinates the top edge is minY when flipped, maxY otherwise
        let (tY, bY) = flipped ? (r.minY, r.maxY) : (r.maxY, r.minY)
        let tr: CGFloat = top ? 6 : 0, br: CGFloat = bottom ? 6 : 0
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.midX, y: tY))
        p.appendArc(from: NSPoint(x: r.maxX, y: tY), to: NSPoint(x: r.maxX, y: bY), radius: tr)
        p.appendArc(from: NSPoint(x: r.maxX, y: bY), to: NSPoint(x: r.minX, y: bY), radius: br)
        p.appendArc(from: NSPoint(x: r.minX, y: bY), to: NSPoint(x: r.minX, y: tY), radius: br)
        p.appendArc(from: NSPoint(x: r.minX, y: tY), to: NSPoint(x: r.midX, y: tY), radius: tr)
        p.close()
        return p
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                if self?.isSelected == true { self?.needsDisplay = true }
            })
        }
    }

    deinit { keyObservers.forEach(NotificationCenter.default.removeObserver) }
}
