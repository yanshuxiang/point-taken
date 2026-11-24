// Point Taken for Windows: a tray app whose one job is annotating. Launch shows only a notification and the tray icon
// (no window); opening it again while it runs pops the tray menu. The menu: 开始标注, 历史记录, 设置, the models in use
// and the last record's result, 退出. Quitting never loses a recording on its way: the session saves first.
using System.Drawing;
using System.Windows;
using System.Windows.Threading;
using PointTaken.App.Capture;
using PointTaken.App.Interop;
using PointTaken.Core;
using Forms = System.Windows.Forms;

namespace PointTaken.App;

public static class Program
{
    const string MutexName = "PointTaken.Windows.SingleInstance";
    const string ShowMenuEvent = "PointTaken.Windows.ShowMenu";

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] is "--self-check" or "--live-probe" or "--render-ui")
        {
            var outDir = args[0] is "--self-check" or "--render-ui" ? args[1] : args.Length > 2 ? args[2] : Path.Combine(Path.GetTempPath(), "point-taken-probe");
            Directory.CreateDirectory(outDir);
            using var log = new StreamWriter(Path.Combine(outDir, args[0].TrimStart('-') + ".jsonl"), append: false) { AutoFlush = true };
            Console.SetOut(log);
            var checkApp = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            TrayMenu.InstallStyles(checkApp);
            ScriptRunner.ExtraEnvironment = Secrets.Environment;
            ScriptRunner.Adopt = Native.AdoptChild;
            var code = 1;
            checkApp.Startup += (_, _) =>
            {
                try { code = args[0] switch { "--self-check" => SelfCheck.Run(outDir, checkApp), "--render-ui" => SelfCheck.RenderUi(outDir, checkApp), _ => SelfCheck.LiveProbe(args[1], outDir, checkApp) }; }
                catch (Exception e) { Console.WriteLine(e); }
                checkApp.Shutdown(code);
            };
            checkApp.Run();
            return code;
        }
        using var mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            // a second launch asks the running one to show its menu
            try { using var e = EventWaitHandle.OpenExisting(ShowMenuEvent); e.Set(); } catch { }
            return 0;
        }
        using var showMenu = new EventWaitHandle(false, EventResetMode.AutoReset, ShowMenuEvent);
        var app = new TrayApp(args.Contains("--background"));
        var wait = new Thread(() =>
        {
            while (showMenu.WaitOne())
                app.Dispatcher.BeginInvoke(app.PopMenu);
        }) { IsBackground = true };
        wait.Start();
        return app.Run();
    }
}

public sealed class TrayApp : Application
{
    readonly bool background;
    Forms.NotifyIcon? tray;
    HotkeyCenter? hotkeys;
    int? startHotkey;
    bool quitting;

    public TrayApp(bool background)
    {
        this.background = background;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        DispatcherUnhandledException += (_, e) =>
        {
            Notices.Post("出错了：" + e.Exception.Message);
            Log(e.Exception.ToString());
            e.Handled = true;
        };
        Startup += (_, _) => Launch();
    }

    static void Log(string text)
    {
        try
        {
            var dir = Path.Combine(Paths.Home, "logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "windows-app.log"), $"[{DateTime.Now:O}] {text}\n");
        }
        catch { }
    }

    void Launch()
    {
        ScriptRunner.ExtraEnvironment = Secrets.Environment;
        ScriptRunner.Adopt = Native.AdoptChild;
        TrayMenu.InstallStyles(this);
        BoardSession.Install(Dispatcher);
        var session = BoardSession.Shared;
        hotkeys = new HotkeyCenter();
        session.SuspendStartHotkey = () => { hotkeys.Unregister(startHotkey); startHotkey = null; return null; };
        session.ResumeStartHotkey = RegisterStart;
        session.StateChanged += UpdateTrayText;
        Settings.SettingsWindow.HotkeysChanged = () => { if (!session.Active) { hotkeys.Unregister(startHotkey); startHotkey = null; RegisterStart(); } };
        RegisterStart();

        tray = new Forms.NotifyIcon
        {
            Icon = LoadIcon(),
            Text = PointTakenInfo.Name,
            Visible = true,
        };
        tray.MouseUp += (_, e) => PopMenu();
        tray.BalloonTipClicked += (_, _) => PopMenu();
        _ = SpeechModels.Load();
        // a system notification only: no startup window, no change of keyboard focus
        Notices.Post(PointTakenInfo.NameZh + "已启动，点击托盘图标开始标注。");
        tray.ShowBalloonTip(5000, PointTakenInfo.NameZh + "已启动", "点击托盘图标开始标注。", Forms.ToolTipIcon.None);
        UpdateTrayText();
    }

    static Icon LoadIcon()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "icon.ico");
            if (File.Exists(path)) return new Icon(path, Forms.SystemInformation.SmallIconSize);
        }
        catch { }
        return SystemIcons.Application;
    }

    void RegisterStart()
    {
        if (hotkeys == null || startHotkey != null) return;
        startHotkey = hotkeys.Register(HotkeySettings.Start, () => BoardSession.Shared.Hotkey());
        if (startHotkey == null) Notices.Post($"开始快捷键 {HotkeySettings.Start} 被其他程序占用了；可以在设置 → 快捷键里换一个。");
    }

    void UpdateTrayText()
    {
        if (tray == null) return;
        var s = BoardSession.Shared;
        var text = s.Active ? (s.Paused ? "已暂停 · " : "正在标注 · ") + PointTakenInfo.Name : s.Finalizing ? "正在整理转写 · " + PointTakenInfo.Name : PointTakenInfo.Name;
        tray.Text = text.Length > 63 ? text[..63] : text;
    }

    public void PopMenu()
    {
        if (menuOpen) return;
        Native.GetCursorPos(out var p);
        // a WPF menu closes on a click elsewhere only while one of our windows is in front: a 1-px helper
        var helper = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = System.Windows.Media.Brushes.Transparent, ShowInTaskbar = false,
            Width = 1, Height = 1, Topmost = true, Left = -10000, Top = -10000,
        };
        helper.Show();
        helper.Activate();
        var menu = BuildMenu();
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.AbsolutePoint;
        var scale = System.Windows.Media.VisualTreeHelper.GetDpi(helper).DpiScaleX;
        menu.HorizontalOffset = p.X / scale - 12;
        menu.VerticalOffset = p.Y / scale - 12;
        menu.Closed += (_, _) => { menuOpen = false; helper.Close(); };
        menuOpen = true;
        menu.IsOpen = true;
        // above the taskbar: open upwards
        menu.Opened += (_, _) => { };
    }
    bool menuOpen;

    /// The menu (BoardHome.boardMenu): 开始标注 · 识别模型 ▸ · 历史记录… · 设置… · 退出.
    System.Windows.Controls.ContextMenu BuildMenu()
    {
        var menu = TrayMenu.Create();
        var s = BoardSession.Shared;
        var active = s.Active;
        menu.Items.Add(active ? TrayMenu.Item("正在标注 · 请使用顶部灵动岛", null, enabled: false)
                              : TrayMenu.Item(s.Finalizing ? "开始标注" : "开始标注", () => s.Start(), HotkeySettings.Start.ToString()));
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(ModelItem(active));
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(TrayMenu.Item("历史记录…", active ? null : History.HistoryWindow.ShowWindow));
        menu.Items.Add(TrayMenu.Item("设置…", active ? null : () => Settings.SettingsWindow.ShowWindow(), "Ctrl+,"));
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(TrayMenu.Item("退出", Quit, "Ctrl+Q"));
        return menu;
    }

    /// One line for the recognition model (live captions and the final transcript share it). Idle: a submenu to
    /// switch it; while recording the model is fixed for this session, so the line is display-only.
    System.Windows.Controls.MenuItem ModelItem(bool active)
    {
        var current = BoardSession.Shared.CurrentTranscriptionModel ?? BoardTranscription.Selected;
        var item = TrayMenu.Item((SpeechModels.IsLocal(current) ? "识别模型：" : "识别 API：") + SpeechModels.Title(current), null);
        if (active)
        {
            item.IsEnabled = false;
            item.ToolTip = "录音开始时已固定本次模型，结束后可切换。";
            return item;
        }
        item.IsEnabled = true;
        foreach (var m in SpeechModels.Choices(current))
        {
            var id = m.Id;
            item.Items.Add(TrayMenu.Item(SpeechModels.Title(id) + (m.Local ? " · 本地" : " · API"), () => BoardTranscription.Select(id), check: id == current));
        }
        item.Items.Add(new System.Windows.Controls.Separator());
        item.Items.Add(TrayMenu.Item("模型与 API 设置…", () => Settings.SettingsWindow.ShowWindow("模型与 API")));
        item.ToolTip = "实时字幕和结束后的完整转写都用这个模型；切换从下一次录音生效。";
        if (SpeechModels.Models.Count == 0 && !SpeechModels.Loading) _ = SpeechModels.Load();
        return item;
    }

    public void Quit()
    {
        if (quitting) return;
        quitting = true;
        BoardSession.Shared.PrepareForQuit(() =>
        {
            if (BoardFileWriter.Warning(null) is { } warning
                && MessageBox.Show(warning + "\n\n仍然退出？", "还有内容未保存", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            {
                quitting = false;
                return;
            }
            hotkeys?.Dispose();
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            Shutdown();
        });
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        // Windows is signing out: save what can be saved without waiting for the long final pass
        BoardSession.Shared.PrepareForQuit(() => { });
        BoardFileWriter.Flush();
        base.OnSessionEnding(e);
    }
}
