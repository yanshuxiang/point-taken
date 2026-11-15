import AppKit
import PointTakenCore
import Carbon.HIToolbox

/// A hold-to-draw key, as the user recorded it (Settings → Shortcuts → While recording): modifiers alone (⌥, ⌃⌥ …:
/// only watched, never taken from the app in front), or modifiers with one key, or one key alone (⌥D, F5, ` …: a
/// hotkey while recording, so that key goes to Lianbiao, not to the app in front). record.board.hold_keys.<tool>.
struct BoardHoldKey: Equatable {
    var mods: NSEvent.ModifierFlags
    /// a key's virtual code; nil: the modifiers alone
    var code: Int?
    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    /// the tools a key can hold, in the order the settings list them
    static let tools: [InkTool] = [.free, .box]
    static let defaults: [InkTool: BoardHoldKey] = [.free: BoardHoldKey(mods: [.option]), .box: BoardHoldKey(mods: [.option, .shift])]

    init(mods: NSEvent.ModifierFlags, code: Int? = nil) {
        self.mods = mods.intersection(Self.relevant)
        self.code = code
    }
    /// the keycaps, Apple's order: ⌃ ⌥ ⇧ ⌘, then the key
    var keys: [String] {
        var k: [String] = []
        if mods.contains(.control) { k.append("⌃") }
        if mods.contains(.option) { k.append("⌥") }
        if mods.contains(.shift) { k.append("⇧") }
        if mods.contains(.command) { k.append("⌘") }
        if let code { k.append(KeyCombo(mods: 0, code: code)?.label ?? "键\(code)") }
        return k
    }
    var label: String { keys.joined() }
    var carbonMods: Int { KeyCombo.carbonMods(mods) }
    /// a key with no modifier: while recording it is taken for drawing and can't be typed
    var takesTyping: Bool { code != nil && mods.subtracting(.shift).isEmpty }

    private var stored: [String: Any] { ["mods": Int(mods.rawValue), "code": code ?? -1] }
    private init?(_ d: [String: Any]) {
        guard let m = d["mods"] as? Int else { return nil }
        let c = d["code"] as? Int ?? -1
        self.init(mods: NSEvent.ModifierFlags(rawValue: UInt(m)), code: c < 0 ? nil : c)
        if self.code == nil && self.mods.isEmpty { return nil }
    }

    static func current(_ tool: InkTool) -> BoardHoldKey {
        let saved = ((recordConfig()["board"] as? [String: Any])?["hold_keys"] as? [String: Any])?[tool.rawValue] as? [String: Any]
        return saved.flatMap(BoardHoldKey.init) ?? defaults[tool] ?? BoardHoldKey(mods: [.option])
    }
    /// nil: back to the default
    static func set(_ tool: InkTool, _ key: BoardHoldKey?) {
        var board = recordConfig()["board"] as? [String: Any] ?? [:]
        var keys = board["hold_keys"] as? [String: Any] ?? [:]
        keys[tool.rawValue] = key?.stored
        board["hold_keys"] = keys.isEmpty ? nil : keys
        setRecordConfig("board", board)
    }
    static func restoreDefaults() { tools.forEach { set($0, nil) } }
}

/// Hold-to-draw during an annotation session: holding the freehand key (⌥ by default) turns on freehand, the rectangle
/// key (⌥⇧) the rectangle, for as many strokes as are drawn while it is held; letting go returns to whatever was on
/// before. A quick press and release (a tap, nothing drawn) arms the tool for one stroke instead. The keys are the user's (BoardHoldKey).
/// Modifiers alone are only watched (never consumed): every key still goes to the app in front, and a short delay,
/// cancelled by any key press, keeps ⌥-typing (⌥E, ⌥←…) from switching tools. A key with a key in it is a hotkey for
/// the session: pressed holds the tool at once, let go releases it.
final class BoardHoldKeys {
    /// Turns the tool on; returns the tool that was on before (to restore), or nil when it can't hold now.
    typealias Hold = (InkTool) -> InkTool??
    private var hold: Hold?
    private var onRelease: ((InkTool?) -> Void)?
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    /// While held: the tool held, and the tool to go back to.
    /// `combo`: held by a hotkey (its own release ends it; modifier changes don't)
    private var held: (tool: InkTool, before: InkTool?, combo: Bool)?
    /// when the key held now went down, and whether anything was drawn while it was held
    private var pressedAt: TimeInterval = 0
    private var drewWhileHeld = false
    /// shorter than this, with nothing drawn, a press is a tap
    static let tapTime: TimeInterval = 0.35
    /// A tap armed this tool for one stroke (the session turns it off after that stroke).
    var onTap: ((InkTool) -> Void)?
    /// A key is held: every stroke keeps the tool on.
    var holding: Bool { held != nil }
    /// A stroke was finished (while held, that makes the press a hold, not a tap).
    func strokeDrawn() { if held != nil { drewWhileHeld = true } }
    private var waitingForMouseUp: Timer?
    static let delay: TimeInterval = 0.18
    /// the keys for this session (read once at start)
    private var keys: [InkTool: BoardHoldKey] = BoardHoldKey.defaults
    /// raw hotkey ids for the keys with a key in them (HotkeyCenter.registerRaw, < 100)
    private static let rawIDs: [InkTool: UInt32] = [.free: 40, .box: 41]

    /// The modifier-only key held now, if any.
    func tool(for flags: NSEvent.ModifierFlags) -> InkTool? {
        let held = flags.intersection(BoardHoldKey.relevant)
        guard !held.isEmpty else { return nil }
        return BoardHoldKey.tools.first { keys[$0]?.code == nil && keys[$0]?.mods == held }
    }

    func start(hold: @escaping Hold, release: @escaping (InkTool?) -> Void) {
        stop()
        self.hold = hold
        self.onRelease = release
        keys = Dictionary(uniqueKeysWithValues: BoardHoldKey.tools.map { ($0, BoardHoldKey.current($0)) })
        // keys with a key in them: hotkeys while the session lasts (both edges: press holds, release lets go)
        for (tool, key) in keys {
            guard let code = key.code, let id = Self.rawIDs[tool] else { continue }
            HotkeyCenter.shared.rawHandlers[id] = { [weak self] down in self?.combo(tool, down: down) }
            HotkeyCenter.shared.registerRaw(id, code: code, mods: key.carbonMods)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.changed(e.modifierFlags) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.pending?.cancel(); self?.tapCandidate = nil   // ⌥ with a key is typing, not a tap
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.changed(e.modifierFlags); return e }) {
            monitors.append(m)
        }
    }

    func stop() {
        for id in Self.rawIDs.values {
            HotkeyCenter.shared.unregisterRaw(id)
            HotkeyCenter.shared.rawHandlers[id] = nil
        }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pending?.cancel(); pending = nil
        waitingForMouseUp?.invalidate(); waitingForMouseUp = nil
        held = nil
        tapCandidate = nil
        hold = nil
        onRelease = nil
    }

    /// A button chose a tool: whatever a held key turned on is no longer the key's to undo.
    func release() {
        pending?.cancel(); pending = nil
        held = nil
    }

    private func changed(_ flags: NSEvent.ModifierFlags) {
        pending?.cancel(); pending = nil
        let want = tool(for: flags)
        if let current = held {
            if current.combo { return }         // a hotkey's hold ends with its own key, not with its modifiers
            if let want {
                // ⌥ → ⌥⇧ while held: switch tools, keep what to go back to
                if want != current.tool, hold?(want) != nil { held = (want, current.before, false) }
            } else {
                held = nil
                letGo(current)
            }
            return
        }
        guard let want else {
            // let go before the hold began: a tap
            if let tapped = tapCandidate, ProcessInfo.processInfo.systemUptime - pressedAt < Self.tapTime { onTap?(tapped) }
            tapCandidate = nil
            return
        }
        if tapCandidate == nil { tapCandidate = want; pressedAt = ProcessInfo.processInfo.systemUptime; drewWhileHeld = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.held == nil, self.tool(for: NSEvent.modifierFlags) == want,
                  let before = self.hold?(want) else { return }
            self.held = (want, before, false)
            self.tapCandidate = nil
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// A hotkey hold: pressed holds the tool at once (its repeats change nothing), let go goes back.
    private func combo(_ tool: InkTool, down: Bool) {
        pending?.cancel(); pending = nil
        if down {
            if let current = held {
                if current.tool != tool, hold?(tool) != nil { held = (tool, current.before, true) }
                return
            }
            if let before = hold?(tool) {
                held = (tool, before, true)
                pressedAt = ProcessInfo.processInfo.systemUptime; drewWhileHeld = false
            }
        } else if let current = held, current.tool == tool {
            held = nil
            letGo(current)
        }
    }

    /// The key came up: a quick press with nothing drawn leaves the tool on for one stroke (a tap); otherwise the
    /// tool held goes back to what was on before.
    private func letGo(_ current: (tool: InkTool, before: InkTool?, combo: Bool)) {
        if !drewWhileHeld, ProcessInfo.processInfo.systemUptime - pressedAt < Self.tapTime, NSEvent.pressedMouseButtons & 1 == 0 {
            onTap?(current.tool)
            return
        }
        restore(current.before)
    }
    /// a modifier press that has not become a hold yet (a tap if it comes up soon)
    private var tapCandidate: InkTool?

    /// Let go mid-stroke: finish the stroke first, then go back.
    private func restore(_ before: InkTool?) {
        waitingForMouseUp?.invalidate(); waitingForMouseUp = nil
        guard NSEvent.pressedMouseButtons & 1 != 0 else { onRelease?(before); return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            self?.waitingForMouseUp = nil
            if self?.held == nil { self?.onRelease?(before) }
        }
        RunLoop.main.add(timer, forMode: .common)
        waitingForMouseUp = timer
    }
}
