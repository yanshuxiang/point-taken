// Point Taken (懂你意思): the app's own name, bundle id and folders.
//
//   settings, models, uv   ~/.point-taken
//   marked sessions        ~/Point Taken/记录
//   exports                ~/Point Taken/导出
import Foundation

public enum PointTaken {
    public static let bundleID = "io.github.yanshuxiang.pointtaken"
    public static let repo = "https://github.com/yanshuxiang/point-taken"

    public static let nameZh = "懂你意思"
    public static let nameEn = "Point Taken"
    /// The name in the app's language.
    public static var name: String { Loc.isChinese ? nameZh : nameEn }

    static let homeFolder = ".point-taken"
    static let workspaceFolder = "Point Taken"

    /// One folder per marked session.
    public static var records: URL { PointTakenPaths.workspace.appendingPathComponent("记录") }
    public static var exports: URL { PointTakenPaths.workspace.appendingPathComponent("导出") }

    /// The installed app (not a test build or a bare `swift build` binary), using the default folders.
    public static var isInstalledApp: Bool {
        Bundle.main.bundleIdentifier == bundleID
            && ProcessInfo.processInfo.environment["POINT_TAKEN_HOME"] == nil
            && ProcessInfo.processInfo.environment["POINT_TAKEN_WORKSPACE"] == nil
    }
}
