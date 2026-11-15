import AppKit
import SwiftUI
import PointTakenCore
import UserNotifications

/// Passive notifications have one destination. They never create or reopen a window.
final class BoardNotices: ObservableObject {
    static var shared = BoardNotices()
    private let storage: UserDefaults
    @Published private(set) var messages: [String]
    init(storage: UserDefaults = .standard) {
        self.storage = storage; messages = storage.stringArray(forKey: "board.notices") ?? []
    }
    func post(_ text: String) {
        guard !text.isEmpty else { return }
        if !Thread.isMainThread { DispatchQueue.main.async { self.post(text) }; return }
        guard messages.last != text else { return }
        messages = Array((messages + [text]).suffix(40))
        storage.set(messages, forKey: "board.notices")
    }
    func clear() { messages = []; storage.removeObject(forKey: "board.notices") }
}

extension App {
    /// Explicit startup allowlist: no projects, agents, OCR, recorder, remote server or background updater.
    func startBoardResident() {
        Config.shared.onUnreadable = { _ in BoardNotices.shared.post("配置无法读取，请在设置中检查；原记录仍然保留。") }
        Config.shared.onWriteRefused = { _ in BoardNotices.shared.post("设置未能保存，请检查配置文件。") }
        Config.shared.checkReadable()
        writeAppInfo()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "point-taken-board"
        item.isVisible = true
        // the Point Taken menu-bar mark (Assets.car, a template image macOS tints for light and dark bars)
        let mark = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: PointTaken.name)
        mark?.isTemplate = true
        mark?.accessibilityDescription = PointTaken.name
        item.button?.image = mark
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        statusItem = item
        DistributedNotificationCenter.default().addObserver(forName: .init(PointTaken.bundleID + ".start"), object: nil, queue: .main) { [weak self] _ in
            self?.popMenu()
        }
        watchOtherInstances()
        watchConfigEdits()
        Hotkeys.shared.warnOnce { BoardNotices.shared.post($0) }
        BoardLaunchNotice.shared.show()
    }
}

/// A system notification only: no startup panel and no keyboard focus change.
final class BoardLaunchNotice: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BoardLaunchNotice()
    func show(deliver: ((String) -> Void)? = nil) {
        let message = PointTaken.nameZh + "已启动，点击菜单栏图标开始标注。"
        BoardNotices.shared.post(message)
        if let deliver { deliver(message); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { allowed, error in
            if let error { BoardNotices.shared.post("启动通知未显示：" + error.localizedDescription) }
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = PointTaken.nameZh + "已启动"
            content.body = "点击菜单栏图标开始标注。"
            center.add(UNNotificationRequest(identifier: "board-started", content: content, trigger: nil)) { error in
                if let error { BoardNotices.shared.post("启动通知未显示：" + error.localizedDescription) }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) { done() }
}
