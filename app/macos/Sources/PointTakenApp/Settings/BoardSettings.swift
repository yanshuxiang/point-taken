import AppKit
import SwiftUI
import Speech
import AVFoundation
import PointTakenCore

func boardSettingText(_ chinese: String, _ english: String) -> String { Loc.isChinese ? chinese : english }

/// General's settings: opening at login and the app's language.
final class BoardGeneralModel: ObservableObject {
    @Published var openAtLogin = false
    @Published var loginError: String?
    @Published var language = "auto"

    init() { reload() }

    func reload() {
        openAtLogin = LoginItem.enabled
        let l = Config.shared["lang"] as? String ?? "auto"
        language = l == "zh" ? "zh-Hans" : (["en", "zh-Hans"].contains(l) ? l : "auto")
    }

    /// A test build never registers itself in the user's Login Items (LoginItem).
    func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on, via: "settings") == nil ? nil : T("settings.general.login_failed")
        openAtLogin = LoginItem.enabled
    }

    func setLanguage(_ v: String) {
        Config.shared.set("lang", v == "auto" ? nil : v)
        language = v
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return v.isEmpty ? "—" : v
    }
}

/// Only settings used by the annotation workflow. Standalone dictation and its model controls are not part of this app.
struct BoardGeneralPane: View {
    @StateObject private var model = BoardGeneralModel()
    @State private var locale = BoardSession.locale
    @ObservedObject private var notices = BoardNotices.shared

    var body: some View {
        SettingsPage(.general) {
            SettingsGroup("board.app", title: boardSettingText("应用", "App")) {
                SettingToggle("board.login", isOn: Binding(get: { model.openAtLogin }, set: { model.setLogin($0) }),
                              title: boardSettingText("登录时启动" + PointTaken.nameZh, "Open Point Taken at login"), detail: model.loginError)
                SettingRow("board.language", title: boardSettingText("界面语言", "App language")) {
                    ChoicePopup(label: boardSettingText("界面语言", "App language"),
                                choices: [("auto", boardSettingText("跟随系统", "System default")), ("zh-Hans", "简体中文"), ("en", "English")],
                                selection: Binding(get: { model.language }, set: { model.setLanguage($0) }))
                }
                if Loc.normalize(model.language) != Loc.language {
                    SettingsLine {
                        Text(boardSettingText("重新打开" + PointTaken.nameZh + "后生效", "Takes effect after reopening Point Taken")).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsGroup("board.annotation", title: boardSettingText("标注", "Annotation")) {
                SettingRow("board.locale", title: boardSettingText("识别语言", "Speech language"),
                           detail: boardSettingText("录音时按这种语言识别你说的话", "The language you speak while recording")) {
                    ChoicePopup(label: boardSettingText("识别语言", "Speech language"),
                                choices: [("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어")],
                                selection: Binding(get: { locale }, set: { value in
                                    locale = value
                                    var board = recordConfig()["board"] as? [String: Any] ?? [:]
                                    board["locale"] = value
                                    setRecordConfig("board", board)
                                }))
                }
                SettingRow("board.records", title: boardSettingText("记录", "Records"),
                           detail: boardSettingText("原始录音、完整转写和截图一直保留，手动删除。", "Original audio, full transcripts and screenshots stay until you delete them.")) {
                    Button(boardSettingText("打开文件夹", "Open folder")) {
                        let root = BoardHistoryWindow.root
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(root)
                    }
                }
            }
            // messages only while there are some (nothing to show is no section at all)
            if !notices.messages.isEmpty {
                SettingsGroup("board.notices", title: boardSettingText("消息", "Messages"), content: {
                    ForEach(Array(notices.messages.enumerated()), id: \.offset) { _, text in
                        SettingsLine { Text(text).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true) }
                    }
                }, accessory: {
                    Button(boardSettingText("清空", "Clear")) { notices.clear() }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                })
            }
            Text(boardSettingText(PointTaken.nameZh, PointTaken.nameEn) + " " + BoardGeneralModel.version)
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, SettingsMetrics.groupGap)
        }
        .onAppear { model.reload() }
    }
}

struct BoardPermissionsPane: View {
    @StateObject private var permissions = Permissions()
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Speech recognition is only needed for Apple's recognizer: it never counts as missing in the summary.
    private var missingRequired: Int {
        [permissions.screen, permissions.mic, permissions.accessibility].filter { $0 != .granted }.count
    }

    var body: some View {
        SettingsPage(.privacy) {
            // said once, above the rows, only while something required is missing (HIG: nothing while all is well)
            if missingRequired > 0 {
                SettingsNotice(title: boardSettingText("还有 \(missingRequired) 项必需权限没有开启", "\(missingRequired) required permission(s) still off"),
                               detail: boardSettingText("点对应的「打开系统设置…」，允许后回到这里。", "Use “Open System Settings…”, allow it, then come back.")) {
                    Button(boardSettingText("重新检查", "Check Again")) {
                        permissions.refresh(); speech = SFSpeechRecognizer.authorizationStatus()
                    }
                }
                .padding(.top, SettingsMetrics.groupGap)
                .id("board.permissions")
            }
            SettingsGroup("board.permissions.required", title: boardSettingText("必需", "Required")) {
                permission("screen", icon: "rectangle.dashed.badge.record", boardSettingText("屏幕录制", "Screen Recording"),
                           boardSettingText("保存你标注的页面", "Capture the pages you annotate"), granted: permissions.screen == .granted) {
                    if !CGRequestScreenCaptureAccess() { BoardPermission.screen.open() }
                }
                permission("microphone", icon: "mic", boardSettingText("麦克风", "Microphone"),
                           boardSettingText("录下你的讲解", "Record your narration"), granted: permissions.mic == .granted) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { permissions.refresh() } }
                    } else { BoardPermission.microphone.open() }
                }
                permission("accessibility", icon: "accessibility", boardSettingText("辅助功能", "Accessibility"),
                           boardSettingText("把结果粘贴到你选择的应用", "Paste results into the app you choose"),
                           granted: permissions.accessibility == .granted) {
                    BoardPermission.accessibility.open()
                }
            }
            SettingsGroup("board.permissions.optional", title: boardSettingText("可选", "Optional"),
                          footer: boardSettingText("在「系统设置 › 隐私与安全性」里改动后，这里会自动更新。",
                                                   "Changes made in System Settings › Privacy & Security show up here automatically.")) {
                permission("speech", icon: "waveform", boardSettingText("语音识别", "Speech Recognition"),
                           boardSettingText("只有选用苹果系统识别时需要", "Needed only for Apple’s speech recognition"),
                           granted: speech == .authorized) {
                    if speech == .notDetermined {
                        SFSpeechRecognizer.requestAuthorization { value in DispatchQueue.main.async { speech = value } }
                    } else { BoardPermission.speech.open() }
                }
            }
        }
        .onAppear { permissions.start(); speech = SFSpeechRecognizer.authorizationStatus() }
        .onDisappear { permissions.stop() }
        .onReceive(timer) { _ in speech = SFSpeechRecognizer.authorizationStatus() }
    }

    /// A permission: its glyph, name and what it is for; on the right "Allowed" with a check, or the way to allow it.
    private func permission(_ id: String, icon: String, _ title: String, _ detail: String, granted: Bool,
                            action: @escaping () -> Void) -> some View {
        SettingRow("board.permission." + id, title: title, detail: detail, icon: icon) {
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
                    Text(boardSettingText("已允许", "Allowed")).foregroundStyle(.secondary)
                }
                .font(.system(size: SettingsMetrics.titleSize))
            } else {
                Button(boardSettingText("打开系统设置…", "Open System Settings…"), action: action)
            }
        }
    }
}

/// The filled, rounded card the Lianbiao panes put their rows on.
struct BoardCard: View {
    var tint: Color?
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape.fill(tint.map { $0.opacity(0.07) } ?? Color.primary.opacity(0.03))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.25) } ?? Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// Render the actual settings views offscreen; no microphone, screen capture or setting changes.
enum BoardSettingsPreview {
    static func run() -> Never {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            Loc.setting = "zh-Hans"
            // every pane 连标 shows, in both appearances, tall enough for the whole page (POINT_TAKEN_PREVIEW_HEIGHT)
            let height = CGFloat(Double(ProcessInfo.processInfo.environment["POINT_TAKEN_PREVIEW_HEIGHT"] ?? "") ?? 540)
            let panes: [(String, () -> AnyView)] = [("general", { AnyView(BoardGeneralPane()) }), ("permissions", { AnyView(BoardPermissionsPane()) }),
                                                    ("speech", { AnyView(SpeechPane()) }), ("shortcuts", { AnyView(ShortcutsPane()) })]
                + (ProcessInfo.processInfo.environment["POINT_TAKEN_PREVIEW_SHEETS"] == "1" ? SettingsSheetsPreview.views() : [])
            // POINT_TAKEN_PREVIEW_PANES=shortcuts,general: only those (Models & API reads the Keychain: leave it out unless asked)
            let only = ProcessInfo.processInfo.environment["POINT_TAKEN_PREVIEW_PANES"].map { Set($0.split(separator: ",").map(String.init)) }
            let chosen = only.map { o in panes.filter { o.contains($0.0) } } ?? panes
            for (look, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] { for (name, make) in chosen {
                NSApp.appearance = NSAppearance(named: appearance)
                let name = name + look
                let controller = NSHostingController(rootView: make())
                controller.sizingOptions = []
                // a real titled window, as Settings is (a borderless one sends some pages' layout round in circles)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: height),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.isReleasedWhenClosed = false
                window.contentViewController = controller
                window.setContentSize(NSSize(width: 640, height: height))
                window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
                window.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                controller.view.layoutSubtreeIfNeeded()
                guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else { exit(1) }
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do { try data.write(to: URL(fileURLWithPath: "/tmp/point-taken-settings-\(name).png")) }
                catch { exit(1) }
                window.close()
            } }
            exit(0)
        }
    }
}

/// Reads the same model as Settings, without changing grants or opening a window.
enum BoardPermissionCheck {
    static func run() -> Never {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let state = Permissions()
            let actual = AXIsProcessTrusted()
            let checks = ["production_identity": !PasteMode.testMode,
                          "settings_matches_system": (state.accessibility == .granted) == actual,
                          "paste_matches_system": PastePermission.accessibility == actual]
            let ok = checks.values.allSatisfy { $0 }
            emit(["event": "board_permission_check", "ok": ok, "checks": checks,
                  "system_accessibility": actual, "settings_accessibility": state.accessibility.rawValue])
            exit(ok ? 0 : 1)
        }
    }
}
