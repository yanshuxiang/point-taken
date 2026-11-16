// Multi-page annotation session. Input controls live in the nonactivating capsule.
// Originals, editable marks, continuous audio and the complete transcript are archived independently.
import AppKit
import AVFoundation
import PointTakenCore
import PointTakenObjC
import Carbon.HIToolbox
import Speech

// MARK: - colours (one colour, one meaning)

enum BoardColor {
    /// the capsule: solid near-black like the website's (#16161A); Liquid Glass read as washed-out grey over pages
    static let glass = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.10, alpha: 0.96)
    static let rim = NSColor(white: 1, alpha: 0.10)
    static let text = NSColor(white: 1, alpha: 0.94)
    static let secondary = NSColor(white: 1, alpha: 0.55)
    static let faint = NSColor(white: 1, alpha: 0.32)
    /// the pen and the marks
    static let pen = BrandColor.Island.markup
    /// the mic is live
    static let live = NSColor(srgbRed: 0.20, green: 0.84, blue: 0.42, alpha: 1)
    /// something needs the user
    static let warn = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.20, alpha: 1)
}

// MARK: - the session

final class BoardSession {
    static let shared = BoardSession()

    struct Page {
        var images: [URL]
        var text: String
        var thumb: CGImage?
        var original: URL? = nil
        var marks: [[[Double]]] = []
        var included = true
        var scene = ""
        var lineWidth: CGFloat = 4
        var footerTrim = 0
        var sourceFrames: [URL] = []
        var retainedFiles: [URL] = []
        var components: [Page] = []
        var componentOffsets: [Int] = []
        var contextIDs: [String] = []
        var markEvidence: [BoardMarkEvidence] = []
        var manuallySaved = false
        var imageNeedsRepair = false
        /// session seconds when the screen picture was taken (a long picture: its last part); nil in older records
        var capturedAt: Double? = nil
        /// the user split this long picture in the review: never join its parts automatically again
        var keepApart = false
        var allFiles: Set<URL> { Set(images + [original].compactMap { $0 } + sourceFrames + retainedFiles + components.flatMap { Array($0.allFiles) }) }
    }

    private(set) var active = false
    private var busy = false
    private(set) var paused = false
    private var finalizing = false
    var currentTranscriptionModel: String? { active || finalizing ? speech.transcriptionModel : nil }
    private(set) var pages: [Page] = []
    private var dir: URL?
    private var panels: [BoardInkPanel] = []
    let capsule = BoardCapsule()
    private let speech = BoardSpeech()
    private var timeline: BoardTimeline? = nil
    private var clock = BoardCaptureClock(now: ProcessInfo.processInfo.systemUptime)
    private var strokeStart: BoardMoment?
    private var strokeFrame: BoardScreenFeed.Frame?
    private var penDisplay: CGRect?
    private var nextMarkNumber = 1
    private var lastMetadataTick = 0.0
    private var moment: BoardMoment {
        BoardMoment(elapsed: clock.elapsed(at: ProcessInfo.processInfo.systemUptime), audio: speech.audioSeconds)
    }
    private var ticker: Timer?
    private(set) var selectedTool: InkTool?
    private(set) var penOn = false
    private let holdKeys = BoardHoldKeys()
    private var runner: PasteRunner?
    private var hintsThisSession = false
    private let screenFeed = BoardScreenFeed()
    private var liveScroll: BoardLiveScroll?
    private var livePage: Int?
    private let alignmentQueue = DispatchQueue(label: "pointtaken.board.alignment", qos: .userInitiated)
    private var aligning = false
    private var pendingScrollFrame: BoardScreenFeed.Frame?
    private var review: BoardReviewWindow?
    private var reviewedTranscript: String?
    private var archivedTranscript: String?
    private var screenWarning: String?
    var deliveryTranscript: String { reviewedTranscript ?? originalTranscript }
    private var originalTranscript: String { archivedTranscript ?? speech.fullText }

    var imageCount: Int { pages.reduce(0) { $0 + $1.images.count } }

    // MARK: keys

    /// The configurable shortcut only starts a session; it is released while recording.
    func hotkey() {
        if !active { start() }
    }

    func showIdle() {
        guard !active, runner == nil else { return }
        capsule.hide()
    }

    /// Suspend configurable keys independently from shortcut-editor suspension.
    static func yieldKeyboard(_ recording: Bool) {
        Hotkeys.shared.passesKeysToOtherApps = recording
        if recording {
            NSApp.keyWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
            NSApp.unhideWithoutActivation()
        }
    }

    func selectTool(_ tool: InkTool?) {
        selectedTool = tool
        syncPen()
        configureControls()
    }

    /// the tool the pen button turns back on (the last one used; freehand at first)
    private var lastTool: InkTool = .free

    /// The capsule's one row of controls, like the website's demo: the pen (on: drawing with the last tool, off:
    /// normal operation), the three shapes (the hold-to-draw key on each that has one), undo; pause; 完成.
    private func configureControls() {
        capsule.setControls(Self.capsuleControls(
            tool: selectedTool, paused: paused,
            pen: { [weak self] in
                guard let self else { return }
                self.holdKeys.release()
                if self.selectedTool == nil { self.selectTool(self.lastTool); self.keyTip(self.lastTool) } else { self.selectTool(nil) }
            },
            use: { [weak self] tool in
                guard let self else { return }
                self.holdKeys.release()
                if self.selectedTool == tool { self.selectTool(nil) } else { self.lastTool = tool; self.selectTool(tool); self.keyTip(tool) }
            },
            undo: { [weak self] in self?.undo() }, pause: { [weak self] in self?.togglePause() },
            save: { [weak self] in self?.nextPage() }, finish: { [weak self] in self?.finish() }))
    }
    /// A tool turned on by clicking: a short tip under the capsule that it can be drawn with its key held, for next
    /// time. Shown the first few times per tool, then left out.
    private func keyTip(_ tool: InkTool) {
        guard BoardHoldKey.tools.contains(tool) else { return }
        let seen = "board.keyTip." + tool.rawValue
        let shown = UserDefaults.standard.integer(forKey: seen)
        guard shown < Self.keyTipTimes else { return }
        UserDefaults.standard.set(shown + 1, forKey: seen)
        let key = BoardHoldKey.current(tool).label
        capsule.tip(tool == .box ? "下次可以直接按住 \(key) 画矩形，松开就停" : "下次可以直接按住 \(key) 画，松开就停")
    }
    static let keyTipTimes = 5

    static func capsuleControls(tool selected: InkTool?, paused: Bool, pen: @escaping () -> Void, use: @escaping (InkTool) -> Void,
                                undo: @escaping () -> Void, pause: @escaping () -> Void, save: @escaping () -> Void,
                                finish: @escaping () -> Void) -> [BoardCapsule.Control] {
        func shape(_ tool: InkTool, _ symbol: String, _ name: String) -> BoardCapsule.Control {
            let k = BoardHoldKey.tools.contains(tool) ? BoardHoldKey.current(tool).label : nil
            return .init(title: name, symbol: symbol, kind: .icon, on: selected == tool,
                         tip: k.map { "\(name)：点一下一直保持，再点取消；按住 \($0) 临时画，松开回到正常操作" } ?? "\(name)：点一下一直保持，再点取消") {
                use(tool)
            }
        }
        let drawing = selected != nil
        return [
            .init(title: drawing ? "正常操作" : "画笔", symbol: "pencil", kind: .toggle, on: drawing,
                  tip: drawing ? "回到正常操作（点击、滚动都交给下面的程序）" : "开始画（用上次的工具）", run: pen),
            shape(.free, "scribble", "自由画"),
            shape(.box, "rectangle", "矩形"),
            shape(.ellipse, "circle", "圆圈"),
            .init(title: "撤销", symbol: "arrow.uturn.backward", kind: .icon, tip: "撤销上一笔", run: undo),
            .init(title: paused ? "继续" : "暂停", symbol: paused ? "play.fill" : "pause.fill", kind: .icon, on: paused,
                  tip: paused ? "继续录音" : "暂停录音（暂停期间不录音、不截图）", run: pause),
            .init(title: "完成", kind: .primary, tip: "结束录音，打开检查窗口", run: finish),
        ]
    }

    private func togglePause() {
        guard active, !busy else { return }
        if !paused {
            sealScroll(); timeline?.close(at: moment)
            clock.pause(at: ProcessInfo.processInfo.systemUptime)
        } else { clock.resume(at: ProcessInfo.processInfo.systemUptime) }
        paused.toggle()
        selectTool(nil)
        speech.setPaused(paused)
        screenFeed.paused = paused
        if !paused { screenFeed.resetBoundary() }
        configureControls(); refresh()
    }

    func preview() {
        guard active else { openReview(); return }
        capsule.togglePreview(pages: pages, text: speech.fullText)
    }

    func handle(_ k: HK) {
        guard active else { return }
        switch k {
        case .boardFinish: finish()
        case .boardCancel: cancel()
        case .boardUndo: undo()
        case .boardDropPage: dropLastPage()
        default: break
        }
    }

    // MARK: start / stop

    static let hintKey = "board.hintSessions"

    func start() {
        if let review { review.show(); return }
        if finalizing { openReview(); return }
        guard !active, !finalizing, runner == nil, review == nil else { return }
        active = true
        paused = false
        busy = false
        pages = []
        timeline = BoardTimeline()
        clock = BoardCaptureClock(now: ProcessInfo.processInfo.systemUptime)
        nextMarkNumber = 1; strokeStart = nil
        reviewedTranscript = nil
        archivedTranscript = nil
        screenWarning = nil
        originalPrints = [:]
        liveScroll = nil; livePage = nil
        selectedTool = nil
        Self.yieldKeyboard(true)
        holdKeys.start(
            hold: { [weak self] tool in
                guard let self, self.active, !self.paused, !self.busy else { return nil }
                let before = self.selectedTool
                self.selectTool(tool)
                return before
            },
            release: { [weak self] before in
                guard let self, self.active else { return }
                self.selectTool(before)
            })
        // a tap of the draw key: that tool for one stroke
        holdKeys.onTap = { [weak self] tool in
            guard let self, self.active, !self.paused, !self.busy else { return }
            self.selectTool(tool)
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        dir = PointTaken.records.appendingPathComponent(stamp.string(from: Date()))
        do { try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true) }
        catch {
            end()
            capsule.message(.init(symbol: "exclamationmark.triangle", tint: BoardColor.warn,
                                  text: "无法创建记录文件夹：\(error.localizedDescription)"), seconds: 8)
            return
        }

        panels = NSScreen.screens.map { BoardInkPanel(screen: $0) }
        panels.forEach { panel in
            panel.ink.onStrokeBegan = { [weak self] in
                guard let self else { return }
                self.strokeStart = self.moment
                self.strokeFrame = self.screenFeed.current
            }
            panel.ink.onStrokeCompleted = { [weak self] in self?.strokeCompleted(panel) }
            panel.orderFrontRegardless()
        }

        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        // the keys under the capsule: the first three sessions, until the first page is kept
        let shown = UserDefaults.standard.integer(forKey: BoardSession.hintKey)
        hintsThisSession = shown < 3
        if hintsThisSession { UserDefaults.standard.set(shown + 1, forKey: BoardSession.hintKey) }

        capsule.beginSession()
        configureControls()
        speech.onText = { [weak self] _ in
            guard let self else { return }; self.review?.updateTranscript(self.speech.fullText); self.refresh()
        }
        speech.onStatus = { [weak self] _ in self?.refresh() }
        speech.onLevel = { [weak self] l in self?.capsule.setLevel(l) }
        refresh()
        wordsAtScreen = 0; pagesAtScreen = pages.count; copiedSegments = nil
        speech.start(locale: BoardSession.locale, directory: dir!)
        screenFeed.onObserve = { [weak self] frame, boundary in
            guard let self, self.active, !self.paused else { return }
            self.timeline?.observe(frame, boundary: boundary, at: self.moment)
            if boundary { self.writeNotes() }
        }
        screenFeed.onInput = { [weak self] kind, dy, at in
            guard let self, self.active, !self.paused, let timeline = self.timeline else { return }
            if timeline.evidence.inputs == nil { timeline.evidence.inputs = [] }
            BoardScrollInput.append(BoardInput(kind: kind, at: self.clock.elapsed(at: at), dy: dy), to: &timeline.evidence.inputs!)
        }
        screenFeed.onTransition = { [weak self] old, next, scrolling in self?.transition(old, next, scrolling: scrolling) ?? false }
        screenFeed.onLeave = { [weak self] frame in
            guard let self else { return }
            self.autoPage(frame); self.keepSpoken(frame, wordCount: self.speech.fullText.count)
        }
        screenFeed.onFailure = { [weak self] error in self?.screenWarning = "自动留页不可用：" + error; self?.refresh() }
        screenFeed.start()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        emit(["event": "board_start", "dir": dir!.path])
    }

    static var locale: String {
        (recordConfig()["board"] as? [String: Any])?["locale"] as? String ?? "zh-CN"
    }

    private func end() {
        timeline?.close(at: moment)
        active = false
        busy = false
        ticker?.invalidate()
        ticker = nil
        screenFeed.stop()
        penOn = false
        selectedTool = nil
        holdKeys.stop()
        Self.yieldKeyboard(false)
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    func cancel() {
        guard active else { return }
        guard !busy else { return }
        if let review, !review.closeSaving() { return }
        keepPage(always: false, finishing: true) { _ in }
        finalizing = true
        speech.stop { [weak self] _ in
            guard let self else { return }
            self.finalizing = false
            self.writeNotes()
            let message = self.speech.archiveWarning.map { "已停止，未粘贴。" + $0 }
                ?? (self.speech.finalTranscriptVerified ? "已停止，录音和完整转写已保留，未粘贴" : "已停止，已保留可用录音与文字，未粘贴")
            BoardFileWriter.whenFinished {
                BoardNotices.shared.post(BoardFileWriter.warning(in: self.dir).map { "已停止，未粘贴。" + $0 } ?? message)
            }
            emit(["event": "board_cancel"])
        }
        end()
        capsule.hide()
    }

    /// Called during normal app termination; flush audio and the final transcript before quitting.
    func prepareForQuit(_ done: @escaping () -> Void) {
        if let review { _ = review.closeSaving() }
        if finalizing { speech.stopForQuit { _ in BoardFileWriter.prepareToQuit(done) }; return }
        guard active else { BoardFileWriter.prepareToQuit(done); return }
        keepPage(always: false, finishing: true) { _ in }
        speech.stopForQuit { [weak self] _ in
            self?.writeNotes()
            self?.end()
            BoardFileWriter.prepareToQuit(done)
        }
    }

    // MARK: pen

    private func tick() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !paused, now - lastMetadataTick >= 1 {
            lastMetadataTick = now
            if screenFeed.current == nil {
                let context = BoardScreenFeed.context()
                timeline?.observe(scene: context.scene, app: context.app, title: context.title, at: moment)
            }
            writeEvidence()
        }
        if NSApp.isHidden {
            penOn = false
            selectedTool = nil
            panels.forEach { $0.setPen(false) }
            capsule.setPen(false)
            return
        }
        syncPen()
        let m = NSEvent.mouseLocation
        for p in panels { p.ink.moveHalo(screen: m, in: p.frame, show: penOn && p.frame.contains(m)) }
    }

    /// Only the capsule changes tools. Keyboard modifiers always belong to the application under it.
    private func syncPen() {
        let on = !busy && !paused && screenFeed.current != nil && review == nil && selectedTool != nil
        if let selectedTool { panels.forEach { $0.ink.tool = selectedTool } }
        guard !panels.contains(where: { $0.ink.drawing }) else { return }
        let display = screenFeed.current?.bounds
        guard on != penOn || display != penDisplay else { return }
        penOn = on
        penDisplay = display
        // Wait for this display's clean frame before accepting ink on it. A rapid display switch must never
        // leave a completed stroke without corresponding pixels to archive.
        panels.forEach { $0.setPen(on && $0.displayBounds == display) }
        capsule.setPen(on)
    }

    private func undo() {
        if let liveScroll, let index = livePage, pages.indices.contains(index) {
            do {
                guard try liveScroll.undo() else { return }
                pages[index] = liveScroll.page
                panels.first { $0.displayBounds == liveScroll.frame.bounds }?.ink.load(liveScroll.viewportMarks)
                if liveScroll.page.marks.isEmpty && !pages[index].manuallySaved {
                    let removed = pages.remove(at: index)
                    self.liveScroll = nil; livePage = nil
                    panels.forEach { $0.ink.clear() }
                    let retained = pages.reduce(into: Set<URL>()) { $0.formUnion($1.allFiles) }
                    BoardFileWriter.remove(removed.allFiles.subtracting(retained))
                }
                capsule.setTray(pages.compactMap(\.thumb)); writeNotes()
            } catch { capsule.toast("撤销未能保存：" + error.localizedDescription) }
            return
        }
        guard let p = panels.max(by: { $0.ink.lastStrokeAt < $1.ink.lastStrokeAt }), p.ink.undo() else { return }
    }

    private func dropLastPage() {
        guard !busy, let last = pages.popLast() else { return }
        BoardFileWriter.remove(last.allFiles)
        writeNotes()
        capsule.setTray(pages.compactMap(\.thumb))
        capsule.toast("删掉了第 \(pages.count + 1) 页")
        refresh()
    }

    // MARK: pages

    private func nextPage() {
        guard active, !busy, !paused, review == nil else { return }
        keepPage(always: true) { [weak self] kept in
            guard let self else { return }
            self.busy = false
            if kept {
                self.selectTool(nil)
                self.hintsThisSession = false
                self.capsule.toast("第 \(self.pages.count) 页已存，切到下一页接着标")
            } else {
                self.capsule.toast("这一页还没画也没说，先标一下再点“存页”")
            }
            self.refresh()
        }
    }

    private func strokeCompleted(_ panel: BoardInkPanel) {
        // holding the draw key: the tool stays on for the next stroke (many boxes, many circles); otherwise one
        // stroke and back to normal clicking
        holdKeys.strokeDrawn()
        defer { strokeStart = nil; strokeFrame = nil; if !holdKeys.holding { selectTool(nil) } }
        guard active, !paused, let frame = strokeFrame ?? screenFeed.current, frame.bounds == panel.displayBounds,
              let stroke = panel.ink.normalizedStrokes.last else { return }
        let evidence = BoardMarkEvidence(number: nextMarkNumber, start: strokeStart ?? moment, end: moment)
        nextMarkNumber += 1
        place(stroke, evidence: evidence, frame: frame, panel: panel)
    }

    /// Whether two pictures show the same page: what moves on its own there (a carousel, a video) is left out.
    private func samePicture(_ a: BoardFrameFingerprint, _ b: BoardFrameFingerprint, within limit: Double = 0.002) -> Bool {
        screenFeed.motion.distance(a, b) < limit
    }

    /// Files a stroke just drawn on `frame`: onto the page being marked when the screen still shows it, else as a
    /// new page. A stroke on a part that moves by itself (a carousel's cover) must sit on the picture it was drawn
    /// on: when that part has changed since the page was taken, the page takes the current picture — unless an
    /// earlier mark is on the moving part too (it was about what was shown then), in which case this is a new page.
    func place(_ stroke: [[Double]], evidence: BoardMarkEvidence, frame: BoardScreenFeed.Frame, panel: BoardInkPanel?) {
        let motion = screenFeed.motion
        let sameViewport = liveScroll.map { $0.frame.bounds == frame.bounds && samePicture($0.frame.fingerprint, frame.fingerprint) } ?? true
        var onChangedMovingPart = false
        if let liveScroll, sameViewport, motion.touches(stroke),
           motion.movingDistance(liveScroll.frame.fingerprint, frame.fingerprint) > 0.01 {
            onChangedMovingPart = true
        }
        var startsNewPage = !sameViewport
        if onChangedMovingPart, let liveScroll {
            let earlier = liveScroll.offset == 0 ? liveScroll.viewportMarks.contains { motion.touches($0) } : true
            startsNewPage = earlier || !refreshPicture(liveScroll, to: frame)
        }
        timeline?.observe(frame, boundary: startsNewPage, at: moment)
        timeline?.anchor(frame)
        if !startsNewPage, let liveScroll, liveScroll.offset == 0, let index = livePage, pages.indices.contains(index) {
            do { try liveScroll.add(stroke, evidence: evidence); pages[index] = liveScroll.page; writeNotes() }
            catch { capsule.toast("标记保存失败：" + error.localizedDescription) }
        } else {
            // Scrolling follows existing ink in memory, but a fresh viewport is only archived
            // when the user draws here. Never append unmarked content to a long screenshot.
            var marks: [[[Double]]] = []
            var metadata: [BoardMarkEvidence] = []
            if let liveScroll, sameViewport, !onChangedMovingPart {
                for (points, item) in zip(liveScroll.viewportMarks, liveScroll.page.markEvidence) {
                    if points.contains(where: { $0.count == 2 && $0[1] >= 0 && $0[1] <= 1 }) {
                        marks.append(points); metadata.append(item)
                    }
                }
            }
            marks.append(stroke); metadata.append(evidence)
            let index = save(frame.image, bounds: frame.bounds, marks: marks, text: "", included: true,
                             scene: frame.scene, evidence: metadata, capturedAt: clock.elapsed(at: frame.capturedAt),
                             fresh: onChangedMovingPart)
            if let index {
                sealScroll()
                liveScroll = BoardLiveScroll(page: pages[index], frame: frame); livePage = index
                panel?.ink.load(pages[index].marks)
            }
        }
        wordsAtScreen = speech.fullText.count; pagesAtScreen = pages.count
        capsule.setTray(pages.compactMap(\.thumb))
    }

    /// The page being marked takes `frame` as its picture (its marks are redrawn on it). Only for a plain page
    /// still at its first viewport; false when that is not possible.
    private func refreshPicture(_ live: BoardLiveScroll, to frame: BoardScreenFeed.Frame) -> Bool {
        guard let index = livePage, pages.indices.contains(index), live.offset == 0,
              let original = live.page.original, (try? live.replacePicture(with: frame)) == true else { return false }
        originalPrints[original] = (frame.fingerprint, frame.image.width, frame.image.height)
        pages[index] = live.page
        return true
    }

    private func sealScroll() {
        guard let index = livePage, pages.indices.contains(index) else { liveScroll = nil; livePage = nil; return }
        _ = index // Full speech is never sliced into page text.
        let bounds = liveScroll?.frame.bounds
        liveScroll = nil; livePage = nil
        panels.filter { $0.displayBounds == bounds }.forEach { $0.ink.clear() }
        writeNotes()
    }

    private func transition(_ old: BoardScreenFeed.Frame, _ next: BoardScreenFeed.Frame, scrolling: Bool) -> Bool {
        guard active, !busy, !paused, let liveScroll, let index = livePage, pages.indices.contains(index) else { return false }
        guard !panels.contains(where: { $0.ink.drawing }) else { return true }
        // a carousel or a video turning over is the page moving by itself, not navigation
        if old.scene == next.scene, old.title == next.title, !scrolling,
           samePicture(old.fingerprint, next.fingerprint, within: 0.045) { return false }
        if old.scene == next.scene, old.title == next.title, scrolling {
            guard !aligning else { pendingScrollFrame = next; return true }
            if liveScroll.frame.fingerprint.distance(to: next.fingerprint) < 0.001 { return true }
            aligning = true
            let snapshot = liveScroll.snapshot()
            let marks = liveScroll.page.markEvidence
            let observedAt = moment
            alignmentQueue.async { [weak self, weak liveScroll] in
                let matched = (try? snapshot.advance(to: next, retainNewContent: false)) == true
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.aligning = false
                    let latest = self.pendingScrollFrame ?? self.screenFeed.current
                    self.pendingScrollFrame = nil
                    guard self.active, !self.paused, let liveScroll, self.liveScroll === liveScroll,
                          self.livePage == index, liveScroll.page.markEvidence == marks,
                          !self.panels.contains(where: { $0.ink.drawing }) else { return }
                    if matched {
                        let moved = snapshot.offset != liveScroll.offset
                        self.liveScroll = snapshot
                        if moved {
                            self.timeline?.observe(next, boundary: true, at: observedAt)
                            self.wordsAtScreen = self.speech.fullText.count; self.pagesAtScreen = self.pages.count
                        }
                        if let latest, latest.scene == next.scene, latest.title == next.title,
                           latest.fingerprint.distance(to: next.fingerprint) >= 0.001 {
                            // Keep the verified intermediate mapping, but never paint its stale viewport on top
                            // of newer pixels. Continue immediately with the most recent frame, not an old queue.
                            _ = self.transition(next, latest, scrolling: true)
                        } else if latest?.bounds == next.bounds {
                            self.panels.first { $0.displayBounds == next.bounds }?.ink.load(snapshot.viewportMarks)
                        }
                    } else {
                        self.sealScroll(); self.selectTool(nil)
                        self.timeline?.observe(next, boundary: true, at: observedAt)
                        self.wordsAtScreen = self.speech.fullText.count; self.pagesAtScreen = self.pages.count
                        self.writeNotes()
                    }
                }
            }
            return true
        }
        // Navigation or unreliable registration never leaves stale ink blocking the new content.
        screenFeed.motion.reset()
        sealScroll(); selectTool(nil)
        timeline?.observe(next, boundary: true, at: moment)
        writeNotes()
        return true
    }

    private func autoPage(_ frame: BoardScreenFeed.Frame) {
        guard active, !busy, !paused, review == nil, liveScroll == nil else { return }
        let panel = panels.first { $0.displayBounds == frame.bounds }
        if panel?.ink.drawing == true { panel?.ink.end(); return }
        guard let panel, !panel.ink.normalizedStrokes.isEmpty else { return }
        // Completed strokes normally save immediately. This is only a recovery boundary.
        let marks = panel.ink.normalizedStrokes
        let evidence = marks.map { _ -> BoardMarkEvidence in
            defer { nextMarkNumber += 1 }; return BoardMarkEvidence(number: nextMarkNumber)
        }
        if save(frame.image, bounds: frame.bounds, marks: marks, text: "", included: true, scene: frame.scene, evidence: evidence,
                capturedAt: clock.elapsed(at: frame.capturedAt)) != nil {
            panel.ink.clear(); selectTool(nil); refresh()
        }
    }

    /// Freeze pixels and strokes before waiting for the final transcript, so later navigation cannot
    /// pair old ink with new pixels. The continuously captured original never contains our own panels.
    private func keepPage(always: Bool, finishing: Bool = false, then: @escaping (Bool) -> Void) {
        panels.filter { $0.ink.drawing }.forEach { $0.ink.end() }
        if let liveScroll, let index = livePage, pages.indices.contains(index), liveScroll.offset == 0,
           screenFeed.current.map({ $0.bounds == liveScroll.frame.bounds && samePicture($0.fingerprint, liveScroll.frame.fingerprint) }) ?? true {
            if always { pages[index].manuallySaved = true }
            sealScroll(); screenFeed.resetBoundary(); then(true); return
        }
        // Finish keeps existing annotated images; the last screen only if it was talked over (unchecked, like others).
        guard always else {
            if finishing, let frame = screenFeed.current { keepSpoken(frame, wordCount: speech.fullText.count) }
            sealScroll(); then(false); return
        }
        busy = true
        guard let frame = screenFeed.current else { writeNotes(); then(false); return }
        timeline?.observe(frame, boundary: false, at: moment)
        let marks = liveScroll?.viewportMarks ?? []
        let evidence = liveScroll?.page.markEvidence ?? []
        let kept = save(frame.image, bounds: frame.bounds, marks: marks, text: "", included: true,
                        scene: frame.scene, evidence: evidence, manual: true, capturedAt: clock.elapsed(at: frame.capturedAt)) != nil
        if kept { sealScroll(); screenFeed.resetBoundary() }
        then(kept)
    }

    /// the saved originals' fingerprints and sizes (the revisit check compares against these, never re-reading files)
    private var originalPrints: [URL: (print: BoardFrameFingerprint, width: Int, height: Int)] = [:]
    private func originalPrint(_ url: URL) -> (print: BoardFrameFingerprint, width: Int, height: Int)? {
        if let p = originalPrints[url] { return p }
        guard let image = loadCGImage(url) else { return nil }
        let p = (BoardFrameFingerprint(image), image.width, image.height)
        originalPrints[url] = p
        return p
    }

    @discardableResult private func save(_ image: CGImage, bounds: CGRect, marks: [[[Double]]], text: String,
                                         included: Bool, scene: String, evidence: [BoardMarkEvidence] = [], manual: Bool = false,
                                         capturedAt: Double? = nil, fresh: Bool = false) -> Int? {
        guard let dir, !marks.isEmpty || manual else { return nil }
        let contextIDs = timeline?.currentID.map { [$0] } ?? []
        let imagePrint = BoardFrameFingerprint(image)
        // Revisit a confidently matched unchanged viewport: update one image, keep all visits. What moves on its own
        // there is left out — but marks on a moving part that has changed since need the picture they were drawn on.
        let motion = screenFeed.motion
        if !fresh, let index = pages.indices.first(where: { index in
            let page = pages[index]
            guard !contextIDs.isEmpty, page.contextIDs == contextIDs, page.scene == scene,
                  let url = page.original, let old = originalPrint(url), old.width == image.width, old.height == image.height else { return false }
            guard motion.distance(old.print, imagePrint) < 0.002 else { return false }
            return !(marks.contains(where: motion.touches) && motion.movingDistance(old.print, imagePrint) > 0.01)
        }), let output = pages[index].images.first {
            var page = pages[index]
            let known = Set(page.markEvidence.map(\.number))
            let before = page.marks.count
            for (mark, item) in zip(marks, evidence) where !known.contains(item.number) {
                page.marks.append(mark); page.markEvidence.append(item)
            }
            // a page kept only for what was said (unchecked) that is then drawn on goes to the AI like any marked page
            page.included = BoardPageInclusion.after(change: before, to: page.marks.count, included: page.included)
            page.manuallySaved = page.manuallySaved || manual
            guard let thumb = renderBoardMarked(image, strokes: page.marks, evidence: page.markEvidence, lineWidth: page.lineWidth, thumbnailHeight: 96) else { return nil }
            BoardFileWriter.marked(image, page: page, to: output)
            page.thumb = thumb; pages[index] = page
            writeNotes(); return index
        }
        let id = UUID().uuidString
        let original = dir.appendingPathComponent("原图-\(id).png")
        let output = dir.appendingPathComponent("标注-\(id).png")
        let width = max(2, CGFloat(image.width) / max(1, bounds.width) * 4)
        guard let thumb = renderBoardMarked(image, strokes: marks, evidence: evidence, lineWidth: width, thumbnailHeight: 96) else {
            capsule.toast("截图保存失败，标记暂未清除"); return nil
        }
        BoardFileWriter.png(image, to: original)
        originalPrints[original] = (imagePrint, image.width, image.height)
        let page = Page(images: [output], text: text, thumb: thumb,
                          original: original, marks: marks, included: included, scene: scene,
                          lineWidth: width, sourceFrames: [original], contextIDs: contextIDs, markEvidence: evidence, manuallySaved: manual,
                          capturedAt: capturedAt)
        BoardFileWriter.marked(image, page: page, to: output)
        pages.append(page)
        capsule.setTray(pages.compactMap(\.thumb))
        writeNotes()
        return pages.count - 1
    }

    func openReview(allowEmpty: Bool = false, filesReady: Bool = false) {
        guard review == nil else { return }
        if active { preview(); return }
        guard filesReady else {
            BoardFileWriter.whenFinished { [weak self] in self?.openReview(allowEmpty: allowEmpty, filesReady: true) }
            return
        }
        if panels.contains(where: { $0.ink.hasInk || $0.ink.drawing }) {
            guard let frame = screenFeed.current else { capsule.toast("屏幕画面尚未准备好，请稍后回看"); return }
            autoPage(frame)
            guard !panels.contains(where: { $0.ink.hasInk }) else { return }
        }
        guard allowEmpty || finalizing || !pages.isEmpty || !deliveryTranscript.isEmpty else { return }
        selectTool(nil)
        screenFeed.paused = true
        let warnings = [archivedTranscript == nil ? speech.archiveWarning : nil, BoardFileWriter.warning(in: dir)].compactMap { $0 }
        let window = BoardReviewWindow(pages: pages, transcript: deliveryTranscript, recording: active,
                                       originalTranscript: originalTranscript,
                                       warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
        review = window
        window.evidence = timeline?.evidence
        window.audio = dir?.appendingPathComponent("原始录音.wav")
        if let name = dir?.lastPathComponent {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
            window.recordDate = f.date(from: name)
        }
        window.onEvidence = { [weak self] edited in self?.timeline?.evidence.speech = edited.speech; self?.writeNotes() }
        window.onExport = { [weak self] pages, transcript in
            let root = PointTaken.exports
            return try Self.exportFolder(pages: pages, transcript: transcript, evidence: self?.timeline?.evidence, root: root)
        }
        window.setFinalizing(finalizing)
        // a page deleted in the window can come back with ⌘Z until it closes: its files go only then
        var seen = Self.files(of: pages)
        window.onSave = { [weak self] pages, transcript in
            guard let self else { return }
            seen.formUnion(Self.files(of: pages))
            self.pages = pages
            if !self.active, let transcript { self.reviewedTranscript = transcript }
            self.writeNotes()
            self.capsule.setTray(pages.compactMap(\.thumb))
        }
        window.onClose = { [weak self] in
            guard let self else { return }
            BoardFileWriter.remove(seen.subtracting(Self.files(of: self.pages)))
            self.review = nil
            self.screenFeed.paused = false
            self.screenFeed.resetBoundary()
        }
        window.onDeliver = { [weak self] target, export in
            guard let self else { return }
            self.writeNotes()
            self.paste(target: target, export: export)
        }
        window.show()
    }

    static func files(of pages: [Page]) -> Set<URL> { pages.reduce(into: Set<URL>()) { $0.formUnion($1.allFiles) } }

    static func thumbnail(_ img: CGImage) -> CGImage {
        let h: CGFloat = 96
        let w = (CGFloat(img.width) / CGFloat(max(img.height, 1)) * h).rounded()
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// the transcriber's sentences last copied into the timeline
    private var copiedSegments: [BoardSpeechSegment]?
    /// what had been said, and how many pages kept, when the screen now showing came up (BoardSession.keepSpoken)
    private var wordsAtScreen = 0
    private var pagesAtScreen = 0

    /// A screen was talked over but not marked: keep it as a page, unchecked (it goes to the AI only if checked in the
    /// review), so the words said there have their picture. A screen marked on already has its page.
    private func keepSpoken(_ frame: BoardScreenFeed.Frame, wordCount: Int) {
        defer { wordsAtScreen = wordCount; pagesAtScreen = pages.count }
        let unsavedViewport = liveScroll.map { $0.offset != 0 || $0.frame.bounds != frame.bounds || !samePicture($0.frame.fingerprint, frame.fingerprint) } ?? true
        guard active, !paused, !busy, unsavedViewport, pages.count == pagesAtScreen,
              wordCount - wordsAtScreen >= 4 else { return }
        timeline?.observe(frame, boundary: liveScroll != nil, at: moment)
        save(frame.image, bounds: frame.bounds, marks: [], text: "", included: false, scene: frame.scene, manual: true,
             capturedAt: clock.elapsed(at: frame.capturedAt))
    }

    private func writeEvidence() {
        guard let dir, let timeline else { return }
        if active && !paused { timeline.touch(at: moment) }
        if archivedTranscript == nil, speech.timedSegments != copiedSegments || !speech.hasReliableAudioTimeline {
            copiedSegments = speech.timedSegments
            speech.updateTiming(&timeline.evidence)
        }
        let evidence = timeline.evidence
        BoardFileWriter.enqueue(dir.appendingPathComponent(BoardEvidence.filename)) {
            do { try evidence.save(dir); return true } catch { return false }
        }
    }

    private func writeNotes() {
        guard let dir else { return }
        writeEvidence()
        let savedPages = pages, transcript = deliveryTranscript, evidence = timeline?.evidence
        BoardFileWriter.enqueue(dir.appendingPathComponent("说明.md")) {
            let text = BoardEvidenceExport.text(pages: savedPages, transcript: transcript, evidence: evidence)
            let notes = text + "\n\n" + BoardSession.markdown(savedPages)
            do { try notes.write(to: dir.appendingPathComponent("说明.md"), atomically: true, encoding: .utf8); return true }
            catch { return false }
        }
        BoardFileWriter.enqueue(dir.appendingPathComponent("页面.json")) {
            do {
                let data = try JSONSerialization.data(withJSONObject: savedPages.map(BoardPageFiles.encode), options: [.prettyPrinted, .sortedKeys])
                try data.write(to: dir.appendingPathComponent("页面.json"), options: .atomic)
                return true
            } catch { return false }
        }
        if let reviewedTranscript {
            BoardFileWriter.enqueue(dir.appendingPathComponent("交付转写.txt")) {
                do { try BoardDeliveryTranscript.saveEdit(reviewedTranscript, to: dir); return true } catch { return false }
            }
        }
    }

    /// 图1 / 图2 …: the label each picture gets, and the words of its page under the first one.
    static func labelled(_ pages: [Page]) -> [(image: URL?, label: String, text: String)] {
        var out: [(URL?, String, String)] = []
        var n = 0
        for p in pages {
            if p.images.isEmpty { out.append((nil, "补充", p.text)); continue }
            for (i, u) in p.images.enumerated() {
                n += 1
                out.append((u, "图\(n)", i == 0 ? p.text : "（和上一张是同一页的另一块屏幕）"))
            }
        }
        return out
    }

    static func markdown(_ pages: [Page]) -> String {
        labelled(pages).map { e in
            let body = e.text.isEmpty ? "（此页没有单独的语音摘录，完整说明见上方转写）" : e.text
            return e.image.map { "![\(e.label)](\($0.lastPathComponent))\n\n\(e.label)：\(body)" } ?? "\(e.label)：\(body)"
        }.joined(separator: "\n\n")
    }

    // MARK: finish → paste

    func finish() {
        guard active, !busy else { return }
        // Snapshot synchronously, then show review while the saved audio is transcribed.
        keepPage(always: false, finishing: true) { [weak self] _ in
            guard let self else { return }
            self.finalizing = true
            self.speech.stop { [weak self] _ in
                guard let self else { return }
                self.finalizing = false
                self.writeNotes()
                // the review opened while the words were still being transcribed: give it the timeline with its sentences
                self.review?.evidence = self.timeline?.evidence
                let warnings = [self.speech.archiveWarning, BoardFileWriter.warning(in: self.dir)].compactMap { $0 }
                self.review?.finishTranscript(self.deliveryTranscript, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
                // A closed review stays closed; no completion callback may recreate it.
            }
            self.end()
            self.capsule.hide()
            self.writeNotes()
            self.openReview(allowEmpty: true)
        }
    }

    static func exportFolder(pages: [Page], transcript: String, evidence: BoardEvidence?, root: URL) throws -> BoardFolderExport.Bundle {
        let selected = pages.filter(\.included).map {
            BoardReadablePage(images: $0.images, contextIDs: $0.contextIDs, marks: $0.markEvidence)
        }
        return try BoardFolderExport.create(root: root, pages: selected, transcript: transcript, evidence: evidence)
    }

    static func deliverySteps(export: BoardFolderExport.Bundle) -> [PasteStep] {
        export.text.isEmpty ? [] : [.text(export.text)]
    }

    private func paste(target: NSRunningApplication, export: BoardFolderExport.Bundle) {
        guard !finalizing, runner == nil else { return }
        guard !target.isTerminated else { review?.deliveryStatus("接收应用已退出，请重新选择。", failed: true); return }
        guard PastePermission.accessibility else { review?.deliveryStatus("自动粘贴需要辅助功能权限；可以先复制说明和图片路径。", failed: true); return }
        let steps = Self.deliverySteps(export: export)
        guard !steps.isEmpty else { review?.deliveryStatus("没有选中的图片或文字可粘贴。", failed: true); return }
        let pb = capturePasteboard, saved = ClipboardSaved.take(capturePasteboard)
        let r = PasteRunner(steps: steps, pasteboard: pb, pid: target.processIdentifier) { saved.restore(pb) }
        r.stopOnTimeout = true
        r.targetStillReady = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier && Self.hasTextTarget(target.processIdentifier)
        }
        runner = r
        weak var currentReview = review
        r.done = { [weak self] run in
            self?.runner = nil
            if run.state == .done {
                _ = currentReview?.closeSaving()
                BoardNotices.shared.post("已执行粘贴到 \(target.localizedName ?? "目标应用")，未自动发送。")
            } else {
                currentReview?.deliveryStatus("粘贴中断；未重试，可手动复制说明和图片路径。", failed: true)
            }
        }
        target.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.runner === r else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  Self.hasTextTarget(target.processIdentifier) else {
                self.runner = nil
                currentReview?.deliveryStatus("未找到目标应用的可编辑输入框；未粘贴、未重试。请选好输入框，或手动复制。", failed: true)
                return
            }
            r.start()
        }
    }

    private static func hasTextTarget(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var editable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable)
        return editable.boolValue || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "")
    }

    // MARK: the capsule

    func refresh() {
        guard active else { return }
        var warnings: [BoardCapsule.Warning] = []
        if !CGPreflightScreenCaptureAccess() {
            warnings.append(.init(text: "截图要「屏幕录制」权限，打开后重开这个 App", permission: .screen))
        }
        if case .off(let why, let p) = speech.status, !why.isEmpty { warnings.append(.init(text: why, permission: p)) }
        if !PastePermission.accessibility {
            warnings.append(.init(text: "最后自动粘贴要用「辅助功能」权限", permission: .accessibility))
        }
        if let warning = screenWarning { warnings.append(.init(text: warning, permission: nil)) }
        if let warning = speech.archiveWarning { warnings.append(.init(text: warning, permission: nil)) }
        let mic: BoardCapsule.Mic
        if speech.isRecording { mic = .live }
        else { switch speech.status {
        case .listening: mic = .live
        case .starting: mic = .starting
        case .off: mic = .off
        } }
        capsule.update(page: pages.count + 1, words: paused ? "已暂停 · 语音与画面都已停止记录" : speech.pageText, mic: paused ? .off : mic, warnings: warnings, hints: false)
    }
}

/// Screenshots written off the main thread: encoding a full-screen PNG took a few hundred ms there after every stroke,
/// and the pen stalled at the start of the next one. One serial queue (the last write of a file wins); whatever reads
/// the files back (the review, the finish) calls `flush()` first. A failed write is said in the messages.
enum BoardFileWriter {
    private static let queue = DispatchQueue(label: "pointtaken.board.png-writer", qos: .userInitiated)
    private static let lock = NSLock()
    private struct Work { let id = UUID(); let run: () -> Bool; let original: CGImage? }
    private static var pending: [URL: Work] = [:]
    private static var failed: [URL: Work] = [:]
    private static var cancelled: Set<URL> = []
    private static var order: [URL] = []
    private static var imageWork: Set<URL> = []
    private static var draining = false
    /// Replace obsolete work for the same file before it is encoded. At most the current render plus the latest
    /// version of each page is retained, even when a user rapidly draws many boxes.
    static func enqueue(_ url: URL, image: Bool = false, original: CGImage? = nil, write: @escaping () -> Bool) {
        lock.lock()
        if pending[url] == nil { order.append(url) }
        pending[url] = Work(run: write, original: original)
        failed.removeValue(forKey: url)
        cancelled.remove(url)
        if image { imageWork.insert(url) }
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { drain() } }
    }
    private static func drain() {
        while true {
            lock.lock()
            guard !order.isEmpty else { draining = false; lock.unlock(); return }
            let next = order.firstIndex { imageWork.contains($0) } ?? order.startIndex
            let url = order.remove(at: next), work = pending.removeValue(forKey: url)!
            imageWork.remove(url)
            lock.unlock()
            let ok = autoreleasepool(invoking: work.run)
            lock.lock()
            if !ok && pending[url] == nil && !cancelled.contains(url) { failed[url] = work }
            lock.unlock()
            if !ok {
                DispatchQueue.main.async { BoardNotices.shared.post("文件保存失败，请检查存储空间并重试：" + url.lastPathComponent) }
            }
        }
    }
    static func png(_ image: CGImage, to url: URL) {
        enqueue(url, image: true, original: image) { writePNG(image, to: url) }
    }
    static func marked(_ image: CGImage, page: BoardSession.Page, to url: URL) {
        let marks = page.marks, evidence = page.markEvidence, width = page.lineWidth
        enqueue(url, image: true) {
            guard let marked = renderBoardMarked(image, strokes: marks, evidence: evidence, lineWidth: width) else { return false }
            return writePNG(marked, to: url)
        }
    }
    static func data(_ data: Data, to url: URL) {
        enqueue(url) { do { try data.write(to: url, options: .atomic); return true } catch { return false } }
    }
    static func remove(_ files: Set<URL>) {
        lock.lock()
        files.forEach { pending.removeValue(forKey: $0); failed.removeValue(forKey: $0); imageWork.remove($0) }
        cancelled.formUnion(files)
        order.removeAll { files.contains($0) }
        lock.unlock()
        // An encode already in progress must finish before deletion, otherwise undo can resurrect the PNG.
        queue.async {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            lock.lock(); cancelled.subtract(files); lock.unlock()
        }
    }
    static func flush() { queue.sync {} }
    static func recoveryImage(_ url: URL) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return pending[url]?.original ?? failed[url]?.original
    }
    static func needsRepair(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed[url] != nil
    }
    static func acceptWritten(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        failed.removeValue(forKey: url)
    }
    static func warning(in directory: URL?) -> String? {
        lock.lock(); defer { lock.unlock() }
        let count = failed.keys.filter { directory == nil || $0.deletingLastPathComponent().standardizedFileURL.path == directory?.standardizedFileURL.path }.count
        return count == 0 ? nil : "还有 \(count) 个文件未能保存，内容暂留在内存中。请腾出空间后重新打开检查窗口重试；退出应用会失去未保存的内容。"
    }
    static func whenFinished(_ done: @escaping () -> Void, retryFailures: Bool = true) {
        queue.async {
            // A finish/open is one bounded retry, never an unbounded retry loop. Failed work keeps the source
            // pixels alive so a transient disk error cannot destroy the only copy when the live session ends.
            lock.lock(); let retry = retryFailures ? failed : [:]; lock.unlock()
            for (url, work) in retry {
                lock.lock(); let current = failed[url]?.id == work.id && pending[url] == nil; lock.unlock()
                guard current, autoreleasepool(invoking: work.run) else { continue }
                lock.lock()
                if failed[url]?.id == work.id { failed.removeValue(forKey: url) }
                lock.unlock()
            }
            DispatchQueue.main.async {
                lock.lock(); let busy = draining || !pending.isEmpty; lock.unlock()
                // Work can arrive while the bounded retry runs. A review/quit callback only fires after that
                // newer work too; waiting again does not trigger another automatic retry of disk failures.
                if busy { whenFinished(done, retryFailures: false) } else { done() }
            }
        }
    }
    static func prepareToQuit(_ done: @escaping () -> Void) {
        whenFinished {
            guard let warning = warning(in: nil) else { done(); return }
            let alert = NSAlert()
            alert.messageText = "还有内容未保存"
            alert.informativeText = warning
            alert.addButton(withTitle: "重试保存")
            alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn { prepareToQuit(done) } else { done() }
        }
    }
}

/// CGImage → PNG file.
@discardableResult
func writePNG(_ img: CGImage, to url: URL) -> Bool {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let d = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { return false }
    return rename(temporary.path, url.path) == 0
}

enum BoardPermission {
    case screen, accessibility, microphone, speech

    func open() {
        let pane: String
        switch self {
        case .screen: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        }
        if self == .accessibility {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }
}

extension App {
    @objc func mBoard() { BoardSession.shared.hotkey() }
}

// MARK: - the pen's window, one per screen

final class BoardInkPanel: NSPanel {
    let ink: BoardInkView
    let displayBounds: CGRect        // global, top-left origin (ScreenCaptureKit's)

    init(screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        displayBounds = CGDisplayBounds(id)
        ink = BoardInkView(frame: NSRect(origin: .zero, size: screen.frame.size))
        ink.lineWidth = inkWidth(for: screen)
        super.init(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true          // before the level (setting it afterwards resets the level)
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = ink
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setPen(_ on: Bool) {
        if on { orderFrontRegardless() }
        ignoresMouseEvents = !on
        ink.setPen(on)
    }
}

final class BoardInkView: NSView {
    var tool: InkTool = .free
    var acceptsInk = true
    var onStrokeBegan: (() -> Void)?
    var onStrokeCompleted: (() -> Void)?
    var lineWidth: CGFloat = 4
        var footerTrim = 0
    private var stroke: InkStroke?
    private var live: CAShapeLayer?
    private var strokes: [CAShapeLayer] = []
    private(set) var normalizedStrokes: [[[Double]]] = []
    private var restTimer: Timer?
    private(set) var lastStrokeAt = 0.0
    private let halo = CAShapeLayer()
    private let edge = CALayer()
    private let flashLayer = CALayer()

    var hasInk: Bool { !strokes.isEmpty }
    var drawing: Bool { live != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        edge.borderColor = BoardColor.pen.withAlphaComponent(0.75).cgColor
        edge.borderWidth = 3
        edge.shadowColor = BoardColor.pen.cgColor
        edge.shadowOpacity = 0.9
        edge.shadowRadius = 10
        edge.shadowOffset = .zero
        edge.opacity = 0
        layer?.addSublayer(edge)

        let r: CGFloat = 13
        halo.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        halo.fillColor = BoardColor.pen.withAlphaComponent(0.16).cgColor
        halo.strokeColor = BoardColor.pen.cgColor
        halo.lineWidth = 2
        halo.shadowColor = NSColor.black.cgColor
        halo.shadowOpacity = 0.35
        halo.shadowRadius = 2
        halo.shadowOffset = .zero
        halo.shadowPath = halo.path         // the ring's shadow from its own shape (no off-screen pass as it moves)
        halo.isHidden = true
        layer?.addSublayer(halo)

        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        layer?.addSublayer(flashLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = bounds
        // the glowing edge's shadow from the border itself (else the whole screen-sized layer is rendered off screen)
        edge.shadowPath = CGPath(rect: bounds, transform: nil).copy(strokingWithWidth: edge.borderWidth * 2, lineCap: .butt,
                                                                     lineJoin: .miter, miterLimit: 10)
        flashLayer.frame = bounds
        CATransaction.commit()
    }

    func setPen(_ on: Bool) {
        // a fully transparent window lets clicks fall through; a whisper of fill makes it take them
        layer?.backgroundColor = on ? NSColor(white: 0, alpha: 0.02).cgColor : nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.12 : 0.25)
        edge.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    /// the ring at the pointer while the pen is on (`screen`: the pointer in screen points, `frame` this view's screen)
    func moveHalo(screen p: NSPoint, in frame: NSRect, show: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.isHidden = !show
        if show { halo.position = CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
        CATransaction.commit()
    }

    func flash() {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 0.45, 0]
        a.keyTimes = [0, 0.25, 1]
        a.duration = 0.32
        flashLayer.add(a, forKey: "flash")
    }

    override func mouseDown(with e: NSEvent) { if acceptsInk { begin(at: convert(e.locationInWindow, from: nil)) } }

    func begin(at p: CGPoint) {
        onStrokeBegan?()
        stroke = InkStroke(at: p, tool: tool)
        let l = CAShapeLayer()
        styleInk(l, width: lineWidth)
        layer?.insertSublayer(l, below: halo)
        live = l
        restTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let s = self.stroke else { return }
            if s.checkRest() { self.showLive() }
        }
        RunLoop.main.add(t, forMode: .common)
        restTimer = t
        showLive()
    }

    override func mouseDragged(with e: NSEvent) { move(to: convert(e.locationInWindow, from: nil)) }

    func move(to p: CGPoint) {
        guard let s = stroke else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.position = p
        if s.move(to: p, tool: tool), let l = live { inkSetPath(l, inkPath(s.display, ring: 18)) }
        CATransaction.commit()
    }

    override func mouseUp(with e: NSEvent) { end() }

    func end() {
        restTimer?.invalidate()
        restTimer = nil
        guard let l = live, let s = stroke else { return }
        live = nil
        stroke = nil
        let pts = s.display
        if pts.count <= 1 || (!s.isShape && s.length < 3) { inkSetPath(l, inkPath(Array(pts.prefix(1)), ring: 18)) }   // a tap: ring the spot
        strokes.append(l)
        let savedPoints = (pts.count <= 1 || (!s.isShape && s.length < 3)) ? Array(pts.prefix(1)) : pts
        normalizedStrokes.append(savedPoints.map { [Double($0.x / max(1, bounds.width)), Double($0.y / max(1, bounds.height))] })
        lastStrokeAt = ProcessInfo.processInfo.systemUptime
        onStrokeCompleted?()
    }

    private func showLive() {
        guard let l = live, let s = stroke else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkSetPath(l, inkPath(s.display, ring: 18))
        CATransaction.commit()
    }

    func undo() -> Bool {
        guard let l = strokes.popLast() else { return false }
        if !normalizedStrokes.isEmpty { normalizedStrokes.removeLast() }
        l.removeFromSuperlayer()
        if strokes.isEmpty { lastStrokeAt = 0 }
        return true
    }

    func load(_ marks: [[[Double]]]) {
        clear()
        normalizedStrokes = marks
        for mark in marks {
            let points = mark.filter { $0.count == 2 }.map { CGPoint(x: $0[0] * bounds.width, y: $0[1] * bounds.height) }
            let shape = CAShapeLayer()
            styleInk(shape, width: lineWidth)
            inkSetPath(shape, inkPath(points, ring: 18))
            layer?.insertSublayer(shape, below: halo)
            strokes.append(shape)
        }
    }

    func clear() {
        normalizedStrokes = []
        strokes.forEach { $0.removeFromSuperlayer() }
        strokes = []
        lastStrokeAt = 0
    }
}

// MARK: - a kept page flying into the tray

enum BoardFly {
    static func run(image: CGImage, from: NSRect, to: NSRect, done: @escaping () -> Void) {
        let w = NSWindow(contentRect: from, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .popUpMenu
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(origin: .zero, size: from.size))
        v.wantsLayer = true
        v.layer?.contents = image
        v.layer?.contentsGravity = .resizeAspectFill
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        v.layer?.borderColor = NSColor(white: 1, alpha: 0.6).cgColor
        v.layer?.borderWidth = 2
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        w.orderFrontRegardless()
        // a beat at full size (it "shrinks back" first), then it flies
        let inset = from.insetBy(dx: from.width * 0.06, dy: from.height * 0.06)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.16
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(inset, display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.48
                c.timingFunction = BoardMotion.emphasized
                w.animator().setFrame(to, display: true)
                w.animator().alphaValue = 0.85
            }, completionHandler: {
                w.orderOut(nil)
                done()
            })
        })
    }
}

// MARK: - the capsule at the top of the screen

final class BoardCapsulePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Whether a press at this window point grabs the capsule (its body and its buttons; not the tray or a scroll
    /// view, which have their own dragging).
    var grabbable: ((NSPoint) -> Bool)?
    /// the button under a window point, if any: pressed and let go without moving, it is clicked
    var buttonAt: ((NSPoint) -> NSButton?)?
    private var pressedButton: NSButton?
    /// The mouse moved this far (screen points) while the capsule is held.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private var pressed: NSEvent?
    private var start = NSPoint.zero
    private var last = NSPoint.zero
    private var moved = false
    var dragging: Bool { pressed != nil }

    /// The whole capsule body drags the window; a press that doesn't move is passed on as the click it was, so the
    /// words still open the preview.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where grabbable?(event.locationInWindow) == true:
            pressed = event
            pressedButton = buttonAt?(event.locationInWindow)
            start = NSEvent.mouseLocation; last = start; moved = false
        case .leftMouseDragged where pressed != nil:
            let now = NSEvent.mouseLocation
            if !moved && hypot(now.x - start.x, now.y - start.y) < 3 { return }
            moved = true
            onDrag?(NSPoint(x: now.x - last.x, y: now.y - last.y))
            last = now
        case .leftMouseUp where pressed != nil:
            let down = pressed!
            pressed = nil
            let button = pressedButton
            pressedButton = nil
            if moved { onDragEnd?() }
            else if let button { if button.isEnabled { button.performClick(nil) } }
            else { super.sendEvent(down); super.sendEvent(event) }
        default:
            super.sendEvent(event)
        }
    }
}

final class BoardCapsule {
    enum Mic { case live, starting, off }
    typealias Action = (title: String, run: () -> Void)

    struct Warning {
        var text: String
        var permission: BoardPermission?
    }

    struct Message {
        var symbol: String?
        var tint: NSColor
        var text: String
        var actions: [Action] = []
        var spinner = false
    }

    /// One control on the capsule's row. `.toggle`: the pen (filled orange while on); `.icon`: a round icon button
    /// (an orange ring while on); `.text` / `.primary`: 存这页 / 完成.
    struct Control {
        enum Kind { case toggle, icon, text, primary }
        var title: String
        var symbol: String? = nil
        var kind: Kind = .text
        var on = false
        var tip: String? = nil
        var run: () -> Void
    }

    static let wordsWidth: CGFloat = 230
    /// the gap around the row's buttons: (pill height 46 − button 30) / 2
    static let endInset: CGFloat = 8
    static let panelWidth: CGFloat = 1040

    private var panel: NSPanel?
    private let root = BoardFlippedView()
    private let column = NSStackView()
    private let pill = BoardCapsuleView()
    // the session row
    private let sessionRow = NSStackView()
    private let dot = BoardDotView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let words = BoardTranscriptLabel(wrappingLabelWithString: "")
    private let tray = BoardTrayView()
    // the message row (pasting, done, cancelled)
    private let messageRow = NSStackView()
    private let messageIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let messageText = NSTextField(wrappingLabelWithString: "")
    private let messageButtons = NSStackView()
    private let controls = NSStackView()
    private var controlActions: [() -> Void] = []
    // under the capsule
    private let toastLabel = NSTextField(labelWithString: "")
    private let toastPill = BoardCapsuleView()
    private let warningsBox = NSStackView()
    private let warningCard = BoardCapsuleView()
    private let hintsBox = BoardHintsView()

    private var hideWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var buttonActions: [() -> Void] = []
    private var shownWords = ""
    private var mouseTimer: Timer?
    private var pinnedScreen: NSScreen?
    private var anchor: NSPoint?
    private var expanded = false
    private let previewBox = NSStackView()
    private let dragHandle = BoardDragHandle(labelWithString: "⠿")
    func setExpanded(_ value: Bool) { expanded = value; if !value { previewBox.isHidden = true } }
    func togglePreview(pages: [BoardSession.Page], text: String) {
        if !previewBox.isHidden { previewBox.isHidden = true; place(); return }
        let images = pages.suffix(4).compactMap { page -> NSView? in
            guard let thumb = page.thumb else { return nil }
            let v = NSImageView(); v.image = NSImage(cgImage: thumb, size: .zero)
            v.imageScaling = .scaleProportionallyUpOrDown
            v.widthAnchor.constraint(equalToConstant: 110).isActive = true
            v.heightAnchor.constraint(equalToConstant: 100).isActive = true
            return v
        }
        let row = NSStackView(views: images)
        let transcript = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 130))
        transcript.string = text.isEmpty ? "暂无转写；结束后可编辑图片和文字" : text
        transcript.isEditable = false; transcript.isSelectable = false; transcript.drawsBackground = false
        transcript.textColor = BoardColor.text; transcript.font = .systemFont(ofSize: 12)
        transcript.isVerticallyResizable = true; transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = transcript
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        previewBox.setViews([row, scroll], in: .top); previewBox.isHidden = false; place()
    }

    init() {
        build()
        tray.onOpen = { BoardSession.shared.preview() }
        words.onOpen = { BoardSession.shared.preview() }
    }

    // MARK: build

    private func label(_ f: NSTextField, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.isBordered = false
        f.drawsBackground = false
        f.isEditable = false
        f.isSelectable = false
    }

    private func build() {
        root.wantsLayer = true

        // session row: ● 第 2 页 │ words … [tray]
        label(pageLabel, size: 13, weight: .semibold, color: BoardColor.text)
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        label(words, size: 13, color: BoardColor.text)
        words.maximumNumberOfLines = 2
        words.lineBreakMode = .byWordWrapping
        words.preferredMaxLayoutWidth = BoardCapsule.wordsWidth
        dragHandle.textColor = BoardColor.secondary
        dragHandle.onDrag = { [weak self] delta in
            self?.move(by: delta)
        }
        let left = NSStackView(views: [dragHandle, dot, pageLabel])
        left.spacing = 8
        left.alignment = .centerY
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        sessionRow.setViews([left, divider, words, tray, controls], in: .leading)
        sessionRow.orientation = .horizontal
        sessionRow.alignment = .centerY
        sessionRow.spacing = 12
        sessionRow.setCustomSpacing(14, after: divider)
        // 完成 sits as far from the round end as from the top and bottom (concentric with it). The inset is on the row:
        // the vertical stack around it drops its own trailing inset, and 完成 then touched the pill's edge.
        sessionRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: BoardCapsule.endInset)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 18),
            words.widthAnchor.constraint(equalToConstant: BoardCapsule.wordsWidth),
            // one line (the hint) sits centred, two lines fill the row; the row keeps the two-line height so the
            // capsule doesn't jump when words arrive
            words.heightAnchor.constraint(lessThanOrEqualToConstant: 34),
            sessionRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])

        // message row: (icon | spinner) text [buttons]
        messageIcon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        label(messageText, size: 14, weight: .medium, color: BoardColor.text)
        messageText.maximumNumberOfLines = 2
        messageText.preferredMaxLayoutWidth = 420
        messageButtons.orientation = .horizontal
        messageButtons.spacing = 8
        messageRow.setViews([messageIcon, spinner, messageText, messageButtons], in: .leading)
        messageRow.orientation = .horizontal
        messageRow.alignment = .centerY
        messageRow.spacing = 10
        messageRow.isHidden = true
        messageRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true   // as tall as the session row

        controls.isHidden = true
        previewBox.orientation = .vertical; previewBox.spacing = 8; previewBox.isHidden = true
        let inner = NSStackView(views: [sessionRow, previewBox, messageRow])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 0)
        messageRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: BoardCapsule.endInset)
        previewBox.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 14)
        pill.content = inner
        pill.radius = 23

        // the toast under the capsule (a page kept, a page dropped)
        label(toastLabel, size: 12, weight: .medium, color: BoardColor.text)
        let toastInner = NSStackView(views: [toastLabel])
        toastInner.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        toastPill.content = toastInner
        toastPill.radius = 14
        toastPill.isHidden = true

        warningsBox.orientation = .vertical
        warningsBox.alignment = .leading
        warningsBox.spacing = 8
        warningsBox.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)
        warningCard.radius = 16
        warningCard.tint = BoardColor.warn
        warningCard.content = warningsBox
        warningCard.isHidden = true

        hintsBox.isHidden = true

        column.setViews([pill, toastPill, warningCard, hintsBox], in: .top)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
        ])
    }

    private func makePanel() -> NSPanel {
        if let p = panel { return p }
        let p = BoardCapsulePanel(contentRect: NSRect(x: 0, y: 0, width: BoardCapsule.panelWidth, height: 200),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = root
        p.grabbable = { [weak self] point in
            guard let self else { return false }
            var view = self.root.hitTest(self.root.convert(point, from: nil))
            while let v = view {
                if v is BoardTrayView || v is NSScrollView { return false }
                if v === self.pill { return true }
                view = v.superview
            }
            return false
        }
        p.buttonAt = { [weak self] point in
            guard let self else { return nil }
            var view = self.root.hitTest(self.root.convert(point, from: nil))
            while let v = view, v !== self.pill {
                if let button = v as? NSButton { return button }
                view = v.superview
            }
            return nil
        }
        p.onDrag = { [weak self] delta in self?.move(by: delta) }
        p.onDragEnd = { [weak self] in self?.saveAnchor() }
        panel = p
        return p
    }

    private static let anchorKey = "board.capsule.anchor"

    /// The capsule follows the mouse; where it is let go is where the next session starts (on that screen).
    private func move(by delta: NSPoint) {
        guard let panel else { return }
        anchor = NSPoint(x: panel.frame.minX + delta.x, y: panel.frame.maxY + delta.y)
        pinnedScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? pinnedScreen
        place()
    }

    private func saveAnchor() {
        guard let panel else { return }
        UserDefaults.standard.set([panel.frame.minX, panel.frame.maxY], forKey: BoardCapsule.anchorKey)
    }

    /// The spot the capsule was last dragged to, when it lies on `screen`; nil: the default, top centre.
    private static func savedAnchor(on screen: NSScreen?) -> NSPoint? {
        guard let xy = UserDefaults.standard.array(forKey: anchorKey) as? [Double], xy.count == 2,
              let frame = screen?.visibleFrame else { return nil }
        let point = NSPoint(x: xy[0], y: xy[1])
        return frame.insetBy(dx: -2, dy: -2).contains(NSPoint(x: point.x + 1, y: point.y - 1)) ? point : nil
    }

    /// The panel's size for what shows now; at the top of the screen under the pointer.
    private func place() {
        let p = makePanel()
        // Measure at the window's current size. A temporary 400pt-high root can outlive setFrame when the
        // window's size is unchanged, putting this flipped view's top-aligned contents above the visible window.
        root.frame = NSRect(origin: .zero, size: p.contentLayoutRect.size)
        root.layoutSubtreeIfNeeded()
        let h = column.fittingSize.height + 24
        let screen = pinnedScreen ?? NSScreen.main
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = anchor ?? NSPoint(x: (v.midX - BoardCapsule.panelWidth / 2).rounded(), y: v.maxY - 6)
        p.setFrame(NSRect(x: max(v.minX, min(origin.x, v.maxX - BoardCapsule.panelWidth)),
                          y: max(v.minY, min(origin.y - h, v.maxY - h)), width: BoardCapsule.panelWidth, height: h), display: false)
        root.frame = NSRect(origin: .zero, size: p.contentLayoutRect.size)
        root.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        updateMousePassthrough(at: NSEvent.mouseLocation)
        trackMouse()
    }

    func updateMousePassthrough(at location: NSPoint) {
        guard let panel else { return }
        guard panel.isVisible, panel.alphaValue > 0.01, !NSApp.isHidden else {
            panel.ignoresMouseEvents = true
            return
        }
        if (panel as? BoardCapsulePanel)?.dragging == true { panel.ignoresMouseEvents = false; return }
        let point = panel.convertPoint(fromScreen: location)
        panel.ignoresMouseEvents = !visibleButtons(in: root).contains { Self.clippedFrame($0).contains(point) }
    }

    /// Where a view really shows, in window coordinates: its bounds cut to every superview's bounds. (`visibleRect`
    /// stopped doing this once views no longer clip to their superviews by default, macOS 14 SDK and later.)
    static func clippedFrame(_ view: NSView) -> NSRect {
        var rect = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let a = ancestor {
            rect = rect.intersection(a.convert(a.bounds, to: nil))
            ancestor = a.superview
        }
        return rect
    }

    private func visibleButtons(in view: NSView) -> [NSView] {
        guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else { return [] }
        if view === pill { return [view] }            // the whole body takes the mouse: it drags the capsule
        if let button = view as? NSButton { return button.isEnabled ? [button] : [] }
        if let tray = view as? BoardTrayView, tray.hasPages { return [tray] }
        if view is BoardTranscriptLabel || view is BoardDragHandle || view is NSScrollView { return [view] }
        return view.subviews.flatMap { visibleButtons(in: $0) }
    }

    /// A transparent NSWindow still intercepts clicks outside its controls unless the window itself opts out.
    private func trackMouse() {
        guard !visibleButtons(in: root).isEmpty else {
            mouseTimer?.invalidate()
            mouseTimer = nil
            panel?.ignoresMouseEvents = true
            return
        }
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.updateMousePassthrough(at: NSEvent.mouseLocation)
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    // MARK: states

    /// The row's controls: the tools (pen, shapes, undo, pause) as round icons, then 存这页 and 完成, with a thin
    /// rule between the drawing tools and the rest.
    func setControls(_ items: [Control]) {
        controlActions = items.map(\.run)
        var views: [NSView] = []
        for (index, item) in items.enumerated() {
            if index > 0, item.kind == .text || item.kind == .primary, items[index - 1].kind != .text {
                let rule = NSView()
                rule.wantsLayer = true
                rule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
                rule.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([rule.widthAnchor.constraint(equalToConstant: 1), rule.heightAnchor.constraint(equalToConstant: 20)])
                views.append(rule)
            }
            let button: NSButton
            switch item.kind {
            case .toggle, .icon:
                button = BoardRoundButton(symbol: item.symbol ?? "circle", title: item.title,
                                          style: item.kind == .toggle ? .toggle : .ring, on: item.on)
            case .text, .primary:
                // a real selector: with nil, Swift picks NSButton's own init(title:target:action:) (a system push button)
                let pill = BoardPillButton(title: item.title, target: self, action: #selector(controlTapped(_:)))
                pill.restyle(primary: item.kind == .primary)
                button = pill
            }
            button.target = self
            button.action = #selector(controlTapped(_:))
            button.tag = index
            button.toolTip = item.tip ?? button.toolTip
            views.append(button)
        }
        controls.setViews(views, in: .leading)
        for (i, v) in views.enumerated() where i + 1 < views.count && (v is BoardRoundButton) == false {
            controls.setCustomSpacing(8, after: v)
        }
        controls.isHidden = items.isEmpty
        place()
    }
    /// Plain text buttons (the self-checks), `selected` one filled.
    func setControls(_ actions: [Action], selected: Int, primary: Int = 3) {
        setControls(actions.enumerated().map { i, a in Control(title: a.title, kind: i == selected ? .primary : .text, run: a.run) })
    }

    @objc private func controlTapped(_ button: NSButton) {
        guard controlActions.indices.contains(button.tag) else { return }
        controlActions[button.tag]()
    }

    func beginSession() {
        pinnedScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        anchor = BoardCapsule.savedAnchor(on: pinnedScreen)
        previewBox.isHidden = true
        hideWork?.cancel()
        hideWork = nil
        sessionRow.isHidden = false
        messageRow.isHidden = true
        messageButtons.setViews([], in: .leading)
        buttonActions = []
        tray.set([])
        pill.setPen(false)
        shownWords = ""
        let p = makePanel()
        place()
        cancelHide()
        p.alphaValue = 0
        p.orderFrontRegardless()
        appear()
    }

    /// The capsule comes out of the top edge the way the Dynamic Island grows: a small pill at the middle of the top
    /// edge springs down and out to full size, its words fading in a beat later; whatever hangs under it (keys,
    /// cards) drops in after. Only layers move — the window keeps its frame, so a resize meanwhile (a permission
    /// warning arriving) never fights the animation. Reduce Motion: a short fade.
    private func appear() {
        guard let p = panel else { return }
        root.layoutSubtreeIfNeeded()
        if BoardMotion.reduced {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; p.animator().alphaValue = 1 }
            return
        }
        p.alphaValue = 1
        guard let layer = pill.layer else { return }
        let start = BoardMotion.fromTop(layer, scaleX: 0.34, scaleY: 0.42, lift: 12)
        layer.add(BoardMotion.spring("transform", from: NSValue(caTransform3D: start), to: NSValue(caTransform3D: CATransform3DIdentity),
                                     response: BoardMotion.bouncy.response, damping: BoardMotion.bouncy.damping), forKey: "board-grow")
        BoardMotion.fade(layer, from: 0, to: 1, duration: 0.14)
        BoardMotion.fade(pill.content?.layer, from: 0, to: 1, duration: 0.24, delay: 0.1)
        for other in root.subviews where other !== pill && !other.isHidden {
            guard let l = other.layer else { continue }
            l.add(BoardMotion.spring("transform.translation.y", from: 10, to: 0,
                                     response: BoardMotion.snappy.response, damping: BoardMotion.snappy.damping), forKey: "board-drop")
            BoardMotion.fade(l, from: 0, to: 1, duration: 0.22, delay: 0.12)
        }
    }

    /// counts hides: a hide's ending only takes the panel away if nothing showed it again meanwhile
    private var hideGeneration = 0
    /// Something shows the capsule: a hide still animating is called off and its shrink undone.
    private func cancelHide() {
        hideGeneration += 1
        pill.layer?.removeAnimation(forKey: "board-shrink")
        root.layer?.removeAnimation(forKey: "board-vanish")
    }

    /// the warnings the card shows now (it is rebuilt only when they change)
    private var shownWarnings: [String]?
    func update(page: Int, words w: String, mic: Mic, warnings: [Warning], hints: Bool) {
        pageLabel.stringValue = "第 \(page) 页"
        dot.mic = mic
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            words.plain(mic == .off ? "听写没开，只记你画的" : "正在听 · 按住 \(BoardHoldKey.current(.free).label) 就能画")
            words.textColor = BoardColor.secondary
        } else {
            // the newest words: the longest tail that really fits the label's two lines (a fixed character count
            // overflowed with Chinese, and the label then cut off the end — the words just said)
            words.textColor = BoardColor.text
            words.live(t, shown: BoardCapsule.newestWords(t, font: words.font ?? .systemFont(ofSize: 14),
                                                          width: BoardCapsule.wordsWidth, lines: words.maximumNumberOfLines))
        }
        shownWords = t

        let warningTexts = warnings.map(\.text)
        if warningTexts != shownWarnings {
            shownWarnings = warningTexts
            warningPermissions = []
            warningsBox.setViews(warnings.map { warningRow($0) }, in: .top)
        }
        warningCard.isHidden = warnings.isEmpty
        pageLabel.stringValue = warnings.isEmpty ? "第 \(page) 页" : "第 \(page) 页 · ⚠"
        hintsBox.isHidden = !hints
        place()
        if !NSApp.isHidden {
            let wasShown = panel?.isVisible == true
            cancelHide()
            panel?.orderFrontRegardless()
            if !wasShown { appear() }
        }
    }

    /// `text` if it fits `lines` lines of `width`, else "…" + the longest suffix that does.
    static func newestWords(_ text: String, font: NSFont, width: CGFloat, lines: Int) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let limit = ceil(font.boundingRectForFont.height * CGFloat(max(lines, 1)) + 1)
        func fits(_ s: String) -> Bool {
            let rect = (s as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            return ceil(rect.height) <= limit
        }
        // two lines hold well under 200 characters: measure only the tail (the whole page's text was measured ~12
        // times on every recognised word)
        let chars = Array(text.suffix(240))
        if chars.count == text.count, fits(text) { return text }
        var low = 0, high = chars.count       // keep `low` characters: fits; `high`: doesn't
        while high - low > 1 {
            let mid = (low + high) / 2
            if fits("…" + String(chars.suffix(mid))) { low = mid } else { high = mid }
        }
        return "…" + String(chars.suffix(low))
    }

    func setPen(_ on: Bool) {
        pill.setPen(on)
    }

    func setLevel(_ l: Float) { dot.level = CGFloat(l) }

    func setTray(_ thumbs: [CGImage]) {
        tray.set(thumbs)
        place()
    }

    /// Where a kept page lands: the tray's next slot, in screen points.
    func trayLanding() -> NSRect {
        guard let p = panel, tray.window != nil else { return NSRect(x: 0, y: 0, width: 44, height: 28) }
        let r = tray.convert(tray.nextSlot, to: nil)
        return p.convertToScreen(r)
    }

    func toast(_ text: String) {
        BoardNotices.shared.post(text)
        if BoardSession.shared.active { words.plain(text) }
    }

    /// counts tips: a fade-out only hides the pill if no newer tip came meanwhile
    private var tipGeneration = 0
    /// A short tip in the small pill under the capsule that fades away by itself (not kept with the notices).
    func tip(_ text: String, seconds: Double = 2.8) {
        toastWork?.cancel()
        tipGeneration += 1
        let generation = tipGeneration
        toastLabel.stringValue = text
        let wasHidden = toastPill.isHidden
        toastPill.alphaValue = 1
        toastPill.isHidden = false
        place()
        if wasHidden { BoardMotion.fade(toastPill.layer, from: 0, to: 1, duration: 0.2) }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.3
                self.toastPill.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.tipGeneration == generation else { return }
                self.toastPill.isHidden = true
                self.toastPill.alphaValue = 1
                self.place()
            })
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// The capsule turns into one message (pasting, done, cancelled); it hides after `seconds`.
    func message(_ m: Message, seconds: Double) {
        controls.isHidden = true
        previewBox.isHidden = true
        toastWork?.cancel()
        toastPill.isHidden = true
        warningCard.isHidden = true
        hintsBox.isHidden = true
        sessionRow.isHidden = true
        messageRow.isHidden = false
        pill.setPen(false)
        if let s = m.symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) {
            messageIcon.image = img
            messageIcon.contentTintColor = m.tint
            messageIcon.isHidden = false
        } else {
            messageIcon.isHidden = true
        }
        spinner.isHidden = !m.spinner
        if m.spinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        messageText.stringValue = m.text
        buttonActions = m.actions.map(\.run)
        messageButtons.setViews(m.actions.enumerated().map { i, a in pillButton(a.title, tag: i) }, in: .leading)
        place()
        panel?.alphaValue = 1
        if !NSApp.isHidden {
            let wasShown = panel?.isVisible == true
            cancelHide()
            panel?.orderFrontRegardless()
            if !wasShown { appear() }
        }

        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        if seconds.isFinite { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w) }
    }

    /// The capsule goes back into the top edge: it shrinks toward the middle of the top while fading, quickly (an
    /// exit is faster than an entrance), then the panel is taken away.
    func hide() {
        hideWork?.cancel(); hideWork = nil
        guard !BoardSession.shared.active else { return }
        mouseTimer?.invalidate(); mouseTimer = nil
        panel?.ignoresMouseEvents = true
        messageButtons.setViews([], in: .leading); buttonActions = []
        guard let p = panel, p.isVisible, !BoardMotion.reduced, let layer = pill.layer, let rootLayer = root.layer else {
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            return
        }
        hideGeneration += 1
        let generation = hideGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            p.orderOut(nil)
            p.alphaValue = 1
            layer.removeAnimation(forKey: "board-shrink")
            rootLayer.removeAnimation(forKey: "board-vanish")
        }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.toValue = NSValue(caTransform3D: BoardMotion.fromTop(layer, scaleX: 0.34, scaleY: 0.42, lift: 12))
        shrink.duration = 0.24
        shrink.timingFunction = BoardMotion.exit
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "board-shrink")
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.toValue = 0
        vanish.duration = 0.2
        vanish.beginTime = CACurrentMediaTime() + 0.04
        vanish.timingFunction = BoardMotion.exit
        vanish.fillMode = .both
        vanish.isRemovedOnCompletion = false
        rootLayer.add(vanish, forKey: "board-vanish")
        CATransaction.commit()
    }

    // MARK: pieces

    private func pillButton(_ title: String, tag: Int) -> NSButton {
        let b = BoardPillButton(title: title, target: self, action: #selector(tapped(_:)))
        b.restyle(primary: false)
        b.tag = tag
        return b
    }

    @objc private func tapped(_ b: NSButton) {
        guard b.tag < buttonActions.count else { return }
        buttonActions[b.tag]()
    }

    private var warningPermissions: [BoardPermission] = []

    private func warningRow(_ w: Warning) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = BoardColor.warn
        let t = NSTextField(labelWithString: w.text)
        label(t, size: 12, weight: .medium, color: BoardColor.text)
        var views: [NSView] = [icon, t]
        if let p = w.permission {
            let b = BoardPillButton(title: "打开设置", target: self, action: #selector(openPermission(_:)))
            warningPermissions.append(p)
            b.tag = warningPermissions.count - 1
            views.append(b)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)   // the card's trailing inset isn't kept by its stack
        return row
    }

    @objc private func openPermission(_ b: NSButton) {
        guard b.tag < warningPermissions.count else { return }
        warningPermissions[b.tag].open()
    }

    // MARK: preview (point-taken --board-preview DIR)

    func previewViews() -> NSView {
        _ = makePanel()
        place()
        return root
    }
}

/// The pill everything sits in: solid near-black with a soft shadow, as on the website (Liquid Glass came out a
/// washed-out grey over light pages).
class BoardCapsuleView: NSView {
    var radius: CGFloat = 21 { didSet { applyRadius() } }
    /// Never more than half the height: a radius past that drew pointed ends (the one-line message capsule was
    /// shorter than the radius it was given).
    private func applyRadius() {
        let r = bounds.height > 0 ? min(radius, bounds.height / 2) : radius
        layer?.cornerRadius = r
    }
    override func layout() {
        super.layout()
        applyRadius()
    }
    var tint: NSColor? { didSet { layer?.borderColor = (tint?.withAlphaComponent(0.45) ?? BoardColor.rim).cgColor } }
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let c = content else { return }
            let into: NSView = self
            c.translatesAutoresizingMaskIntoConstraints = false
            into.addSubview(c)
            NSLayoutConstraint.activate([
                c.leadingAnchor.constraint(equalTo: into.leadingAnchor), c.trailingAnchor.constraint(equalTo: into.trailingAnchor),
                c.topAnchor.constraint(equalTo: into.topAnchor), c.bottomAnchor.constraint(equalTo: into.bottomAnchor),
            ])
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = BoardColor.rim.cgColor
        layer?.backgroundColor = BoardColor.glass.cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 14
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setPen(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.borderWidth = on ? 2 : 1
        layer?.borderColor = on ? BoardColor.pen.cgColor : (tint?.withAlphaComponent(0.45) ?? BoardColor.rim).cgColor
        CATransaction.commit()
    }
}

final class BoardFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The mic dot: green and breathing with the voice while listening, hollow while starting, grey when off.
final class BoardDotView: NSView {
    var mic: BoardCapsule.Mic = .starting { didSet { restyle() } }
    var level: CGFloat = 0 {
        didSet {
            guard mic == .live else { return }
            let s = 1 + min(0.7, max(0, level) * 9)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            ring.transform = CATransform3DMakeScale(s * 1.25, s * 1.25, 1)
            ring.opacity = Float(min(0.55, level * 12))
            CATransaction.commit()
        }
    }
    private let core = CALayer()
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        layer?.addSublayer(core)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.frame = bounds
        core.cornerRadius = bounds.width / 2
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    private func restyle() {
        switch mic {
        case .live:
            core.backgroundColor = BoardColor.live.cgColor
            core.borderWidth = 0
            ring.backgroundColor = BoardColor.live.cgColor
        case .starting:
            core.backgroundColor = nil
            core.borderColor = BoardColor.secondary.cgColor
            core.borderWidth = 1.5
            ring.opacity = 0
        case .off:
            core.backgroundColor = NSColor(white: 1, alpha: 0.28).cgColor
            core.borderWidth = 0
            ring.opacity = 0
        }
    }
}

/// The kept pages, stacked like cards, newest on top, with how many.
final class BoardTrayView: NSView {
    var onOpen: (() -> Void)?
    var hasPages: Bool { n > 0 }
    override func mouseDown(with event: NSEvent) { if hasPages { onOpen?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    static let thumb = CGSize(width: 46, height: 30)
    private var layers: [CALayer] = []
    private let count = NSTextField(labelWithString: "")
    private var n = 0
    private var widthC: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        count.textColor = BoardColor.secondary
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)
        widthC = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([widthC, heightAnchor.constraint(equalToConstant: BoardTrayView.thumb.height + 6),
                                     count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                                     count.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var stackWidth: CGFloat { n == 0 ? 0 : BoardTrayView.thumb.width + CGFloat(min(n, 3) - 1) * 6 }

    /// the rect a new page lands in (this view's coordinates)
    var nextSlot: NSRect {
        let k = min(n, 2)
        return NSRect(x: CGFloat(k) * 6, y: 3, width: BoardTrayView.thumb.width, height: BoardTrayView.thumb.height)
    }

    func set(_ thumbs: [CGImage]) {
        let grew = thumbs.count > n
        n = thumbs.count
        layers.forEach { $0.removeFromSuperlayer() }
        layers = []
        for (i, img) in thumbs.suffix(3).enumerated() {
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.cornerRadius = 4
            l.borderWidth = 1
            l.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
            l.frame = CGRect(x: CGFloat(i) * 6, y: 3, width: BoardTrayView.thumb.width, height: BoardTrayView.thumb.height)
            layer?.addSublayer(l)
            layers.append(l)
        }
        count.stringValue = n > 0 ? "\(n) 页" : ""
        count.sizeToFit()
        widthC.constant = n == 0 ? 0 : stackWidth + 8 + count.fittingSize.width + 2
        if grew, let top = layers.last, !BoardMotion.reduced {
            top.add(BoardMotion.spring("transform.scale", from: 0.6, to: 1,
                                       response: BoardMotion.bouncy.response, damping: 0.6), forKey: "land")
        }
    }
}

/// The keys, as keycaps, under the capsule.
final class BoardHintsView: BoardCapsuleView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = 16
        let lines: [[(String?, String)]] = [
            [(BoardHoldKey.current(.free).label, "按住画"), (BoardHoldKey.current(.box).label, "按住画矩形"), (nil, "松开就回到正常操作")],
            [(nil, BoardHoldKey.tools.contains { BoardHoldKey.current($0).code != nil }
                ? "点按钮则一直保持；录音期间这两个组合只用来画"
                : "点按钮则一直保持；其他按键都照常交给当前程序")],
        ]
        let rows = lines.map { items -> NSStackView in
            let r = NSStackView(views: items.flatMap { k, d -> [NSView] in
                var v: [NSView] = []
                if let k { v.append(BoardKeyCap(k)) }
                let t = NSTextField(labelWithString: d)
                t.font = .systemFont(ofSize: 12)
                t.textColor = BoardColor.secondary
                v.append(t)
                return v
            })
            r.spacing = 6
            r.alignment = .centerY
            r.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 14)   // the column drops its own trailing inset
            for (i, v) in r.arrangedSubviews.enumerated() where v is NSTextField && i < r.arrangedSubviews.count - 1 {
                r.setCustomSpacing(16, after: v)
            }
            return r
        }
        let col = NSStackView(views: rows)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 7
        col.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 0)
        content = col
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class BoardKeyCap: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 11.5, weight: .semibold)
        t.textColor = BoardColor.text
        t.translatesAutoresizingMaskIntoConstraints = false
        addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            t.topAnchor.constraint(equalTo: topAnchor, constant: 2), t.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A round icon button on the capsule (the website demo's look): a soft disc; `.toggle` fills orange while on (the
/// pen), `.ring` turns its icon and ring orange while on (the chosen shape, paused). The hold-to-draw keys aren't
/// written on the buttons (a badge that small couldn't be read); clicking a tool shows its key in a short tip.
final class BoardRoundButton: NSButton {
    enum Style { case toggle, ring }
    static let size: CGFloat = 30
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    /// laid out by its drawn frame (a button's default alignment insets made the discs uneven and the row overflow)
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    init(symbol: String, title: String, style: Style, on: Bool) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        symbolConfiguration = .init(pointSize: 13, weight: .medium)
        contentTintColor = BoardColor.text
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = Self.size / 2
        let fill = style == .toggle && on, ringed = style == .ring && on
        // chosen: an orange icon in an orange ring (an orange tint over the dark capsule turned muddy brown)
        layer?.backgroundColor = (fill ? BoardColor.pen : NSColor(white: 1, alpha: ringed ? 0.14 : 0.10)).cgColor
        layer?.borderWidth = ringed ? 1.5 : 0
        layer?.borderColor = BoardColor.pen.cgColor
        if ringed { contentTintColor = BoardColor.pen }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.size),
                                     heightAnchor.constraint(equalToConstant: Self.size)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class BoardPillButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// "自由画" + keySeparator + "⌥": the title, then its hold key drawn dimmer.
    static let keySeparator = "\u{2002}"

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        layer?.cornerRadius = 11
        let parts = title.components(separatedBy: BoardPillButton.keySeparator)
        let text = NSMutableAttributedString(string: parts[0], attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: BoardColor.text])
        if parts.count > 1 {
            text.append(NSAttributedString(string: " " + parts[1], attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: BoardColor.secondary]))
            toolTip = "按住 \(parts[1]) 临时\(parts[0])，松开回到正常操作；点一下则一直保持，再点一下取消"
        }
        self.title = parts[0]
        attributedTitle = text
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 22)
        widthConstraint = widthAnchor.constraint(equalToConstant: (attributedTitle.size().width + 22).rounded())
        NSLayoutConstraint.activate([heightConstraint!, widthConstraint!])
    }
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    /// The capsule row's text buttons: as tall as the round icons; 完成 (primary) white with dark words.
    func restyle(primary: Bool) {
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: primary ? NSColor(white: 0.08, alpha: 1) : BoardColor.text])
        attributedTitle = text
        layer?.backgroundColor = (primary ? NSColor(white: 1, alpha: 0.96) : NSColor(white: 1, alpha: 0.14)).cgColor
        layer?.cornerRadius = BoardRoundButton.size / 2
        heightConstraint?.constant = BoardRoundButton.size
        widthConstraint?.constant = (text.size().width + 28).rounded()
    }
}

// MARK: - continuous audio and transcript, independent of page boundaries

/// Annotation's final pass has its own explicit selection; standalone dictation stays disabled.
enum BoardTranscription {
    static let apple = "board-apple-speech"
    static var selected: String {
        (recordConfig()["board"] as? [String: Any])?["transcriptionModel"] as? String ?? apple
    }
    static func select(_ id: String) {
        var board = recordConfig()["board"] as? [String: Any] ?? [:]
        board["transcriptionModel"] = id
        setRecordConfig("board", board)
    }
    static func transcribe(_ url: URL, locale: String, model: String,
                           done: @escaping (Result<BoardSpeech.FileTranscript, Error>) -> Void) {
        BoardModelStatus.writeReceipt(audio: url, state: "requested", model: model)
        if model == apple {
            BoardSpeech.appleFile(url, locale) { result in
                let succeeded = (try? result.get()) != nil
                BoardModelStatus.writeReceipt(audio: url, state: succeeded ? "success" : "failed", model: model,
                                              response: ["model": model, "provider": "apple"])
                done(result)
            }
            return
        }
        // A model is explicit, never automatic; no dictation gate, polish, or speaker filtering.
        Scripts.call("transcribe.py", ["note", url.path, "--model-id", model, "--segments", "--no-download"], timeout: 590) { result in
            switch result {
            case .failure(let error):
                BoardModelStatus.writeReceipt(audio: url, state: "failed", model: model, response: ["code": error.code])
                done(.failure(BoardLongImage.Failure(message: BoardModelStatus.failureText(error.code))))
            case .success(let object):
                guard object["model"] as? String == model, let text = object["text"] as? String,
                      let rows = object["segments"] as? [[String: Any]], object["looped"] as? Bool != true else {
                    BoardModelStatus.writeReceipt(audio: url, state: "failed", model: model, response: ["code": "incomplete_response"])
                    done(.failure(BoardLongImage.Failure(message: "模型返回不完整，已保留原始录音和实时文字。")))
                    return
                }
                let segments = rows.compactMap { row -> BoardSpeechSegment? in
                    guard let start = row["start"] as? Double, let end = row["end"] as? Double,
                          let words = row["text"] as? String, start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                    return BoardSpeechSegment(start: start, end: end, text: words)
                }
                guard segments.count == rows.count else {
                    BoardModelStatus.writeReceipt(audio: url, state: "failed", model: model, response: ["code": "incomplete_response"])
                    done(.failure(BoardLongImage.Failure(message: "模型返回的转写时间不完整，已保留原始录音和实时文字。")))
                    return
                }
                BoardModelStatus.writeReceipt(audio: url, state: "success", model: model, response: object)
                done(.success(BoardSpeech.FileTranscript(text: text, segments: segments)))
            }
        }
    }
}

final class BoardSpeech {
    enum Status { case starting, listening, off(String, BoardPermission?) }
    private(set) var status: Status = .off("", nil)
    private(set) var archiveWarning: String?
    var onText: ((String) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var selectedLive: BoardLiveSpeech?
    private var liveID = UUID()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = BoardTranscript()
    private var directory: URL?
    private var audio: BoardAudioArchive?
    private var audioPipeline: BoardAudioPipeline?
    private var audioArchiveIncomplete = false {
        didSet {
            if audioArchiveIncomplete { timedSegments = []; finalTranscriptVerified = false }
        }
    }
    private var audioPipelineStopped = false
    private var audioDraining = false
    private let transcriptWriter = DispatchQueue(label: "pointtaken.board.transcript", qos: .utility)
    private var pendingTranscriptWrite: DispatchWorkItem?
    private var persistedTranscript: String?
    private var savedAudioSeconds: Double?
    var hasReliableAudioTimeline: Bool { !audioArchiveIncomplete }
    var audioSeconds: Double? { hasReliableAudioTimeline ? (audio?.seconds ?? savedAudioSeconds) : nil }
    private(set) var timedSegments: [BoardSpeechSegment] = []
    /// Live PCM includes buffers that a damaged WAV may lack; never publish their shifted positions as raw-audio evidence.
    func updateTiming(_ evidence: inout BoardEvidence) {
        evidence.speech = hasReliableAudioTimeline ? timedSegments : []
        evidence.speechTimingSource = evidence.speech.isEmpty ? "unavailable" : "original-audio-file"
    }
    struct FileTranscript {
        var text: String
        var segments: [BoardSpeechSegment] = []
    }
    private var generation = 0
    private var sessionID = UUID()
    private var running = false
    private var paused = false
    private var tapInstalled = false
    private var stopping: [() -> Void] = []
    private var levelTick = 0
    private var errorCount = 0
    private var locale = "zh-CN"
    private var finalizing = false
    private var skipFileFinalization = false
    private(set) var finalTranscriptVerified = false
    /// The live session of the recording just stopped, once it has ended (its result decides the final pass).
    private var finishedLive: BoardLiveSpeech?
    private var finalModel = BoardTranscription.selected
    var transcriptionModel: String { finalModel }
    // Injectable for retention checks. Production snapshots the selection when recording begins.
    var transcribeFile: (URL, String, @escaping (Result<FileTranscript, Error>) -> Void) -> Void = { url, locale, done in
        BoardTranscription.transcribe(url, locale: locale, model: BoardTranscription.selected, done: done)
    }
    static func appleFile(_ url: URL, _ locale: String, _ done: @escaping (Result<FileTranscript, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            let result: Result<FileTranscript, Error>
            do {
                guard AppleSpeech.available, await AppleSpeech.assets(locale) == .installed else {
                    throw AppleSpeech.Failure.unsupported
                }
                let segments = try await AppleSpeech.recognize(url, locale: locale)
                result = .success(FileTranscript(text: AppleSpeech.join(segments, locale: locale),
                    segments: segments.map { BoardSpeechSegment(start: $0.start, end: $0.end, text: $0.text) }))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { done(result) }
        }
    }

    var pageText: String { transcript.pageText }
    var fullText: String { transcript.text }
    var isRecording: Bool { engine.isRunning }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private func set(_ value: Status) { status = value; onStatus?(value) }

    private func changed() {
        persist()
        onText?(pageText)
    }

    private func persist(completion: (() -> Void)? = nil) {
        guard let directory else { completion?(); return }
        if completion != nil {
            pendingTranscriptWrite?.cancel(); pendingTranscriptWrite = nil
            writeTranscript(fullText, to: directory, completion: completion)
            return
        }
        // Throttle, rather than debounce: continuous partials must still reach disk every 250 ms.
        guard pendingTranscriptWrite == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.directory == directory else { return }
            self.pendingTranscriptWrite = nil
            self.writeTranscript(self.fullText, to: directory, completion: nil)
        }
        pendingTranscriptWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func writeTranscript(_ text: String, to directory: URL, completion: (() -> Void)?) {
        transcriptWriter.async { [weak self] in
            guard let self else { return }
            var failure: Error?
            if self.persistedTranscript != text {
                do {
                    try text.write(to: directory.appendingPathComponent("完整转写.txt"), atomically: true, encoding: .utf8)
                    self.persistedTranscript = text
                } catch { failure = error }
            }
            DispatchQueue.main.async {
                guard self.directory == directory else { return }
                if let failure {
                    self.finalTranscriptVerified = false
                    self.archiveWarning = "转写保存失败：\(failure.localizedDescription)"
                    self.onStatus?(self.status)
                }
                completion?()
            }
        }
    }

    func start(locale: String, directory: URL) {
        sessionID = UUID()
        let id = sessionID
        self.directory = directory
        self.locale = locale
        liveID = UUID()
        finalModel = BoardTranscription.selected
        let model = finalModel
        transcribeFile = { url, locale, done in
            BoardTranscription.transcribe(url, locale: locale, model: model, done: done)
        }
        transcript = BoardTranscript()
        pendingTranscriptWrite?.cancel(); pendingTranscriptWrite = nil
        transcriptWriter.async { [weak self] in self?.persistedTranscript = nil }
        audioArchiveIncomplete = false
        audioPipelineStopped = false
        audioDraining = false
        timedSegments = []; savedAudioSeconds = nil
        finishedLive = nil
        paused = false
        finalizing = false
        skipFileFinalization = false
        finalTranscriptVerified = false
        archiveWarning = nil
        errorCount = 0
        recognizer = nil
        persist()
        persistState("recording")
        set(.starting)
        // Record the original microphone independently of speech-recognition permission/availability.
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard id == self.sessionID, BoardSession.shared.active else { return }
                guard ok else { self.set(.off("麦克风未获准，不能保存录音", .microphone)); return }
                guard self.beginAudio() else { return }
                guard self.finalModel == BoardTranscription.apple else { return }
                SFSpeechRecognizer.requestAuthorization { auth in
                    DispatchQueue.main.async {
                        guard id == self.sessionID, self.running else { return }
                        guard auth == .authorized else {
                            self.set(.off("原始录音正在保存；转写需要「语音识别」权限", .speech)); return
                        }
                        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
                            self.set(.off("语音识别暂不可用，不影响录音", nil)); return
                        }
                        self.recognizer = recognizer
                        self.newRequest()
                    }
                }
            }
        }
    }

    private func beginAudio() -> Bool {
        guard let directory else { return false }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            set(.off("没找到可用的麦克风", nil)); return false
        }
        let writer: BoardAudioArchive
        do { writer = try BoardAudioArchive(url: directory.appendingPathComponent("原始录音.wav"), format: format) }
        catch { set(.off("原始录音无法保存：\(error.localizedDescription)", nil)); return false }
        audio = writer
        var live: BoardLiveSpeech?
        if finalModel != BoardTranscription.apple {
            do {
                let source = try BoardLiveSpeech(model: finalModel, directory: directory, format: format)
                let id = liveID
                source.onText = { [weak self] words, final in
                    guard let self, id == self.liveID else { return }
                    self.transcript.update(words, final: final)
                    self.changed()
                }
                source.onReady = { [weak self] in
                    guard let self, id == self.liveID, self.running, !self.paused else { return }
                    self.set(.listening)
                }
                source.onFailure = { [weak self] message in
                    guard let self, id == self.liveID else { return }
                    self.set(.off(BoardModelStatus.name(self.finalModel) + "实时字幕失败：" + message + "。不影响录音。", nil))
                }
                source.onFinalizing = { [weak self] in
                    guard let self, id == self.liveID else { return }
                    self.persistState("finalizing")
                    self.set(.off("正在根据原始录音整理完整转写…", nil))
                }
                live = source
                selectedLive = source
            } catch {
                set(.off("所选模型实时字幕无法启动，不影响录音。", nil))
            }
        }
        var writeWarningSent = false // accessed only on the serial audio worker
        let pipeline = BoardAudioPipeline(consume: { [weak self, live] buffer in
            guard let self else { return }
            // A failed write must not permanently disable every later buffer. Retrying the following buffers
            // preserves as much raw audio as possible, and the final pass must never certify a partial archive.
            do { try writer.append(buffer) }
            catch {
                if !writeWarningSent {
                    writeWarningSent = true
                    DispatchQueue.main.async {
                        guard !self.audioArchiveIncomplete else { return }
                        self.audioArchiveIncomplete = true
                        self.finalTranscriptVerified = false
                        self.archiveWarning = "原始录音部分写入失败，录音可能不完整：\(error.localizedDescription)"
                        self.set(.off("录音保存异常；实时文字仍保留，请检查存储空间", nil))
                    }
                }
            }
            live?.append(buffer)
            self.lock.lock(); self.request?.append(buffer); self.lock.unlock()
            self.levelTick += 1
            if self.levelTick % 2 == 0, let channel = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<count { sum += channel[i] * channel[i] }
                let rms = count > 0 ? sqrt(sum / Float(count)) : 0
                DispatchQueue.main.async { self.onLevel?(rms) }
            }
        }, failed: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.audioArchiveIncomplete = true
                self.audioPipelineStopped = true
                self.archiveWarning = "音频保存跟不上麦克风，录音已暂停；已接收的录音和实时文字会保留。"
                self.setPaused(true)
                self.set(.off("录音已暂停：请检查存储空间后结束本次录音", nil))
            }
        })
        audioPipeline = pipeline
        var exception: NSError?
        let installed = PointTakenTry({
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, pipeline] buffer, _ in
                guard let self else { return }
                self.lock.lock(); let suspended = self.paused; self.lock.unlock()
                guard !suspended else { return }
                pipeline.append(buffer)
            }
        }, &exception)
        guard installed else {
            pipeline.finish { writer.close() }; audioPipeline = nil; audio = nil
            live?.cancel(); selectedLive = nil
            set(.off("麦克风启动失败：\(exception?.localizedDescription ?? "设备格式变化")", nil))
            return false
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0); tapInstalled = false
            pipeline.finish { writer.close() }; audioPipeline = nil; audio = nil
            live?.cancel(); selectedLive = nil
            set(.off("麦克风打不开：\(error.localizedDescription)", nil)); return false
        }
        running = true
        if paused { engine.pause() }
        if finalModel == BoardTranscription.apple { set(.starting) }
        else if let live { set(.starting); live.start() }
        return true
    }

    private func newRequest() {
        guard running, !paused, let recognizer else { return }
        generation += 1
        let gen = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        lock.lock()
        self.request = request
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { self?.result(result, error: error, gen: gen) }
        }
        set(.listening)
    }

    private func result(_ result: SFSpeechRecognitionResult?, error: Error?, gen: Int) {
        receive(words: result?.bestTranscription.formattedString,
                final: result?.isFinal == true || error != nil, failed: error != nil, gen: gen,
                utteranceComplete: result?.speechRecognitionMetadata != nil)
    }

    private func receive(words: String?, final: Bool, failed: Bool, gen: Int, utteranceComplete: Bool = false) {
        guard gen == generation else { return }
        if let words { transcript.update(words, final: final, utteranceComplete: utteranceComplete) }
        else if final { transcript.commit() }
        changed()
        guard final else { return }
        generation += 1 // Ignore late callbacks from the completed request, including repeated final results.
        lock.lock(); request = nil; lock.unlock()
        task = nil
        if !stopping.isEmpty {
            if !audioDraining { completeStop() }
            return
        }
        guard running else { return }
        if failed {
            errorCount += 1
            set(.off("实时字幕暂时中断，不影响录音", nil))
            let id = sessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + min(5, Double(errorCount))) { [weak self] in
                guard let self, id == self.sessionID else { return }
                self.newRequest()
            }
        } else { errorCount = 0; newRequest() }
    }

    func setPaused(_ value: Bool) {
        guard value || !audioPipelineStopped else {
            set(.off("录音保存异常，请先结束本次录音；已接收的内容会保留", nil)); return
        }
        lock.lock(); paused = value; lock.unlock()
        if value {
            engine.pause()
            lock.lock(); let pending = request; lock.unlock()
            let live = selectedLive
            let boundary = { live?.setPaused(true); pending?.endAudio() }
            if let audioPipeline { audioPipeline.afterPending(boundary) }
            else { boundary() }
            set(.off("已暂停", nil))
        } else if running {
            do {
                let live = selectedLive
                if let audioPipeline { audioPipeline.afterPending { live?.setPaused(false) } }
                else { live?.setPaused(false) }
                try engine.start()
                if finalModel != BoardTranscription.apple {
                    if selectedLive?.healthy == true { set(.listening) }
                    else { set(.off("所选模型实时字幕不可用，不影响录音。", nil)) }
                    return
                }
                if task == nil { newRequest() }
                if recognizer == nil { set(.off("正在保存原始录音；实时转写暂不可用", .speech)) }
                else { set(.listening) }
            }
            catch { set(.off("恢复麦克风失败：\(error.localizedDescription)", nil)) }
        }
    }

    /// Saving a screenshot marks a text boundary; it never interrupts microphone input or recognition.
    func cut(_ done: @escaping (String) -> Void) {
        let words = transcript.markPage()
        changed()
        done(words)
    }

    /// What a failed final transcript leaves behind, said as done (not "still saving"), and only naming live text
    /// when there is some.
    private var keptNote: String {
        (fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "原始录音已保存" : "原始录音和实时文字已保存")
            + "，可在「历史记录」里重新转写。"
    }

    /// Quitting saves audio and the real-time transcript, without holding the app open for a long
    /// file-recognition job. The user can rerun that job from History.
    func stopForQuit(_ done: @escaping (String) -> Void) {
        skipFileFinalization = true
        if !audioArchiveIncomplete {
            archiveWarning = "原始录音已保存；完整转写没做，可从历史重新转写。"
        }
        liveID = UUID()
        selectedLive?.cancel(); selectedLive = nil
        if finalizing {
            generation += 1
            stopping.append { [weak self] in done(self?.pageText ?? "") }
            finishFinalization()
        } else { stop(done) }
    }

    /// Stop audio immediately, then wait briefly for the recognizer's final correction/tail.
    func stop(_ done: @escaping (String) -> Void) {
        stopping.append { [weak self] in done(self?.pageText ?? "") }
        guard stopping.count == 1 else { return }
        running = false
        sessionID = UUID() // A pending permission response must not restart a stopped session.
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if let pipeline = audioPipeline, let writer = audio {
            audioDraining = true
            pipeline.finish { [weak self] in
                writer.close()
                let seconds = writer.seconds
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.savedAudioSeconds = seconds
                    self.audioDraining = false
                    self.audio = nil; self.audioPipeline = nil
                    self.finishAudioStop()
                }
            }
        } else {
            audio?.close(); savedAudioSeconds = audio?.seconds; audio = nil
            finishAudioStop()
        }
    }

    private func finishAudioStop() {
        if let live = selectedLive {
            live.finish { [weak self] in
                guard let self else { return }
                self.selectedLive = nil
                self.finishedLive = live
                self.completeStop()
            }
            return
        }
        lock.lock()
        let pending = request
        pending?.endAudio()
        lock.unlock()
        guard pending != nil else { completeStop(); return }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, gen == self.generation, !self.stopping.isEmpty else { return }
            self.completeStop()
        }
    }

    private func completeStop() {
        guard !finalizing else { return }
        finalizing = true
        generation += 1
        task?.cancel(); task = nil
        lock.lock(); request = nil; lock.unlock()
        transcript.commit()
        changed()
        guard let directory else { finishFinalization(); return }
        let url = directory.appendingPathComponent("原始录音.wav")
        guard FileManager.default.fileExists(atPath: url.path) else { finishFinalization(); return }
        do { try fullText.write(to: directory.appendingPathComponent("实时转写.txt"), atomically: true, encoding: .utf8) }
        catch { archiveWarning = "实时转写备份失败：\(error.localizedDescription)" }
        if skipFileFinalization { finishFinalization(); return }
        // File recognition cannot recover samples that could not be archived. Keep the longer live text intact.
        if audioArchiveIncomplete { finalTranscriptVerified = false; finishFinalization(); return }
        if let live = finishedLive, live.fileFinalizationAttempted {
            if let file = live.finalFileTranscript {
                applyFileTranscript(file, directory: directory)
                BoardModelStatus.writeReceipt(audio: url, state: finalTranscriptVerified ? "success" : "failed",
                                              model: finalModel, response: live.receiptMetadata)
            } else {
                archiveWarning = "完整转写未完成。" + keptNote
            }
            finishFinalization()
            return
        }
        // Doubao already re-recognised every sentence while it was said (two-pass): keep that as the final
        // transcript instead of sending the whole recording again and waiting ~¼ of its length. Anything less
        // than a clean, complete live session still takes the file pass below.
        if let live = finishedLive, live.finalQuality, live.model == finalModel,
           !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            timedSegments = live.segments
            var receipt = live.receiptMetadata
            receipt["model"] = finalModel
            BoardModelStatus.writeReceipt(audio: url, state: "success", model: finalModel, response: receipt)
            finalTranscriptVerified = true
            finishFinalization()
            return
        }
        persistState("finalizing")
        set(.off("正在根据原始录音整理完整转写…", nil))
        let gen = generation
        transcribeFile(url, locale) { [weak self] result in
            guard let self, self.finalizing, self.generation == gen else { return }
            switch result {
            case .success(let file):
                self.applyFileTranscript(file, directory: directory)
            case .failure(let error):
                self.archiveWarning = "完整转写失败：" + error.localizedDescription + "。" + self.keptNote
            }
            self.finishFinalization()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, self.finalizing, self.generation == gen else { return }
            self.archiveWarning = "完整转写超时。" + self.keptNote
            self.finishFinalization()
        }
    }

    private func applyFileTranscript(_ file: FileTranscript, directory: URL) {
        if file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fullText.isEmpty {
            archiveWarning = "完整转写没有返回文字。" + keptNote
            return
        }
        transcript.replaceWithFileTranscript(file.text)
        timedSegments = file.segments.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        finalTranscriptVerified = true
    }

    private func persistState(_ state: String) {
        guard let directory else { return }
        let fields: [String: Any] = ["state": state, "locale": locale, "model": finalModel, "liveModel": finalModel, "updatedAt": Date().timeIntervalSince1970,
                                     "warning": archiveWarning ?? "", "audioTimelineAvailable": hasReliableAudioTimeline]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) {
            do { try data.write(to: directory.appendingPathComponent("转写状态.json"), options: .atomic) }
            catch { archiveWarning = "转写状态保存失败：\(error.localizedDescription)" }
        }
    }

    private func finishFinalization() {
        onText?(pageText)
        persist { [weak self] in
            guard let self else { return }
            self.persistState(self.finalTranscriptVerified ? "complete" : "incomplete")
            self.finalizing = false
            self.set(.off("", nil))
            let callbacks = self.stopping
            self.stopping = []
            callbacks.forEach { $0() }
        }
    }
}

// A deterministic check of the real recognition boundary and paste-plan paths. No microphone,
// screenshots, permission prompts, clipboard writes, or user directories are used.
extension BoardSpeech {
    static func runRetentionCheck() -> Never {
        func waitFor(_ ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !ready(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("point-taken-retention-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { exit(2) }
        let speech = BoardSpeech()
        speech.directory = directory
        speech.receive(words: "先交代背景：给老年人使用。", final: false, failed: false, gen: 0)
        var checks: [String: Bool] = [:]
        speech.cut { _ in }
        checks["page_does_not_restart_recognition"] = speech.generation == 0
        speech.receive(words: "先交代背景：给老年人使用。按钮放大。", final: true, failed: false, gen: 0)
        speech.cut { _ in }
        speech.receive(words: "最后补充", final: false, failed: false, gen: speech.generation)
        // An in-flight recognizer: finish must wait for this request's last correction.
        speech.request = SFSpeechAudioBufferRecognitionRequest()
        let generation = speech.generation
        var completed = false
        speech.stop { _ in
            let expected = "先交代背景：给老年人使用。按钮放大。 最后补充：不要改颜色。"
            checks["final_words_saved"] = speech.fullText == expected
            checks["transcript_on_disk"] = (try? String(contentsOf: directory.appendingPathComponent("完整转写.txt"), encoding: .utf8)) == expected
            let images = [directory.appendingPathComponent("图1.png"), directory.appendingPathComponent("图2.png")]
            let pages = images.map { BoardSession.Page(images: [$0], text: "只涉及此页", thumb: nil) }
            do {
                for image in images { try Data([1, 2, 3]).write(to: image) }
                let export = try BoardSession.exportFolder(pages: pages, transcript: speech.fullText, evidence: nil,
                                                           root: directory.appendingPathComponent("exports"))
                let steps = BoardSession.deliverySteps(export: export)
                checks["handoff_full_transcript"] = export.text.contains(expected)
                checks["paste_text_only"] = steps == [.text(export.text)]
                checks["all_images_in_order"] = export.images.map(\.lastPathComponent) == ["图1.png", "图2.png"]
                let speechOnly = try BoardSession.exportFolder(pages: [], transcript: speech.fullText, evidence: nil,
                                                               root: directory.appendingPathComponent("exports"))
                checks["deleting_all_pages_keeps_speech"] = speechOnly.text.contains(expected) && speechOnly.images.isEmpty
            } catch { checks["folder_export_succeeded"] = false }
            completed = true
        }
        checks["finish_waits_for_final"] = !completed
        speech.receive(words: "最后补充：不要改颜色。", final: true, failed: false, gen: generation)
        waitFor { completed }
        // Replay the actual partial/reset sequence through the callback receiver and disk writer.
        let paused = BoardSpeech()
        paused.directory = directory
        paused.receive(words: "开场背景。", final: false, failed: false, gen: 0, utteranceComplete: true)
        paused.cut { _ in }
        paused.receive(words: "补充", final: false, failed: false, gen: 0)
        paused.receive(words: "补充要求。", final: false, failed: false, gen: 0, utteranceComplete: true)
        checks["pause_keeps_previous_utterance"] = paused.fullText == "开场背景。 补充要求。"
        checks["pause_keeps_next_page_words"] = paused.pageText.trimmingCharacters(in: .whitespaces) == "补充要求。"
        // Exercise stop → file transcriber → persist → callback, with a controlled async boundary.
        let audioURL = directory.appendingPathComponent("原始录音.wav")
        try? Data().write(to: audioURL)
        var fileResult: ((Result<FileTranscript, Error>) -> Void)?
        paused.transcribeFile = { url, _, done in
            checks["final_pass_uses_saved_audio"] = url == audioURL
            fileResult = done
        }
        var fileFinished = false
        paused.stop { _ in
            fileFinished = true
            checks["final_pass_includes_missed_background_and_tail"] = paused.fullText == "开场背景。补充要求。识别重启时的说明。最后一句。"
            checks["final_pass_saved_before_review"] = (try? String(contentsOf: directory.appendingPathComponent("完整转写.txt"), encoding: .utf8)) == paused.fullText
            checks["final_pass_verified"] = paused.finalTranscriptVerified
        }
        checks["review_waits_for_whole_audio"] = !fileFinished && fileResult != nil
        fileResult?(.success(.init(text: "开场背景。补充要求。识别重启时的说明。最后一句。", segments: [BoardSpeechSegment(start: 0, end: 3, text: "开场背景。")])) )
        waitFor { fileFinished }
        checks["final_pass_keeps_phrase_timestamps"] = paused.timedSegments == [BoardSpeechSegment(start: 0, end: 3, text: "开场背景。")]
        checks["final_pass_completes_once"] = fileFinished
        let failed = BoardSpeech()
        failed.directory = directory
        failed.receive(words: "实时文字必须保留", final: false, failed: false, gen: 0)
        failed.transcribeFile = { _, _, done in done(.failure(NSError(domain: "fixture", code: 1))) }
        failed.stop { _ in
            checks["file_failure_preserves_live_text"] = failed.fullText == "实时文字必须保留"
                && !failed.finalTranscriptVerified && failed.archiveWarning != nil
        }
        waitFor { checks["file_failure_preserves_live_text"] != nil }
        let quitting = BoardSpeech()
        quitting.directory = directory
        quitting.receive(words: "退出前的完整实时稿", final: false, failed: false, gen: 0)
        var triedFilePass = false, quitFinished = false
        quitting.transcribeFile = { _, _, _ in triedFilePass = true }
        quitting.stopForQuit { _ in quitFinished = true }
        waitFor { quitFinished }
        checks["quit_keeps_text_without_waiting_for_file_pass"] = quitFinished && !triedFilePass && quitting.fullText == "退出前的完整实时稿"
        let alreadyFinishing = BoardSpeech()
        alreadyFinishing.directory = directory
        alreadyFinishing.receive(words: "收尾中的实时稿", final: false, failed: false, gen: 0)
        var delayed: ((Result<FileTranscript, Error>) -> Void)?
        alreadyFinishing.transcribeFile = { _, _, done in delayed = done }
        alreadyFinishing.stop { _ in }
        var interrupted = false
        alreadyFinishing.stopForQuit { _ in interrupted = true }
        delayed?(.success(.init(text: "迟到的结果不能改写已退出的会话")))
        waitFor { interrupted }
        checks["quit_cancels_wait_and_ignores_late_file_result"] = interrupted && alreadyFinishing.fullText == "收尾中的实时稿"
        // Continuous partials are saved periodically, even when there is never a quiet debounce window.
        let continuous = BoardSpeech()
        continuous.directory = directory.appendingPathComponent("continuous")
        try? FileManager.default.createDirectory(at: continuous.directory!, withIntermediateDirectories: true)
        for n in 0..<12 {
            continuous.receive(words: "持续说话第\(n)句", final: false, failed: false, gen: 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let continuousFile = continuous.directory!.appendingPathComponent("完整转写.txt")
        checks["continuous_partials_reach_disk_before_stop"] = !((try? String(contentsOf: continuousFile, encoding: .utf8)) ?? "").isEmpty
        var continuousStopped = false
        continuous.stopForQuit { _ in continuousStopped = true }
        waitFor { continuousStopped }
        checks["continuous_final_text_saved_before_callback"] = (try? String(contentsOf: continuousFile, encoding: .utf8)) == continuous.fullText

        // Stop during a slow archive write. A recognizer's final callback must not close the file early.
        let draining = BoardSpeech()
        draining.directory = directory.appendingPathComponent("draining")
        try? FileManager.default.createDirectory(at: draining.directory!, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for n in 0..<1024 { buffer.floatChannelData![0][n] = Float(n) / 1024 }
        let drainFile = draining.directory!.appendingPathComponent("原始录音.wav")
        let writer = try! BoardAudioArchive(url: drainFile, format: format)
        let startedWriting = DispatchSemaphore(value: 0), allowWriting = DispatchSemaphore(value: 0)
        var firstBuffer = true
        let pipeline = BoardAudioPipeline(consume: { buffer in
            if firstBuffer { firstBuffer = false; startedWriting.signal(); allowWriting.wait() }
            try! writer.append(buffer)
        }, failed: { _ in })
        draining.audio = writer; draining.audioPipeline = pipeline
        draining.request = SFSpeechAudioBufferRecognitionRequest()
        pipeline.append(buffer)
        _ = startedWriting.wait(timeout: .now() + 1)
        pipeline.append(buffer); pipeline.append(buffer)
        var fullFileRead = false, drainFinished = false
        draining.transcribeFile = { url, _, done in
            fullFileRead = (try? AVAudioFile(forReading: url).length) == 3072
            done(.success(.init(text: "包括最后一段声音")))
        }
        draining.stop { _ in drainFinished = true }
        draining.receive(words: "最后的实时文字", final: true, failed: false, gen: draining.generation)
        checks["stop_does_not_finalize_before_queued_audio"] = !fullFileRead && !drainFinished
        allowWriting.signal()
        waitFor { drainFinished }
        checks["stop_drains_every_buffer_before_file_transcription"] = fullFileRead && drainFinished

        let damaged = BoardSpeech()
        damaged.directory = directory
        damaged.savedAudioSeconds = 10
        damaged.timedSegments = [.init(start: 11, end: 12, text: "包含写入失败缓冲的实时语音")]
        damaged.audioArchiveIncomplete = true
        let damagedPositionUnavailable = damaged.audioSeconds == nil
        damaged.archiveWarning = "原始录音部分写入失败"
        damaged.receive(words: "实时文字包括未写入文件的尾句", final: false, failed: false, gen: 0)
        var retriedDamagedFile = false, damagedFinished = false
        damaged.transcribeFile = { _, _, done in
            retriedDamagedFile = true; done(.success(.init(text: "更短的录音")))
        }
        damaged.stop { _ in damagedFinished = true }
        waitFor { damagedFinished }
        checks["partial_archive_cannot_overwrite_live_text_or_claim_complete"] = damagedFinished && !retriedDamagedFile
            && damaged.fullText == "实时文字包括未写入文件的尾句" && !damaged.finalTranscriptVerified
        var damagedEvidence = BoardEvidence()
        damagedEvidence.speech = [.init(start: 11, end: 12, text: "旧定位")]
        damagedEvidence.speechTimingSource = "original-audio-file"
        damaged.updateTiming(&damagedEvidence)
        checks["partial_archive_does_not_claim_precise_audio_positions"] = damagedPositionUnavailable && damaged.audioSeconds == nil
            && damaged.timedSegments.isEmpty && damagedEvidence.speech.isEmpty
            && damagedEvidence.speechTimingSource == "unavailable"
        let pass = completed && checks.values.allSatisfy { $0 }
        try? FileManager.default.removeItem(at: directory)
        emit(["event": "board_retention_check", "ok": pass, "checks": checks])
        exit(pass ? 0 : 1)
    }
}

// MARK: - preview: the capsule's states and the pen, as PNGs

enum BoardPreview {
    static func run(_ args: [String]) -> Never {
        let out = URL(fileURLWithPath: args.first ?? "board-preview")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let thumbs = (0..<3).map { i in sampleScreen(CGSize(width: 1440, height: 900), hue: 0.55 + CGFloat(i) * 0.08) }.map(BoardSession.thumbnail)
        let ok = [(BoardCapsule.Warning)]()
        func controls(_ tool: InkTool?, paused: Bool = false) -> [BoardCapsule.Control] {
            BoardSession.capsuleControls(tool: tool, paused: paused, pen: {}, use: { _ in }, undo: {}, pause: {}, save: {}, finish: {})
        }
        func capsule(_ f: (BoardCapsule) -> Void) -> BoardCapsule { let c = BoardCapsule(); f(c); return c }

        let shots: [(String, BoardCapsule)] = [
            ("1-开始-第一次", capsule { $0.setControls(controls(nil)); $0.update(page: 1, words: "", mic: .live, warnings: ok, hints: true) }),
            ("2-边说边画", capsule {
                $0.setTray(Array(thumbs.prefix(1)))
                $0.setControls(controls(.ellipse))
                $0.update(page: 2, words: "这个按钮太小了，改大一点，然后右边这块留白太多，往左收一点", mic: .live, warnings: ok, hints: false)
                $0.setPen(true)
                $0.setLevel(0.05)
            }),
            ("3-存了三页", capsule {
                $0.setTray(thumbs)
                $0.setControls(controls(nil, paused: true))
                $0.update(page: 4, words: "", mic: .live, warnings: ok, hints: false)
                $0.toast("第 3 页已存，切到下一页接着标")
            }),
            ("3b-快捷键提示", capsule {
                $0.setControls(controls(.box))
                $0.update(page: 1, words: "", mic: .live, warnings: ok, hints: false)
                $0.setPen(true)
                $0.tip("下次可以直接按住 \(BoardHoldKey.current(.box).label) 画矩形，松开就停", seconds: 99)
            }),
            ("4-缺权限", capsule {
                $0.update(page: 1, words: "", mic: .off, warnings: [
                    .init(text: "截图要「屏幕录制」权限，打开后重开这个 App", permission: .screen),
                    .init(text: "说话转文字要「语音识别」权限，现在只记你画的", permission: .speech),
                    .init(text: "最后自动粘贴要用「辅助功能」权限", permission: .accessibility)], hints: false)
            }),
            ("5-正在粘贴", capsule { $0.message(.init(symbol: nil, tint: BoardColor.secondary, text: "正在粘贴 3 页到 Codex…", spinner: true), seconds: 99) }),
            ("6-粘贴完成", capsule {
                $0.message(.init(symbol: "checkmark.circle.fill", tint: BoardColor.live, text: "已粘贴 3 页到 Codex，检查一下再发送",
                                 actions: [("打开文件夹", {})]), seconds: 99)
            }),
            ("7-已取消", capsule { $0.message(.init(symbol: "xmark.circle.fill", tint: BoardColor.secondary, text: "已取消，这次的内容没有粘贴"), seconds: 99) }),
        ]
        let backdrop = sampleScreen(CGSize(width: 1440, height: 900), hue: 0.58)
        for (name, c) in shots {
            let v = c.previewViews()
            render(v, over: backdrop, to: out.appendingPathComponent("\(name).png"))
        }

        // the pen on a page: strokes, the ring, the edge
        let size = NSSize(width: 1200, height: 750)
        let ink = BoardInkView(frame: NSRect(origin: .zero, size: size))
        ink.lineWidth = 4
        ink.tool = .free
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = ink
        ink.layoutSubtreeIfNeeded()
        ink.layout()
        ink.tool = .box
        ink.begin(at: CGPoint(x: 820, y: 210)); ink.move(to: CGPoint(x: 1010, y: 290)); ink.end()
        ink.tool = .free
        ink.begin(at: CGPoint(x: 420, y: 520))
        for i in 0...40 { let a = Double(i) / 40 * .pi * 2; ink.move(to: CGPoint(x: 300 + 120 * cos(a), y: 520 + 50 * sin(a))) }
        ink.end()
        ink.setPen(true)
        ink.moveHalo(screen: NSPoint(x: 1010, y: size.height - 290), in: NSRect(origin: .zero, size: size), show: true)
        CATransaction.flush()
        render(ink, over: sampleScreen(CGSize(width: 1200, height: 750), hue: 0.58), to: out.appendingPathComponent("8-画笔.png"))
        print(out.path)
        exit(0)
    }

    /// a window's content on its own background (the window's)
    static func renderWindow(_ v: NSView, background: NSColor, to url: URL) {
        let size = v.fittingSize
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        render(v, over: ctx.makeImage()!, to: url)
    }

    /// a stand-in app window: a sidebar, a header, a few rows and a button
    static func sampleScreen(_ s: CGSize, hue: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(s.width), height: Int(s.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.fill(CGRect(origin: .zero, size: s))
        ctx.setFillColor(NSColor(white: 0.90, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: s.width * 0.2, height: s.height))
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).cgColor)
        ctx.fill(CGRect(x: s.width * 0.2, y: s.height - 70, width: s.width * 0.8, height: 70))
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        for i in 0..<6 { ctx.fill(CGRect(x: s.width * 0.25, y: s.height - 150 - CGFloat(i) * 60, width: s.width * 0.55, height: 26)) }
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.75, alpha: 1).cgColor)
        ctx.fill(CGRect(x: s.width * 0.7, y: s.height * 0.6, width: 110, height: 34))
        return ctx.makeImage()!
    }

    static func render(_ v: NSView, over backdrop: CGImage, to url: URL) {
        let size = v.bounds.size
        let scale: CGFloat = 2
        let w = v.window ?? NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        if v.window == nil { w.contentView = v }
        // a window has to be on screen for AppKit to give its layers their contents: far off to the side, see-through
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        v.layer?.layoutIfNeeded()
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(backdrop, in: CGRect(origin: .zero, size: size))
        // Liquid Glass lives in its own layers that `CALayer.render(in:)` cannot draw: let AppKit draw the view instead
        if #available(macOS 26.0, *), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let img = rep.cgImage { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
            if let out = ctx.makeImage() { writePNG(out, to: url) }
            w.orderOut(nil)
            return
        }
        // draw the view's tree the way AppKit would, into a flipped context
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        if let l = v.layer {
            ctx.saveGState()
            if v.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            l.render(in: ctx)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let img = ctx.makeImage() { writePNG(img, to: url) }
        w.orderOut(nil)
    }
}

final class BoardTranscriptLabel: NSTextField {
    var onOpen: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The live words: newly said characters come in like Apple Intelligence's text (BoardRevealLayoutManager: a quick
    // small float up out of a soft glow); a second pass rewriting words already shown swaps them in quietly. Other text (the hint, a toast)
    // is drawn as a plain label.
    /// the whole transcript the shown tail comes from (empty: a plain label)
    private var full = ""
    /// when each UTF-16 unit of `full` starts coming in
    private var born: [Double] = []
    private var animEnd: CFTimeInterval = 0
    private var timer: Timer?

    /// Plain text from here on (a hint, a toast).
    func plain(_ text: String) {
        full = ""; born = []
        timer?.invalidate(); timer = nil
        stringValue = text
        needsDisplay = true
    }

    /// `shown` is the tail of `transcript` that fits (maybe after "…"); what is new in `transcript` comes in.
    func live(_ transcript: String, shown: String) {
        let old = full as NSString, new = transcript as NSString
        var common = 0
        let n = min(old.length, new.length)
        while common < n, old.character(at: common) == new.character(at: common) { common += 1 }
        if common < new.length { common = min(common, new.rangeOfComposedCharacterSequence(at: common).location) }
        if born.count > common { born.removeLast(born.count - common) }
        if born.count < common { born += Array(repeating: -1000, count: common - born.count) }
        let fresh = new.length - common
        if fresh > 0 {
            born += Array(repeating: -1000, count: fresh)
            // only what goes past the end of what was shown is new speech; a second pass rewriting words already
            // shown swaps them in place, quietly
            let start = max(common, old.length)
            if start < new.length, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                animate(from: start, count: new.length - start)
            }
        }
        let changed = full != transcript || stringValue != shown
        full = transcript
        if stringValue != shown { stringValue = shown }
        if changed { needsDisplay = true }
    }

    private func animate(from: Int, count: Int) {
        let now = CACurrentMediaTime()
        let gap = min(BoardWordsReveal.step, BoardWordsReveal.spread / Double(max(1, count - 1)))
        for i in 0..<count { born[from + i] = now + Double(i) * gap }
        animEnd = max(animEnd, now + Double(max(0, count - 1)) * gap + BoardWordsReveal.duration)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self else { return tm.invalidate() }
            self.needsDisplay = true
            if CACurrentMediaTime() >= self.animEnd { tm.invalidate(); self.timer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !full.isEmpty, let cell = cell, CACurrentMediaTime() < animEnd else { return super.draw(dirtyRect) }
        let shown = stringValue as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        let text = NSTextStorage(string: stringValue, attributes: [.font: font ?? .systemFont(ofSize: 14),
                                                                   .foregroundColor: textColor ?? .labelColor,
                                                                   .paragraphStyle: paragraph])
        // the shown tail's characters, where they are in the whole transcript
        let body = shown.hasPrefix("…") && !(full as NSString).hasPrefix("…") ? 1 : 0
        let offset = (full as NSString).length - (shown.length - body)
        let now = CACurrentMediaTime()
        shown.enumerateSubstrings(in: NSRange(location: body, length: shown.length - body), options: .byComposedCharacterSequences) { _, r, _, _ in
            let at = offset + r.location - body
            guard at >= 0, at < self.born.count, now - self.born[at] < BoardWordsReveal.duration else { return }
            text.addAttribute(.boardReveal, value: self.born[at], range: r)
        }
        let frame = cell.titleRect(forBounds: bounds)
        let manager = BoardRevealLayoutManager()
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2
        container.maximumNumberOfLines = maximumNumberOfLines
        manager.addTextContainer(container)
        text.addLayoutManager(manager)
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: frame.origin)
    }
}

extension BoardSession {
    func isReviewing(_ directory: URL) -> Bool { dir == directory && (review != nil || runner != nil || active || finalizing) }

    func openArchive(_ directory: URL) {
        // this record is already open: bring its window up
        if let review, dir?.standardizedFileURL == directory.standardizedFileURL { review.show(); return }
        // another record's review is open (and nothing is recording or pasting): save it, close it, open this one
        if let review, !active, !finalizing, runner == nil { guard review.closeSaving() else { review.show(); return } }
        guard !active, !finalizing, runner == nil, review == nil else { capsule.toast("请先保存并关闭当前检查窗口"); return }
        guard directory.deletingLastPathComponent().standardizedFileURL == BoardHistoryWindow.root.standardizedFileURL else { return }
        dir = directory
        timeline = BoardEvidence.load(directory).map { value in let model = BoardTimeline(); model.evidence = value; return model }
        func file(_ name: String) -> URL? {
            guard !name.isEmpty, (name as NSString).lastPathComponent == name else { return nil }
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let data = try? Data(contentsOf: directory.appendingPathComponent("页面.json"))
        let rows = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        pages = rows.compactMap { BoardPageFiles.decode($0, directory: directory) }
        if rows.isEmpty {
            pages = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { url in
                    url.pathExtension.lowercased() == "png"
                        && !["原图-", "滚动原图-", "长图原图-"].contains(where: { url.lastPathComponent.hasPrefix($0) })
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { Page(images: [$0], text: "", thumb: boardThumbnail($0)) }
        }
        archivedTranscript = (try? String(contentsOf: directory.appendingPathComponent("完整转写.txt"), encoding: .utf8)) ?? ""
        reviewedTranscript = BoardDeliveryTranscript.load(from: directory)
        if pages.isEmpty && deliveryTranscript.isEmpty { NSWorkspace.shared.open(directory) }
        else { openReview() }
    }
}

extension BoardSession {
    /// Real persistence and export paths, isolated from the user's records, mic and clipboard.
    static func runEvidenceCheck() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-evidence-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [String: Bool] = [:]
        let a = BoardPreview.sampleScreen(CGSize(width: 640, height: 400), hue: 0.35)
        let b = BoardPreview.sampleScreen(CGSize(width: 640, height: 400), hue: 0.75)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 400)
        let frameA = BoardScreenFeed.Frame(image: a, displayID: 1, bounds: bounds, scene: "app:home", appName: "测试程序", title: "主页")
        let frameB = BoardScreenFeed.Frame(image: b, displayID: 1, bounds: bounds, scene: "app:detail", appName: "测试程序", title: "详情")
        let delayedAudio = BoardTimeline()
        delayedAudio.observe(frameA, boundary: false, at: .init(elapsed: 0))
        let beforeAudio = delayedAudio.currentID
        delayedAudio.observe(frameA, boundary: false, at: .init(elapsed: 2, audio: 0.1))
        checks["late_audio_permission_keeps_page_and_starts_audio_range"] = delayedAudio.evidence.visits.count == 2
            && delayedAudio.currentID == beforeAudio && delayedAudio.evidence.visits[1].start.audio == 0.1
        let session = BoardSession()
        session.dir = directory; session.active = true; session.timeline = BoardTimeline()
        let timeline = session.timeline!
        timeline.observe(frameA, boundary: false, at: .init(elapsed: 0, audio: 0))
        let homeID = timeline.currentID!
        checks["automatic_empty_save_refused"] = session.save(a, bounds: bounds, marks: [], text: "背景仍会独立保存", included: false, scene: frameA.scene) == nil
        checks["empty_save_writes_no_png"] = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).allSatisfy { !$0.hasSuffix(".png") }
        let firstMark = BoardMarkEvidence(number: 1, start: .init(elapsed: 2, audio: 2), end: .init(elapsed: 3, audio: 3))
        let first = session.save(a, bounds: bounds, marks: [[[0.3, 0.4]]], text: "", included: true, scene: frameA.scene, evidence: [firstMark])
        checks["marked_page_saved"] = first == 0 && session.pages.count == 1
        session.autoPage(frameB)
        checks["unmarked_navigation_does_not_save"] = session.pages.count == 1
        session.keepPage(always: false) { kept in checks["finish_does_not_save_empty_frame"] = !kept && session.pages.count == 1 }
        timeline.observe(frameB, boundary: true, at: .init(elapsed: 5, audio: 5))
        timeline.observe(frameA, boundary: true, at: .init(elapsed: 8, audio: 8))
        checks["return_matches_same_page"] = timeline.currentID == homeID && timeline.evidence.visits.count == 3
        let secondMark = BoardMarkEvidence(number: 2, start: .init(elapsed: 9, audio: 9), end: .init(elapsed: 10, audio: 10))
        let revisit = session.save(a, bounds: bounds, marks: [[[0.6, 0.5]]], text: "", included: true, scene: frameA.scene, evidence: [secondMark])
        checks["revisit_merges_image_and_marks"] = revisit == 0 && session.pages.count == 1 && session.pages[0].markEvidence.map(\.number) == [1, 2]
        timeline.close(at: .init(elapsed: 12, audio: 12))
        checks["revisit_has_separate_intervals"] = timeline.evidence.visits.filter { $0.pageID == homeID }.count == 2
        let changed = BoardScreenFeed.Frame(image: b, displayID: 1, bounds: bounds, scene: frameA.scene, appName: frameA.appName, title: frameA.title)
        timeline.observe(changed, boundary: true, at: .init(elapsed: 14, audio: 14))
        checks["same_title_changed_pixels_are_separate"] = timeline.currentID != homeID
        let manual = session.save(b, bounds: bounds, marks: [], text: "", included: true, scene: changed.scene, manual: true)
        checks["manual_unmarked_snapshot_allowed"] = manual == 1 && session.pages[1].manuallySaved
        // 2026-11-15 dogfood: a page kept for what was said (unchecked), then drawn on, stayed unchecked
        session.pages[1].included = false
        let drawnLater = BoardMarkEvidence(number: 3, start: .init(elapsed: 15, audio: 15), end: .init(elapsed: 16, audio: 16))
        let spokenThenDrawn = session.save(b, bounds: bounds, marks: [[[0.2, 0.2]]], text: "", included: true, scene: changed.scene, evidence: [drawnLater])
        checks["spoken_page_drawn_on_gets_checked"] = spokenThenDrawn == 1 && session.pages[1].included && session.pages[1].marks.count == 1
        BoardFileWriter.flush()
        let encoded = BoardPageFiles.encode(session.pages[0])
        let restored = BoardPageFiles.decode(encoded, directory: directory)!
        checks["mark_times_and_ids_survive_reload"] = restored.markEvidence == session.pages[0].markEvidence && restored.contextIDs == [homeID]
        var missingOutput = encoded
        missingOutput["images"] = ["missing-marked.png"]
        let recovered = BoardPageFiles.decode(missingOutput, directory: directory)
        checks["missing_marked_image_keeps_original_and_editable_marks"] = recovered?.original == restored.original
            && recovered?.markEvidence == restored.markEvidence && recovered?.marks == restored.marks
        var evidence = timeline.evidence
        evidence.speech = [.init(start: 0, end: 2, text: "先说背景。"), .init(start: 2, end: 4, text: "这个按钮放大。"), .init(start: 8, end: 11, text: "那个按钮换颜色。")]
        try! evidence.save(directory)
        checks["visits_persist_without_images"] = BoardEvidence.load(directory)?.visits.count == 4
        let fullText = "先说背景。这是测试用途。这个按钮放大。那个按钮换颜色。最后还有补充。"
        let output = BoardEvidenceExport.text(pages: session.pages, transcript: fullText, evidence: evidence)
        checks["export_has_complete_transcript_once"] = output.components(separatedBy: fullText).count == 2
        checks["export_advisory_not_hard_assignment"] = output.contains("可能跨页") && output.contains("语音参考")
        checks["export_has_number_and_audio_range"] = output.contains("标记 2") && output.contains("00:09.0")
        checks["export_has_unmarked_visit_context"] = output.contains("详情") && output.contains("无截图")
        let textOnly = BoardEvidenceExport.text(pages: [], transcript: fullText, evidence: evidence)
        checks["delete_images_preserves_all_words_and_visits"] = textOnly.contains(fullText) && textOnly.contains("主页") && !textOnly.contains("标记 1：")
        do {
            let export = try BoardSession.exportFolder(pages: session.pages, transcript: fullText, evidence: evidence,
                                                       root: directory.appendingPathComponent("exports"))
            checks["paste_matches_copy_export"] = BoardSession.deliverySteps(export: export) == [.text(export.text)]
            checks["export_contains_saved_image_paths"] = export.images.allSatisfy { export.text.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
        } catch { checks["paste_matches_copy_export"] = false }
        let legacy = BoardPageFiles.decode(["images": session.pages[0].images.map(\.lastPathComponent), "marks": [[[0.3, 0.4]]]], directory: directory)!
        checks["legacy_times_not_fabricated"] = legacy.markEvidence.isEmpty && legacy.contextIDs.isEmpty
        if let image = loadCGImage(restored.images[0]) { _ = writePNG(image, to: URL(fileURLWithPath: "/tmp/point-taken-evidence-number-preview.png")) }
        // Undo the last mark through the live session path: no empty image remains.
        let page = session.pages[0]
        let scroll = BoardLiveScroll(page: page, frame: frameA)
        session.liveScroll = scroll; session.livePage = 0
        session.undo(); session.undo()
        checks["undo_last_mark_removes_automatic_page"] = session.pages.count == 1 && session.pages[0].manuallySaved
        BoardFileWriter.flush()
        checks["undo_does_not_resurrect_queued_images"] = page.allFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        // A completed marked page must not suppress a subsequent spoken-only viewport, including when a
        // background scroll alignment has not completed yet (the live offset is still zero).
        session.liveScroll = BoardLiveScroll(page: session.pages[0], frame: changed)
        session.livePage = 0
        session.wordsAtScreen = 0; session.pagesAtScreen = session.pages.count
        let countBeforeSpeech = session.pages.count
        session.keepSpoken(frameA, wordCount: 8)
        checks["spoken_changed_viewport_survives_live_mark_chain"] = session.pages.count == countBeforeSpeech + 1
            && !session.pages.last!.included && session.pages.last!.marks.isEmpty
        checks["spoken_viewport_has_its_own_context"] = session.pages.last!.contextIDs != session.pages[0].contextIDs
        BoardFileWriter.flush()
        // A page with a carousel of covers: the cover turning over is the page moving by itself, not a new page.
        do {
            let carouselDir = directory.appendingPathComponent("carousel")
            try? FileManager.default.createDirectory(at: carouselDir, withIntermediateDirectories: true)
            let base = BoardPreview.sampleScreen(CGSize(width: 640, height: 400), hue: 0.58)
            func cover(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> BoardScreenFeed.Frame {
                let ctx = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(base, in: bounds)
                ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                ctx.fill(CGRect(x: 400, y: 200, width: 160, height: 120))      // top-left y 80–200
                return BoardScreenFeed.Frame(image: ctx.makeImage()!, displayID: 1, bounds: bounds, scene: "browser:feed",
                                             appName: "浏览器", title: "首页")
            }
            let red = cover(0.9, 0.1, 0.1), blue = cover(0.1, 0.2, 0.9), green = cover(0.1, 0.8, 0.2)
            func mark(_ n: Int) -> BoardMarkEvidence { BoardMarkEvidence(number: n, start: .init(elapsed: Double(n)), end: .init(elapsed: Double(n) + 0.5)) }
            let elsewhere: [[Double]] = [[0.1, 0.7], [0.3, 0.7], [0.3, 0.85], [0.1, 0.85], [0.1, 0.7]]
            let onCover: [[Double]] = [[0.6, 0.18], [0.9, 0.18], [0.9, 0.52], [0.6, 0.52], [0.6, 0.18]]
            func fresh() -> BoardSession {
                let s = BoardSession(); s.dir = carouselDir; s.active = true; s.timeline = BoardTimeline(); return s
            }
            // without knowing what moves, a turned cover splits the page (the reported problem)
            let before = fresh()
            before.place(elsewhere, evidence: mark(1), frame: red, panel: nil)
            before.place(elsewhere, evidence: mark(2), frame: blue, panel: nil)
            checks["carousel_without_mask_used_to_split"] = before.pages.count == 2
            // with the carousel learned (it turned while the user did nothing)
            let s = fresh()
            s.screenFeed.motion.learn(from: red.fingerprint, to: blue.fingerprint)
            s.place(elsewhere, evidence: mark(1), frame: red, panel: nil)
            s.place(elsewhere, evidence: mark(2), frame: blue, panel: nil)
            checks["carousel_turn_keeps_same_page"] = s.pages.count == 1 && s.pages[0].markEvidence.map(\.number) == [1, 2]
            checks["carousel_turn_is_not_navigation"] = s.transition(red, blue, scrolling: false) == false
            // a mark on the cover: the page takes the picture it was drawn on
            s.place(onCover, evidence: mark(3), frame: green, panel: nil)
            BoardFileWriter.flush()
            let shown = s.pages[0].original.flatMap(loadCGImage).map(BoardFrameFingerprint.init)
            checks["mark_on_turned_cover_refreshes_picture"] = s.pages.count == 1 && s.pages[0].marks.count == 3
                && shown.map { $0.distance(to: green.fingerprint) < 0.001 } == true
            // another mark on the cover after it turned again: the first was about the cover shown then
            s.place(onCover, evidence: mark(4), frame: red, panel: nil)
            checks["second_cover_mark_starts_new_page"] = s.pages.count == 2 && s.pages[1].markEvidence.map(\.number) == [4]
            // a real change of page is still one
            let flipped = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            flipped.translateBy(x: 640, y: 400); flipped.scaleBy(x: -1, y: -1)     // another layout: everything moved
            flipped.draw(base, in: bounds)
            let other = BoardScreenFeed.Frame(image: flipped.makeImage()!, displayID: 1, bounds: bounds, scene: red.scene,
                                              appName: red.appName, title: red.title)
            checks["carousel_mask_still_sees_navigation"] = s.transition(red, other, scrolling: false) == true
                && s.screenFeed.motion.isEmpty
            s.place(elsewhere, evidence: mark(5), frame: other, panel: nil)
            checks["changed_page_still_new_page"] = s.pages.count == 3
            BoardFileWriter.flush()
        }
        // Exercise the actual coalescing writer under backlog, not just the enqueue API.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        BoardFileWriter.enqueue(directory.appendingPathComponent("writer-gate")) {
            entered.signal(); release.wait(); return true
        }
        _ = entered.wait(timeout: .now() + 2)
        let coalescedURL = directory.appendingPathComponent("coalesced.png")
        var writes = 0
        for i in 0..<12 {
            BoardFileWriter.enqueue(coalescedURL, image: true) {
                writes += 1
                return writePNG(i == 11 ? b : a, to: coalescedURL)
            }
        }
        release.signal(); BoardFileWriter.flush()
        checks["backlogged_images_encode_only_latest_revision"] = writes == 1
            && loadCGImage(coalescedURL).map { BoardFrameFingerprint($0).distance(to: frameB.fingerprint) < 0.002 } == true
        let recoveryDirectory = directory.appendingPathComponent("recoverable")
        let recoveryURL = recoveryDirectory.appendingPathComponent("original.png")
        BoardFileWriter.png(a, to: recoveryURL)
        BoardFileWriter.flush()
        checks["failed_write_keeps_source_pixels_for_retry"] = BoardFileWriter.recoveryImage(recoveryURL) === a
            && BoardFileWriter.warning(in: recoveryDirectory) != nil
        try! FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        var retried = false
        BoardFileWriter.whenFinished { retried = true }
        let retryDeadline = Date().addingTimeInterval(3)
        while !retried && Date() < retryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        checks["transient_write_failure_recovers_without_losing_page"] = retried && loadCGImage(recoveryURL) != nil
            && BoardFileWriter.recoveryImage(recoveryURL) == nil && BoardFileWriter.warning(in: recoveryDirectory) == nil
        let scrollDirectory = directory.appendingPathComponent("scroll")
        try! FileManager.default.createDirectory(at: scrollDirectory, withIntermediateDirectories: true)
        let documentContext = CGContext(data: nil, width: 320, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<600 { for x in stride(from: 0, to: 320, by: 8) {
            let v = CGFloat((y * 73 + x * 37 + y * x * 13) % 251) / 251
            documentContext.setFillColor(CGColor(gray: v, alpha: 1))
            documentContext.fill(CGRect(x: x, y: y, width: 8, height: 1))
        } }
        let document = documentContext.makeImage()!
        let scrollBounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        let top = BoardScreenFeed.Frame(image: document.cropping(to: scrollBounds)!, displayID: 1, bounds: scrollBounds, scene: "scroll", title: "same title")
        let bottom = BoardScreenFeed.Frame(image: document.cropping(to: CGRect(x: 0, y: 200, width: 320, height: 400))!, displayID: 1, bounds: scrollBounds, scene: "scroll", title: "same title")
        let scrolling = BoardSession()
        scrolling.dir = scrollDirectory; scrolling.active = true; scrolling.timeline = BoardTimeline()
        scrolling.timeline!.observe(top, boundary: false, at: .init(elapsed: 0, audio: 0))
        _ = scrolling.save(top.image, bounds: scrollBounds, marks: [[[0.5, 0.75]]], text: "", included: true, scene: top.scene, evidence: [firstMark])
        scrolling.livePage = 0; scrolling.liveScroll = BoardLiveScroll(page: scrolling.pages[0], frame: top)
        let topID = scrolling.timeline!.currentID
        _ = scrolling.transition(top, bottom, scrolling: true)
        let alignmentDeadline = Date().addingTimeInterval(5)
        while scrolling.aligning && Date() < alignmentDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        checks["scroll_alignment_opens_distinct_viewport_context"] = !scrolling.aligning && scrolling.liveScroll?.offset == 200
            && scrolling.timeline!.currentID != topID
        let carried = scrolling.liveScroll?.viewportMarks ?? []
        _ = scrolling.save(bottom.image, bounds: scrollBounds, marks: carried + [[[0.4, 0.8]]], text: "", included: true,
                           scene: bottom.scene, evidence: [firstMark, secondMark])
        var scrollEvidence = scrolling.timeline!.evidence
        if scrollEvidence.visits.count == 2 {
            scrollEvidence.visits[0].start.audio = 0; scrollEvidence.visits[0].end.audio = 5
            scrollEvidence.visits[1].start.audio = 5; scrollEvidence.visits[1].end.audio = 12
        }
        scrollEvidence.speech = [.init(start: 1, end: 2, text: "first viewport"), .init(start: 8, end: 9, text: "second viewport")]
        let blocks = BoardSpeechBlock.build(pages: scrolling.pages, evidence: scrollEvidence)
        checks["scrolled_page_speech_is_not_assigned_to_first_page"] = blocks.first { $0.pageIndex == 0 }?.segments.map(\.text) == ["first viewport"]
            && blocks.first { $0.pageIndex == 1 }?.segments.map(\.text) == ["second viewport"]
        checks["visible_carried_mark_keeps_its_identity"] = scrolling.pages.count == 2
            && scrolling.pages[0].markEvidence.first?.number == scrolling.pages[1].markEvidence.first?.number
        scrolling.active = false
        BoardFileWriter.flush()
        session.active = false
        try? FileManager.default.removeItem(at: directory)
        let ok = checks.values.allSatisfy { $0 }
        emit(["event": "board_evidence_check", "ok": ok, "checks": checks])
        exit(ok ? 0 : 1)
    }
}
