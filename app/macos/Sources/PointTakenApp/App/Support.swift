import AppKit
import PointTakenCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Options & utilities

struct Options {
    var out = ""
    var events: String? = nil
    var standalone = false         // launched as an app (no --out): lives in the menu bar, records into a workspace
    var fps = 30
    var maxWidth = 2560
    var countdown = 3
    var lang: String? = nil       // --lang en|zh-Hans: overrides config `lang` (K10, Loc.setting)
    var region: CGRect? = nil      // skip picker (global top-left points)
    var lastRegion: CGRect? = nil  // offered in the picker
    var preselect: CGRect? = nil   // picker opens with this selection (testing / "last region")
    var mic = true
    var micName: String? = nil
    var systemAudio = false        // second audio track: what the Mac plays (meeting voices, demo sound), macOS 13+
    var live = true                // mic also → <session>/live/audio.pcm for live.py (LiveAudio.swift); --no-live

    static func parse() -> Options {
        var o = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func rect(_ s: String?) -> CGRect? {
            guard let p = s?.split(separator: ",").compactMap({ Double($0) }), p.count == 4 else { return nil }
            return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        }
        while let a = it.next() {
            switch a {
            case "--out": o.out = it.next() ?? o.out
            case "--events": o.events = it.next()
            case "--fps": o.fps = Int(it.next() ?? "") ?? o.fps
            case "--max-width": o.maxWidth = Int(it.next() ?? "") ?? o.maxWidth
            case "--countdown": o.countdown = Int(it.next() ?? "") ?? o.countdown
            case "--lang": o.lang = it.next()
            case "--region": o.region = rect(it.next())
            case "--last-region": o.lastRegion = rect(it.next())
            case "--preselect": o.preselect = rect(it.next())
            case "--no-mic": o.mic = false
            case "--mic": o.micName = it.next()
            case "--system-audio": o.systemAudio = true
            case "--no-live": o.live = false
            default: break
            }
        }
        if o.out.isEmpty { o.standalone = true }
        return o
    }
}

// MARK: - Config shared with record.py (~/.point-taken/config.json)

// POINT_TAKEN_HOME (as in record.py) relocates config/build state; tests use it to stay out of the user's real setup.
let pointTakenHome = PointTakenPaths.home
let configURL = PointTakenPaths.config

func readConfig() -> [String: Any] { Config.shared.all }

func recordConfig() -> [String: Any] { Config.shared.record }

func setRecordConfig(_ key: String, _ value: Any?) { Config.shared.set("record." + key, value) }

func saveLastRegion(_ r: CGRect) { setRecordConfig("last_region", [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]) }

func lastRegionFromConfig() -> CGRect? {
    guard let r = recordConfig()["last_region"] as? [Double], r.count == 4 else { return nil }
    return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
}

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}


/// Global coordinates: AppKit uses bottom-left origin, CoreGraphics / ScreenCaptureKit use top-left.
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

/// Our chrome (the island, hanging cards, the note bubble, live captions, the ink stage, flashes) can be captured by
/// other tools — ⌘⇧4, WeChat's screenshot, a screen share — so people can show and report it (the founder,
/// 2026-10-30: "otherwise I can't even screenshot it"). Point Taken's own recordings, snaps and loupe stills leave it out
/// through their content filters (Recorder / Snap: every window of this process above the normal level).
let chromeSharing: NSWindow.SharingType = .readOnly

func activateApp() {
    if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

/// Brings one of our windows up in front of the user, whatever app is frontmost. Asking to become the active app is
/// only a request on macOS 14 and later (the frontmost app may keep the focus), so the window is also ordered to the
/// front regardless: it shows on top right away and takes the keyboard as soon as it is clicked.
func presentWindow(_ window: NSWindow) {
    activateApp()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }


func pill(_ text: String, font: NSFont, fg: NSColor, bg: NSColor, at p: NSPoint, pad: CGFloat = 8, icon: BrandIcon? = nil) -> NSRect {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
    let sz = s.size()
    let iw = icon == nil ? 0 : pillIconWidth(font)
    let r = NSRect(x: p.x, y: p.y, width: sz.width + pad * 2 + iw, height: sz.height + pad)
    bg.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    if let icon = icon {     // a brand icon in front of the text (never an emoji)
        let side = (font.pointSize * 1.2).rounded()
        icon.image(size: side, color: fg).draw(in: NSRect(x: r.minX + pad, y: r.midY - side / 2, width: side, height: side),
                                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    s.draw(at: NSPoint(x: r.minX + pad + iw, y: r.minY + pad / 2))
    return r
}

/// Room an icon takes in a pill: the icon (1.2 × the font size) and a gap.
func pillIconWidth(_ font: NSFont) -> CGFloat { (font.pointSize * 1.2).rounded() + 6 }

/// The user guide (docs/guide.md on GitHub — its English half or its Chinese half, by the app's language): Help in the
/// menus and Settings → General, and the lines that point to one of its sections.
enum Help {
    static let repo = PointTaken.repo

    /// `section`: "update" (keeping the app and the skill current); nil = the top of the guide.
    static func guideURL(section: String? = nil) -> URL {
        let zh = Loc.language.hasPrefix("zh")
        let anchor: String
        switch section {
        case "update": anchor = zh ? "9-更新" : "9-updating"        // GitHub's anchors for "### 9. Updating" / "### 9. 更新"
        default: anchor = zh ? "中文" : "english"
        }
        return URL(string: "\(repo)/blob/main/docs/guide.md#" + (anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? anchor))!
    }
}

/// macOS's Reduce Motion (or POINT_TAKEN_REDUCE_MOTION=1 for a test run): animations become fades or nothing.
var reduceMotion: Bool { reduceMotionForced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
private let reduceMotionForced = ProcessInfo.processInfo.environment["POINT_TAKEN_REDUCE_MOTION"] == "1"
