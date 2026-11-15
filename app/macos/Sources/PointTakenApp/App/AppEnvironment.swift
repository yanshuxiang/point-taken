// Seams between the app shell and the parts that plug into it: the settings window (SettingsModule), and the URLs
// macOS hands the app.
import AppKit

protocol SettingsHosting: AnyObject {
    /// nil = the last pane / the first one
    func show(pane: String?)
}

enum AppEnvironment {
    static var settings: SettingsHosting?
    /// pointtaken:// URLs handed to the app by macOS (URLRouter in SettingsModule.swift).
    static var openURL: ((URL) -> Bool)?

    static func installModules() { SettingsModule.install() }
}
