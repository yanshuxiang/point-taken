// Called once at launch, before the menu exists: registers Settings and pointtaken:// handling with the shell
// (AppEnvironment).
import AppKit
import PointTakenCore

enum SettingsModule {
    static func install() {
        AppEnvironment.settings = SettingsController.shared
        AppEnvironment.openURL = { URLRouter.handle($0) }
        CloudStore.refreshStale()
    }
}

// pointtaken:// URLs (Info.plist CFBundleURLTypes), handed over by the app delegate:
//   pointtaken://settings[/<pane>[/<row>]]  → Settings (general, speech, shortcuts, privacy); a row or section is
//                                             scrolled to and flashed (speech/recognition, general/login…)
//   pointtaken://open                       → the menu at the pointer
// Nothing that starts a recording or changes data is reachable from a URL: any web page can open one.
enum URLRouter {
    enum Route: Equatable {
        case settings(String?)
        case open
        case unknown
    }

    static func route(_ u: URL) -> Route {
        guard u.scheme == "pointtaken" else { return .unknown }
        var rest = u.path
        if rest.hasPrefix("/") { rest.removeFirst() }
        rest = rest.removingPercentEncoding ?? rest
        switch u.host ?? "" {
        case "settings": return .settings(rest.isEmpty ? nil : rest)
        case "open": return .open
        default: return .unknown
        }
    }

    static func handle(_ u: URL) -> Bool {
        let r = route(u)
        emit(["event": "url", "url": u.absoluteString, "route": "\(r)"])
        switch r {
        case .settings(let pane): AppEnvironment.settings?.show(pane: pane)
        case .open: (NSApp.delegate as? App)?.popMenu()
        case .unknown: return false
        }
        return true
    }
}
