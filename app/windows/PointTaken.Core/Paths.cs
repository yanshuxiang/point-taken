// Where things live. Same rules as the macOS app and scripts/_common.py: POINT_TAKEN_HOME relocates ~/.point-taken
// (tests, CI), POINT_TAKEN_WORKSPACE relocates ~/Point Taken. Read on each access so a changed variable is honoured.
namespace PointTaken.Core;

public static class PointTakenInfo
{
    public const string Name = "Point Taken";
    public const string NameZh = "懂你意思";
    public const string HomeFolder = ".point-taken";
    public const string WorkspaceFolder = "Point Taken";
    /// the folder inside the workspace that holds one subfolder per annotation session
    public const string RecordsFolder = "连标";
    /// independent hand-off copies (图1.png … 说明.md)
    public const string ExportsFolder = "连标导出";
}

public static class Paths
{
    static string? Env(string k)
    {
        var v = Environment.GetEnvironmentVariable(k);
        return string.IsNullOrEmpty(v) ? null : v;
    }

    static string UserHome => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// ~/.point-taken, or $POINT_TAKEN_HOME
    public static string Home => Env("POINT_TAKEN_HOME") ?? Path.Combine(UserHome, PointTakenInfo.HomeFolder);
    /// ~/.point-taken/config.json (shared with the Python scripts)
    public static string ConfigFile => Path.Combine(Home, "config.json");
    /// ~/.point-taken/models
    public static string Models => Path.Combine(Home, "models");
    /// ~/Point Taken, or $POINT_TAKEN_WORKSPACE, or the folder chosen in Settings (config record.board.folder)
    public static string Workspace => Env("POINT_TAKEN_WORKSPACE") ?? Path.Combine(UserHome, PointTakenInfo.WorkspaceFolder);

    /// ~/Point Taken/连标 — or the records folder the user picked.
    public static string Records
    {
        get
        {
            var chosen = Config.Shared.GetString("record.board.folder");
            return !string.IsNullOrWhiteSpace(chosen) && Path.IsPathRooted(chosen)
                ? chosen
                : Path.Combine(Workspace, PointTakenInfo.RecordsFolder);
        }
    }

    /// ~/Point Taken/连标导出
    public static string Exports => Path.Combine(Path.GetDirectoryName(Records.TrimEnd('\\', '/')) ?? Workspace, PointTakenInfo.ExportsFolder);

    /// The scripts and models the app runs: next to the executable when installed (scripts\, models\), else this
    /// checkout's root (a development build run from app\windows\…\bin). POINT_TAKEN_SKILL_DIR overrides.
    public static string SkillDir
    {
        get
        {
            if (Env("POINT_TAKEN_SKILL_DIR") is { } forced) return forced;
            var exe = AppContext.BaseDirectory;
            if (File.Exists(Path.Combine(exe, "scripts", "_common.py"))) return exe;
            var dir = new DirectoryInfo(exe);
            for (var i = 0; i < 8 && dir != null; i++, dir = dir.Parent)
                if (File.Exists(Path.Combine(dir.FullName, "scripts", "_common.py"))) return dir.FullName;
            return exe;
        }
    }

    public static string Scripts => Path.Combine(SkillDir, "scripts");

    /// A session folder's name: yyyy-MM-dd HH.mm.ss.fff (the macOS app's format; History parses it back).
    public const string SessionStampFormat = "yyyy-MM-dd HH.mm.ss.fff";
}
