// Where things live. Same rules as record.py / _common.py: POINT_TAKEN_HOME relocates ~/.point-taken (tests, CI),
// POINT_TAKEN_WORKSPACE relocates ~/Point Taken. Read with getenv on each access — cheap (no copy of the whole environment, which
// the status item's timer used to make twice a second), and a changed variable is still honoured.
import Foundation

public enum PointTakenPaths {
    static func env(_ k: String) -> String? { getenv(k).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }

    /// ~/.point-taken, or $POINT_TAKEN_HOME
    public static var home: URL {
        env("POINT_TAKEN_HOME").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(PointTaken.homeFolder)
    }
    /// ~/.point-taken/config.json (shared with record.py)
    public static var config: URL { home.appendingPathComponent("config.json") }
    /// ~/.point-taken/index.db (C3; written only by index.py, opened read-only here)
    public static var indexDB: URL { home.appendingPathComponent("index.db") }
    /// The default workspace: ~/Point Taken, or $POINT_TAKEN_WORKSPACE
    public static var workspace: URL {
        env("POINT_TAKEN_WORKSPACE").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(PointTaken.workspaceFolder)
    }
    /// The scripts and models the app runs (scripts/, models/). A release app runs its own (BundledSkill: the copy in
    /// ~/.point-taken/skill, or the bundle itself when that copy couldn't be made), whatever skill an agent has installed.
    /// A local build: config `skill_dir` (record.py writes it on every run), else the usual install location. A
    /// config.json that doesn't parse must not move the app to another skill copy (or to none: a skill installed for
    /// Codex, at a custom path, a dev checkout): its `skill_dir` is still read from the text when it stands whole, else
    /// the last one a readable file named (kept in the app's defaults) — so the scripts keep running on the defaults
    /// instead of every call failing.
    public static var skillDir: URL {
        if let bundled = BundledSkill.source {
            let copy = BundledSkill.installed
            return FileManager.default.fileExists(atPath: copy.appendingPathComponent("scripts/_common.py").path) ? copy : bundled
        }
        return skillDir(config: .shared, remembered: .standard)
    }

    static let rememberedKey = "PointTakenSkillDir"
    /// A local build without a bundled copy: this checkout's root (scripts/ and models/ are there). This file is
    /// <root>/app/macos/Sources/PointTakenCore/Paths.swift.
    static var defaultSkillDir: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }

    static func skillDir(config: Config, remembered: UserDefaults) -> URL {
        if config.readable {
            guard let s = config["skill_dir"] as? String, !s.isEmpty else { return defaultSkillDir }
            if remembered.string(forKey: rememberedKey) != s { remembered.set(s, forKey: rememberedKey) }
            return URL(fileURLWithPath: s)
        }
        let hasScripts = { (p: String) in FileManager.default.fileExists(atPath: URL(fileURLWithPath: p).appendingPathComponent("scripts").path) }
        for s in [config.lenientString("skill_dir"), remembered.string(forKey: rememberedKey)] {
            if let s = s, !s.isEmpty, hasScripts(s) { return URL(fileURLWithPath: s) }
        }
        return defaultSkillDir
    }
    /// <skill>/scripts — transcribe.py, board_live.py…
    public static var scripts: URL { skillDir.appendingPathComponent("scripts") }
}
