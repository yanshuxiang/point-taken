import AppKit
import AVFoundation
import PointTakenCore
import Speech

enum BoardHome {
    /// Always on: this app is Point Taken only. (The switch and every check of it go with the upstream cleanup.)
    static let enabled = true

    static func show() {
        MainActor.assumeIsolated {
            if BoardSession.shared.active { BoardSession.shared.refresh() }
            else { BoardSession.shared.showIdle() }
        }
    }

    static func prepareForDisplay() {
        installMainMenu()
        NSApp.setActivationPolicy(.regular)
    }

    /// Status-item menus do not provide the frontmost window's standard Command shortcuts.
    static func installMainMenu() {
        func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            entry.submenu = submenu
            main.addItem(entry)
        }
        menu(PointTaken.nameZh, [
            item("关于" + PointTaken.nameZh, #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp), .separator(),
            item("设置…", #selector(App.mBoardSettings), ",", target: NSApp.delegate as? App), .separator(),
            item("隐藏" + PointTaken.nameZh, #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("隐藏其他应用", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp), .separator(),
            item("退出" + PointTaken.nameZh, #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        menu("编辑", [item("撤销", Selector(("undo:")), "z"),
                      item("重做", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                      item("剪切", #selector(NSText.cut(_:)), "x"), item("复制", #selector(NSText.copy(_:)), "c"),
                      item("粘贴", #selector(NSText.paste(_:)), "v"), item("全选", #selector(NSText.selectAll(_:)), "a")])
        // the review window's picture (the window's delegate answers these; elsewhere they are greyed out)
        menu("显示", [item("放大", Selector(("boardZoomIn:")), "+"), item("缩小", Selector(("boardZoomOut:")), "-"),
                      item("适合宽度", Selector(("boardZoomFit:")), "0")])
        menu("窗口", [item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"),
                      item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    /// Point Taken's own Settings (speech models, cloud API keys…): kept in this build.
    static func openSettings() {
        guard !BoardSession.shared.active else { return }
        prepareForDisplay()
        activateApp()
        AppEnvironment.settings?.show(pane: nil)
    }
}

// MARK: - the menu-bar menu of the 连标 build

extension App {
    func boardMenu(_ menu: NSMenu) {
        let active = BoardSession.shared.active
        let start = NSMenuItem(title: active ? "正在标注 · 请使用顶部灵动岛" : "开始标注", action: active ? nil : #selector(mBoard), keyEquivalent: "")
        start.target = self
        if !active { start.showHotkey(.board) }
        menu.addItem(start)
        menu.addItem(.separator())
        menu.addItem(boardModelItem(active: active))
        menu.addItem(.separator())
        let history = NSMenuItem(title: "历史记录…", action: active ? nil : #selector(mBoardHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let settings = NSMenuItem(title: "设置…", action: #selector(mBoardSettings), keyEquivalent: ",")
        settings.target = active ? nil : self
        if active { settings.action = nil }
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// One line for the recognition model (live captions and the final transcript share it). Idle: a submenu to switch
    /// it; while recording the model is fixed for this session, so the line is display-only.
    private func boardModelItem(active: Bool) -> NSMenuItem {
        let current = BoardSession.shared.currentTranscriptionModel ?? BoardTranscription.selected
        let (models, localOnly, loading) = MainActor.assumeIsolated {
            (SpeechModel.shared.models, SpeechModel.shared.localOnly, SpeechModel.shared.loading)
        }
        func isLocal(_ id: String) -> Bool { id == BoardTranscription.apple || models.first { $0.id == id }?.local == true }
        func title(_ id: String) -> String {
            id == BoardTranscription.apple || id == "volcengine-seedasr" ? BoardModelStatus.name(id)
                : (models.first { $0.id == id }?.title ?? BoardModelStatus.name(id))
        }
        let item = NSMenuItem(title: (isLocal(current) ? "识别模型：" : "识别 API：") + title(current), action: nil, keyEquivalent: "")
        guard !active else {
            item.isEnabled = false
            item.toolTip = "录音开始时已固定本次模型，结束后可切换。"
            return item
        }
        var choices = [BoardTranscription.apple] + models
            .filter { $0.role == "asr" && $0.installed && ($0.runsHere ?? true) && ($0.local || !localOnly) }
            .map(\.id)
        if !choices.contains(current) { choices.append(current) }
        let sub = NSMenu()
        for id in choices {
            let choice = NSMenuItem(title: title(id) + (isLocal(id) ? " · 本地" : " · API"),
                                    action: #selector(mBoardSelectModel(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = id
            choice.state = id == current ? .on : .off
            sub.addItem(choice)
        }
        sub.addItem(.separator())
        let more = NSMenuItem(title: "模型与 API 设置…", action: #selector(mBoardModelSettings), keyEquivalent: "")
        more.target = self
        sub.addItem(more)
        item.submenu = sub
        item.toolTip = "实时字幕和结束后的完整转写都用这个模型；切换从下一次录音生效。"
        // The list comes from Settings' model read; fetch it once so the next open lists the API models too.
        if models.isEmpty && !loading { Task { @MainActor in await SpeechModel.shared.load() } }
        return item
    }

    @objc func mBoardSelectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, !BoardSession.shared.active else { return }
        BoardTranscription.select(id)
    }
    @objc func mBoardModelSettings() {
        guard !BoardSession.shared.active else { return }
        BoardHome.prepareForDisplay()
        activateApp()
        AppEnvironment.settings?.show(pane: "speech/board.transcription")
    }

    @objc func mBoardHistory() { BoardHistoryWindow.shared.show() }
    @objc func mBoardSettings() { BoardHome.openSettings() }
    @objc func mBoardFinish() { BoardSession.shared.handle(.boardFinish) }
    @objc func mBoardHome() { BoardHome.show() }
    @objc func mBoardFolder() {
        let root = PointTaken.records
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}

// MARK: - preview

private final class BoardStartupCheckDelegate: NSObject, NSApplicationDelegate {
    var quitRequested = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitRequested = true
        return .terminateCancel
    }
}

enum BoardStartupCheck {
    /// Exercises the real start-button transition and capsule without recording, permissions prompts, or user files.
    /// Run as a separate diagnostic process: point-taken --board-startup-check.
    nonisolated static func runStartupCheck() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            BoardHome.prepareForDisplay()
            let delegate = BoardStartupCheckDelegate()
            app.delegate = delegate
            let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = PointTaken.nameZh + "启动检查"
            w.isReleasedWhenClosed = false
            let capsule = BoardCapsule()
            app.finishLaunching()
            w.makeKeyAndOrderFront(nil)
            activateApp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                w.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
                NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    BoardSession.yieldKeyboard(true)
                    capsule.beginSession()
                    var controlClicked = false
                    capsule.setControls([("正常操作", { controlClicked = true }), ("自由画", {})], selected: 0)
                    capsule.update(page: 1, words: "", mic: .starting, warnings: [], hints: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        var checks: [String: Bool] = [:]
                        func check(_ name: String) {
                            let panels = app.windows.filter { $0 is NSPanel && $0.isVisible }
                            checks[name] = panels.contains { panel in
                                guard let content = panel.contentView, let column = content.subviews.first else { return false }
                                content.layoutSubtreeIfNeeded()
                                let rect = column.convert(column.bounds, to: nil)
                                return panel.alphaValue > 0.9 && rect.width > 0 && rect.height > 0
                                    && panel.contentLayoutRect.contains(rect)
                            }
                        }
                        check("initial")
                        checks["keyboard_released"] = Hotkeys.shared.passesKeysToOtherApps && Hotkeys.shared.states.isEmpty
                        checks["capsule_cannot_take_focus"] = app.windows.filter { $0 is NSPanel && $0.isVisible }
                            .allSatisfy { !$0.canBecomeKey && !$0.canBecomeMain }
                        checks["recording_does_not_activate_app"] = !app.isActive
                        if let screen = NSScreen.main {
                            let ink = BoardInkPanel(screen: screen)
                            ink.setPen(true)
                            checks["drawing_cannot_take_focus"] = !ink.canBecomeKey && !ink.canBecomeMain && !ink.ignoresMouseEvents
                            ink.setPen(false)
                            checks["normal_mode_passes_clicks"] = ink.ignoresMouseEvents
                            ink.orderOut(nil)
                        }
                        func controls(_ view: NSView) -> [NSButton] {
                            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(controls)
                        }
                        if let root = app.windows.first(where: { $0 is NSPanel && $0.isVisible })?.contentView,
                           let control = controls(root).first(where: { $0.title == "正常操作" }) {
                            control.performClick(nil)
                            checks["capsule_control_works"] = controlClicked && !app.isActive
                        }
                        for i in 0..<3 {
                            capsule.update(page: 1, words: "启动检查，不会录音", mic: .live, warnings: [], hints: true)
                            check("same_size_refresh_\(i)")
                        }
                        capsule.update(page: 1, words: "", mic: .off,
                                       warnings: [.init(text: "测试权限提示", permission: .microphone)], hints: false)
                        check("permission_warning")
                        if let panel = app.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
                            capsule.updateMousePassthrough(at: NSPoint(x: panel.frame.minX + 1, y: panel.frame.minY + 1))
                            checks["transparent_margin"] = panel.ignoresMouseEvents
                            func buttons(_ view: NSView) -> [NSButton] {
                                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                            }
                            if let root = panel.contentView,
                               let button = buttons(root).first(where: { !$0.isHiddenOrHasHiddenAncestor }) {
                                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                                capsule.updateMousePassthrough(at: panel.convertPoint(toScreen: point))
                                checks["warning_button_clickable"] = !panel.ignoresMouseEvents
                            }
                        }
                        capsule.update(page: 2, words: "恢复转写", mic: .live, warnings: [], hints: false)
                        check("compact")
                        capsule.setExpanded(true)
                        capsule.setControls(BoardSession.capsuleControls(tool: .box, paused: false, pen: {}, use: { _ in }, undo: {},
                                                                          pause: {}, save: {}, finish: {}))
                        let sample = NSImage(size: NSSize(width: 100, height: 60))
                        sample.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 100, height: 60).fill(); sample.unlockFocus()
                        if let cg = sample.cgImage(forProposedRect: nil, context: nil, hints: nil) { capsule.setTray([cg, cg, cg]) }
                        capsule.update(page: 123, words: "展开工具和回看都由你控制", mic: .live,
                                       warnings: [.init(text: "缺少屏幕权限，当前仅保存语音", permission: .screen)], hints: false)
                        check("expanded_controls_fit")
                        if let root = app.windows.first(where: { $0 is BoardCapsulePanel && $0.isVisible })?.contentView,
                           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "/tmp/point-taken-capsule-scope.png")) }
                        }
                        capsule.setExpanded(false)
                        capsule.message(.init(symbol: nil, tint: BoardColor.text, text: "测试完成"), seconds: 5)
                        check("message")
                        func key(_ letter: String, code: UInt16) -> Bool {
                            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                          timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                                          characters: letter, charactersIgnoringModifiers: letter,
                                                          isARepeat: false, keyCode: code) else { return false }
                            return app.mainMenu?.performKeyEquivalent(with: e) ?? false
                        }
                        BoardSession.yieldKeyboard(false)
                        BoardHome.prepareForDisplay()
                        w.makeKeyAndOrderFront(nil)
                        activateApp()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            checks["settings_command_q"] = key("q", code: 12) && delegate.quitRequested
                            let hideDispatched = key("h", code: 4)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                checks["settings_command_h"] = hideDispatched && app.isHidden
                                capsule.update(page: 2, words: "隐藏后来的转写", mic: .live, warnings: [], hints: false)
                                checks["hidden_stays_hidden"] = app.isHidden
                                let pass = checks.values.allSatisfy { $0 }
                                emit(["event": "board_startup_check", "ok": pass, "checks": checks])
                                exit(pass ? 0 : 1)
                            }
                        }
                    }
                }
            }
            app.run()
        }
        exit(2)
    }

}

/// Explicit diagnostic of the current selection through the same Swift → script → service boundary.
/// Input is a caller-provided test WAV; it never starts a microphone or reads an archive.
enum BoardTranscriptionProbe {
    static func run(_ arguments: [String]) -> Never {
        guard arguments.count == 1, FileManager.default.fileExists(atPath: arguments[0]) else { exit(2) }
        _ = NSApplication.shared
        CloudSpeech.install()
        let url = URL(fileURLWithPath: arguments[0])
        let model = BoardTranscription.selected
        BoardTranscription.transcribe(url, locale: BoardSession.locale, model: model) { result in
            var event = BoardModelStatus.read(url.deletingLastPathComponent().appendingPathComponent("转写调用.json")) ?? [:]
            event["event"] = "board_transcription_probe"
            switch result {
            case .success(let file):
                event["ok"] = !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                event["characters"] = file.text.count
                event["segments"] = file.segments.count
                emit(event)
                exit(event["ok"] as? Bool == true ? 0 : 1)
            case .failure:
                event["ok"] = false
                emit(event)
                exit(1)
            }
        }
        CFRunLoopRun()
        exit(2)
    }
}
