import AppKit
import PointTakenCore
import Carbon.HIToolbox

// MARK: - App

/// Point Taken's app delegate: a menu-bar app whose one job is annotating (BoardSession). Launch, the global hotkeys,
/// the menu-bar menu, watching the settings file, quitting.
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    /// the menu's row while speech models download (ModelDownloads keeps its title current)
    var downloadItem: NSMenuItem?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        CloudSpeech.install()
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
            s.resume()
            signalSources.append(s)
        }
        if let l = opts.lang { Loc.setting = l }
        // the bundled scripts are copied where they run from, before anything runs one
        switch BundledSkill.syncAtLaunch() {
        case .success(let copied)?: if copied { emit(["event": "skill_synced", "to": BundledSkill.installed.path]) }
        case .failure(let e)?: NSLog("point-taken: copying the bundled scripts: \(e)"); emit(["event": "skill_synced", "error": "\(e)"])
        case nil: break
        }
        AppEnvironment.installModules()
        installHotkeyHandler()
        hotkeyHandler = { [weak self] k in self?.hotkey(k) }
        Hotkeys.shared.resident = true
        Hotkeys.shared.disabled = Set(HotkeyCenter.Action.allCases.filter { $0 != .board })
        Hotkeys.shared.apply()
        startBoardResident()
    }

    func hotkey(_ k: HK) {
        switch k {
        case .menu: popMenu()
        case .board: BoardSession.shared.hotkey()
        case .boardFinish, .boardCancel, .boardUndo, .boardDropPage: BoardSession.shared.handle(k)
        default: break
        }
    }

    /// Another copy of the app (a dev build next to a release) quitting: its hotkeys come over to this one. Again 3 s
    /// after launch, for one that started at the same moment and hadn't published yet.
    func watchOtherInstances() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                          queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  FileManager.default.fileExists(atPath: HotkeyCenter.registryDir.appendingPathComponent("\(app.processIdentifier).json").path)
                    || app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { App.otherInstancesChanged("quit \(app.processIdentifier)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { App.otherInstancesChanged("launch") }
        // a background app's end isn't always announced: while another instance holds one of our keys, look every few
        // seconds whether it is still there
        let t = Timer(timeInterval: 3, repeats: true) { _ in
            let holders = Set(Hotkeys.shared.states.values.compactMap { s -> pid_t? in if case .taken(let p) = s { return p }; return nil })
            guard !holders.isEmpty else { return }
            let alive = Set(Hotkeys.shared.otherInstances().map(\.pid))
            if holders.contains(where: { !alive.contains($0) }) { App.otherInstancesChanged("gone") }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
    }

    /// Shortcuts changed outside Settings (config.json by hand) work without a relaunch: looked at when the app comes
    /// to the front and every 2 s (Config caches by the file's signature: a look is a stat()).
    func watchConfigEdits() {
        func look(_ via: String) {
            guard Config.shared.checkReadable() else { return }
            if Hotkeys.shared.reloadIfChanged() { emit(["event": "hotkeys_reloaded", "via": via, "taken": Hotkeys.shared.conflicts.map(\.rawValue)]) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in look("activate") }
        let t = Timer(timeInterval: 2, repeats: true) { _ in look("timer") }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
    }

    static func otherInstancesChanged(_ why: String) {
        let before = Hotkeys.shared.states
        Hotkeys.shared.apply()
        if before != Hotkeys.shared.states { emit(["event": "hotkeys_reapplied", "why": why, "taken": Hotkeys.shared.conflicts.map(\.rawValue)]) }
    }

    /// <home>/app.json: which instance is running (its pid and path).
    func writeAppInfo() {
        let info: [String: Any] = ["pid": Int(getpid()), "path": Bundle.main.bundlePath,
                                   "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: pointTakenHome, withIntermediateDirectories: true)
            try? d.write(to: pointTakenHome.appendingPathComponent("app.json"))
        }
    }

    /// Quitting never loses an annotation on its way: the session finishes saving first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        BoardSession.shared.prepareForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    private var quitting = false

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ModelDownloads.shared.atQuit() }   // the download ends now; the next launch carries on
        Hotkeys.shared.unpublish()
        let f = pointTakenHome.appendingPathComponent("app.json")
        if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           o["pid"] as? Int == Int(getpid()) { try? FileManager.default.removeItem(at: f) }
    }

    /// The menu-bar icon can be hidden behind the notch on a crowded menu bar: the same menu at the pointer.
    func popMenu() {
        let m = NSMenu()
        menuNeedsUpdate(m)
        activateApp()
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = AppEnvironment.openURL?(url) }
    }

    /// Opening the app again (Finder, Dock, Spotlight, a second launch) shows the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popMenu()
        return false
    }

    /// Settings → General → "Show in menu bar" (app.menu_bar_icon, on by default). Takes effect at once.
    static var showsMenuBarIcon: Bool { Config.shared["app.menu_bar_icon"] as? Bool ?? true }
    func setMenuBarIcon(_ on: Bool) {
        Config.shared.set("app.menu_bar_icon", on ? nil : false)
        statusItem?.isVisible = on
        emit(["event": "menu_bar_icon", "show": on])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        boardMenu(menu)
    }

    /// A short message: the notices (Settings shows them); nothing pops up.
    func toast(_ text: String, seconds: Double = 4.5) { BoardNotices.shared.post(text) }
    func hudToast(_ text: String, seconds: Double = 4.5) { BoardNotices.shared.post(text) }

    /// A native alert. `also`: a second button (the first is OK) and what it does. `primary`: that button is the way
    /// out instead (the default, ↩), with `cancel` as the plain second (Esc). `critical`: something was lost.
    func alert(_ title: String, _ text: String, also: (String, () -> Void)? = nil, primary: Bool = false, cancel: String? = nil,
               critical: Bool = false) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = critical ? .critical : .warning
        var titles: [String] = []
        if let b = also, primary {
            titles = [b.0, cancel ?? T("action.cancel")]
        } else {
            titles = [T("action.ok")] + (also.map { [$0.0] } ?? [])
        }
        for t in titles { a.addButton(withTitle: t) }
        if titles.count > 1 { a.buttons[1].keyEquivalent = "\u{1b}" }      // the second is Esc
        emit(["event": "alert", "title": title, "text": text, "buttons": titles])
        activateApp()
        a.layout()
        a.window.makeKeyAndOrderFront(nil)
        let r = a.runModal()
        if primary { if r == .alertFirstButtonReturn { also?.1() } }
        else if r == .alertSecondButtonReturn { also?.1() }
    }
}
