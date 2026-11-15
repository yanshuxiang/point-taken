// PointTakenRecorder — native macOS recorder for point-taken (ScreenCaptureKit + AVAssetWriter).
//
// Flow: region picker (drag / click a window / F = full screen) → 3-2-1 countdown → recording with a floating
// control bar (timer, mic level, pause, pen, stop) that is never in the recording. Output: H.264/AAC mp4 + events.jsonl
// (pauses, markers, clicks, cursor samples, pen strokes). Built on first use by record.py with `swiftc`.
// Pen: hold ⌃ and drag to circle / underline / point at things — the ink is in the video and in events.jsonl.
//
// Control: HUD buttons, global hotkeys (defaults ⌥P pause/resume, ⌥A snap, ⌥D pen on/off, ⌥S stop; configurable,
// Hotkeys.swift; ⌥M's marker went in 1.0.7),
// stdin lines ("pause" | "resume" | "toggle" | "snap" | "stop"; an older record.py's "marker" is a snap), or
// SIGTERM/SIGINT (= stop).
// Snap mode, the island and notes live in Capture/ (Snap.swift, Island/, NoteBubble.swift); Peep, the mascot, in
// Icons/Mascot.swift (frames from Resources/Peep) and the menu-bar glyph in App/MenuGlyph.swift.
// stdout: one JSON object per line: ready, selected, countdown, recording, paused, resumed, snap, level?, stopped,
// cancelled, error.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement
import PointTakenCore

// Test hooks (POINT_TAKEN_TEST_*: a command channel, automatic yeses, stand-in permissions…) work only in a build made for tests
// (`POINT_TAKEN_TEST_HOOKS=1 record.py build`) or a debug build. In any other they're gone before anything reads them: another
// program launching Point Taken with them could otherwise skip a question the user must answer, or borrow Point Taken's Screen Recording,
// microphone or Accessibility.
// The same for the few test hooks with other names (a wav for the microphone, where agents are looked for, inspectable web views), and
// for what a launcher could slip into the scripts and agents Point Taken starts, which run with its permissions. The user's own settings for
// those come from their login shell (ShellEnv), not from whoever launched the app.
#if !(DEBUG || POINT_TAKEN_TEST_HOOKS)
private let launchOnly: Set<String> = ["POINT_TAKEN_NOTE_WAV", "POINT_TAKEN_AGENT_PATH", "POINT_TAKEN_INSPECT", "POINT_TAKEN_SCREEN_SNAP_DIR",
                                       "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "NODE_OPTIONS", "NODE_PATH",
                                       "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB", "BASH_ENV", "ENV", "LD_PRELOAD"]
for k in ProcessInfo.processInfo.environment.keys where k.hasPrefix("POINT_TAKEN_TEST_") || k.hasPrefix("DYLD_") || launchOnly.contains(k) { unsetenv(k) }
#endif


// macOS's speech recognition for transcribe.py's `apple` backend (Capture/AppleSpeech.swift): answers and exits.
switch CommandLine.arguments.dropFirst().first {
case "--speech": AppleSpeech.runCLI(Array(CommandLine.arguments.dropFirst(2)))
case "--board-live-probe": BoardLiveProbe.run(Array(CommandLine.arguments.dropFirst(2)))
case "--board-transcription-probe": BoardTranscriptionProbe.run(Array(CommandLine.arguments.dropFirst(2)))
case "--board-preview": BoardPreview.run(Array(CommandLine.arguments.dropFirst(2)))
case "--board-startup-check": BoardStartupCheck.runStartupCheck()
case "--board-workflow-check": BoardReviewWindow.runWorkflowCheck()
case "--board-review-preview":
    // point-taken --board-review-preview <record folder> [page] [WxH] [out.png] [dark]
    let a = CommandLine.arguments
    let size = a.count > 4 ? a[4].split(separator: "x").compactMap { Double($0) } : []
    BoardReviewWindow.renderArchive(URL(fileURLWithPath: a[2]), to: a.count > 5 ? a[5] : "/tmp/point-taken-review-archive.png",
                                    page: a.count > 3 ? Int(a[3]) ?? 1 : 1,
                                    size: size.count == 2 ? NSSize(width: size[0], height: size[1]) : nil,
                                    dark: a.count > 6 && a[6] == "dark")
    exit(0)
case "--board-history-preview": _ = NSApplication.shared; BoardHistoryWindow.renderPreview(to: "/tmp/point-taken-history-preview"); exit(0)
case "--board-history-check": BoardHistoryWindow.runHistoryCheck()
case "--board-retention-check": BoardSpeech.runRetentionCheck()
case "--board-settings-preview": BoardSettingsPreview.run()
case "--board-evidence-check": BoardSession.runEvidenceCheck()
case "--board-permission-check": BoardPermissionCheck.run()
case "--speech-status": AppleSpeech.runCLI(["--status"] + Array(CommandLine.arguments.dropFirst(2)))
default: break
}

var opts = Options.parse()
if let l = opts.lang { Loc.setting = l }
Loc.applyToSystemStrings()


// A second copy of the app (double-click while it's running) just asks the running one to start recording.
// Only for plain launches — `--process`, `--background` etc. are explicit instructions for this process.
let plainLaunch = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") && !$0.hasPrefix("--lang") }
if opts.standalone, plainLaunch, ProcessInfo.processInfo.environment["POINT_TAKEN_ALLOW_MULTI"] == nil,
   NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? PointTaken.bundleID)
       .contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(.init(PointTaken.bundleID + ".start"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
// Point Taken's own dictation is Fn: AppKit's Edit → Start Dictation (macOS's) would be a second one in the same menu.
// Emoji & Symbols stays. In-memory defaults only — nothing is written to the user's preferences.
UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
