// Settings — the macOS app's Settings window for 懂你意思: a sidebar (懂你意思: 通用, 模型与 API, 快捷键, 权限) and a
// page: its title, then sections — a header, a grouped rounded box of rows (an icon, a title over a quiet detail line,
// the control at the right), and a footnote under it.
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using PointTaken.App.Capture;
using PointTaken.Core;

namespace PointTaken.App.Settings;

public sealed class SettingsWindow : MacWindow
{
    static SettingsWindow? open;
    public static Action? HotkeysChanged;
    readonly StackPanel sidebarItems = new() { Margin = new Thickness(10, 0, 10, 0) };
    readonly ScrollViewer page = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    readonly List<(string name, Border row)> panes = new();
    string current = "通用";

    public static void ShowWindow() => ShowWindow(null);

    public static void ShowWindow(string? pane)
    {
        if (open == null) { open = new SettingsWindow(); open.Closed += (_, _) => open = null; open.Show(); }
        if (open.WindowState == WindowState.Minimized) open.WindowState = WindowState.Normal;
        open.Activate();
        open.Show(pane ?? open.current);
    }

    SettingsWindow() : base(52)
    {
        Title = "设置";
        Width = 780; Height = 560; MinWidth = 680; MinHeight = 440;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(172) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var side = new DockPanel { Background = Mac.Sidebar };
        var label = Mac.Text(PointTakenInfo.NameZh, Mac.Subheadline, FontWeights.SemiBold, Mac.Tertiary);
        label.Margin = new Thickness(16, 66, 0, 6);
        DockPanel.SetDock(label, Dock.Top);
        side.Children.Add(label);
        foreach (var (name, symbol) in new[] { ("通用", Icons.Gear), ("模型与 API", Icons.Chip), ("快捷键", Icons.Keyboard), ("权限", Icons.Hand) })
        {
            var icon = Mac.Symbol(symbol, 17, Mac.Secondary, 1.4);
            icon.Margin = new Thickness(0, 0, 10, 0);
            var text = Mac.Text(name, 15);
            var row = new Border
            {
                Child = Ui2Row(icon, text), Height = 32, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 0, 0, 0), Margin = new Thickness(0, 0, 0, 2), Cursor = Cursors.Arrow,
                Background = Brushes.Transparent,
            };
            var n = name;
            row.MouseLeftButtonUp += (_, _) => Show(n);
            panes.Add((name, row));
            sidebarItems.Children.Add(row);
        }
        side.Children.Add(sidebarItems);
        grid.Children.Add(side);
        Grid.SetColumn(page, 1);
        grid.Children.Add(page);
        Body = grid;
    }

    static StackPanel Ui2Row(params UIElement[] items)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var i in items) s.Children.Add(i);
        return s;
    }

    void Show(string name)
    {
        current = name;
        foreach (var (n, row) in panes) row.Background = n == name ? Mac.B(0x14, 0, 0, 0) : Brushes.Transparent;
        Title = name;
        var content = new StackPanel { Margin = new Thickness(24, 0, 28, 28) };
        var title = Mac.Text(name, Mac.Title2, FontWeights.SemiBold);
        title.Margin = new Thickness(0, 14, 0, 40);
        content.Children.Add(title);
        switch (name)
        {
            case "模型与 API": Models(content); break;
            case "快捷键": Shortcuts(content); break;
            case "权限": Permissions(content); break;
            default: General(content); break;
        }
        page.Content = content;
    }

    // ── the pieces every page is made of ──

    static void Section(Panel into, string header, IEnumerable<UIElement> rows, string? footnote = null, UIElement? footer = null)
    {
        if (header.Length > 0)
        {
            var h = Mac.Text(header, 15, FontWeights.SemiBold);
            h.Margin = new Thickness(Mac.GroupGap, 0, 0, Mac.Inner);
            into.Children.Add(h);
        }
        var stack = new StackPanel();
        var first = true;
        foreach (var row in rows)
        {
            if (!first) stack.Children.Add(new Border { Height = 1, Background = Mac.Separator, Margin = new Thickness(Mac.GroupGap, 0, Mac.GroupGap, 0) });
            stack.Children.Add(row);
            first = false;
        }
        into.Children.Add(new Border { Child = stack, Background = Mac.Group, BorderBrush = Mac.GroupEdge, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12) });
        if (footnote != null)
        {
            var f = Mac.Text(footnote, Mac.Callout, color: Mac.Secondary, wrap: true);
            f.Margin = new Thickness(Mac.GroupGap, Mac.Inner, Mac.GroupGap, 0);
            into.Children.Add(f);
        }
        if (footer != null) into.Children.Add(footer);
        into.Children.Add(new Border { Height = 28 });
    }

    /// One row: an optional icon, the title over its detail, the control at the right.
    static UIElement Row(string title, string? detail, UIElement? control, Geometry? icon = null, double minHeight = 56)
    {
        var dock = new DockPanel { MinHeight = minHeight, Margin = new Thickness(Mac.GroupGap, 6, Mac.GroupGap, 6) };
        if (control != null)
        {
            if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(control, Dock.Right);
            dock.Children.Add(control);
        }
        if (icon != null)
        {
            var i = Mac.Symbol(icon, 20, Mac.Secondary, 1.4);
            i.Margin = new Thickness(0, 0, 14, 0);
            i.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(i, Dock.Left);
            dock.Children.Add(i);
        }
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        texts.Children.Add(Mac.Text(title, 15, wrap: true));
        if (!string.IsNullOrEmpty(detail))
        {
            var d = Mac.Text(detail, Mac.Callout, color: Mac.Secondary, wrap: true);
            d.Margin = new Thickness(0, 2, 0, 0);
            texts.Children.Add(d);
        }
        dock.Children.Add(texts);
        return dock;
    }

    /// A pop-up button (NSPopUpButton): the chosen title and ⌃⌄ on a grey capsule; a Mac menu opens on click.
    static Button Popup(IReadOnlyList<(string id, string title)> choices, string selected, Action<string> pick, double maxWidth = 280)
    {
        var text = Mac.Text(choices.FirstOrDefault(c => c.id == selected).title ?? selected, 15);
        text.MaxWidth = maxWidth - 40;
        var chevrons = Mac.Symbol(Icons.ChevronUpDown, 13, Mac.Label, 1.8);
        chevrons.Margin = new Thickness(12, 0, 0, 0);
        var b = new Button
        {
            Content = Ui2Row(text, chevrons), Height = 32, Padding = new Thickness(12, 0, 12, 0), Focusable = false, Cursor = Cursors.Arrow,
            Template = Mac.Template(Mac.B(0x12, 0, 0, 0), Mac.B(0x1C, 0, 0, 0), 8, pressed: Mac.B(0x26, 0, 0, 0)), MaxWidth = maxWidth,
        };
        b.Click += (_, _) =>
        {
            var menu = TrayMenu.Create();
            foreach (var (id, title) in choices)
            {
                var chosen = id;
                menu.Items.Add(TrayMenu.Item(title, () => { text.Text = title; pick(chosen); }, check: id == selected));
            }
            menu.PlacementTarget = b; menu.Placement = PlacementMode.Bottom; menu.HorizontalOffset = -12; menu.VerticalOffset = -10;
            menu.IsOpen = true;
        };
        return b;
    }

    // ── 通用 ──

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static bool StartsWithWindows
    {
        get { using var k = Registry.CurrentUser.OpenSubKey(RunKey); return k?.GetValue(PointTakenInfo.Name) is string; }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue(PointTakenInfo.Name, $"\"{Environment.ProcessPath}\" --background");
            else k.DeleteValue(PointTakenInfo.Name, false);
        }
    }

    void General(Panel content)
    {
        Section(content, "应用", new[]
        {
            Row("登录时启动", null, Mac.Switch(StartsWithWindows, on => { try { StartsWithWindows = on; } catch (Exception e) { MacAlert.Show(this, "无法更改", e.Message, new[] { "好" }); } }), minHeight: 40),
        });
        var languages = new[] { ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어") };
        Section(content, "标注", new[]
        {
            Row("识别语言", "录音时按这种语言识别你说的话", Popup(languages, BoardSession.Locale, id => Config.Shared.Set("record.board.locale", id))),
        });
        var open = Mac.Push("打开文件夹", () => { Directory.CreateDirectory(Paths.Records); Paste.OpenFolder(Paths.Records); });
        Section(content, "记录", new[] { Row("原始录音、完整转写和截图一直保留，手动删除。", Paths.Records, open) });

        var list = new StackPanel();
        void Fill()
        {
            list.Children.Clear();
            var items = Notices.Items;
            if (items.Count == 0) { list.Children.Add(Row("没有消息", null, null, minHeight: 40)); return; }
            foreach (var n in items.Take(30))
                list.Children.Add(Row(n.Text, n.At.ToString("M月d日 HH:mm"), null, minHeight: 40));
        }
        Fill();
        Notices.Changed += () => Dispatcher.BeginInvoke(Fill);
        var clear = Mac.Push("清空", () => { Notices.Clear(); Fill(); }, height: 28, size: Mac.Callout);
        var header = new DockPanel { Margin = new Thickness(Mac.GroupGap, 0, 0, Mac.Inner) };
        DockPanel.SetDock(clear, Dock.Right);
        header.Children.Add(clear);
        header.Children.Add(Mac.Text("消息", 15, FontWeights.SemiBold));
        content.Children.Add(header);
        content.Children.Add(new Border { Child = list, Background = Mac.Group, BorderBrush = Mac.GroupEdge, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12) });
    }

    // ── 模型与 API ──

    readonly Dictionary<string, CancellationTokenSource> downloads = new();
    static readonly Regex Progress = new(@"^\s+(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?) MB", RegexOptions.Compiled);

    void Models(StackPanel content)
    {
        if (SpeechModels.Models.Count == 0)
        {
            content.Children.Add(Mac.Text(SpeechModels.Error is { } err ? "读不到模型列表：" + err : "正在检查这台电脑…（第一次会准备运行环境，可能要一两分钟）", Mac.Callout, color: SpeechModels.Error != null ? Mac.Attention : Mac.Secondary, wrap: true));
            if (ScriptRunner.UvPath == null) content.Children.Add(UvRow());
            void Again() { SpeechModels.Changed -= Again; if (current == "模型与 API") Show("模型与 API"); }
            SpeechModels.Changed += Again;
            if (!SpeechModels.Loading) _ = SpeechModels.Load();
            return;
        }
        var currentModel = BoardTranscription.Selected;
        var local = SpeechModels.IsLocal(currentModel);
        var choices = SpeechModels.Choices(currentModel).Select(m => (m.Id, SpeechModels.Title(m.Id) + (m.Local ? " · 本地" : " · API"))).ToList();
        Section(content, "语音识别", new[]
        {
            Row("语音识别模型", local ? "实时字幕和完整转写都在这台电脑上识别" : "录音时实时识别，结束后用同一个 API 复核整段录音",
                Popup(choices, currentModel, id => { BoardTranscription.Select(id); Show("模型与 API"); }), Icons.Waveform, 64),
        }, "从下一次录音或重新转写开始生效。识别失败时会保留录音和实时文字，不会自动换模型。");

        var rows = new List<UIElement>();
        var recommended = SpeechModels.Models.FirstOrDefault(m => m.Id == BoardTranscription.DefaultModel);
        if (recommended is { Installed: false })
        {
            var progress = Mac.Text("", Mac.Callout, color: Mac.Secondary);
            var download = Mac.Primary("下载", () => { }, "下载到 " + Paths.Models, 32);
            download.Click += async (_, _) => await Download(recommended.Id, download, progress);
            var more = Mac.Icon(Icons.EllipsisCircle, "选择要下载的模型", () => ManageModels(), 32, 18, Mac.Secondary, 16);
            more.Margin = new Thickness(0, 0, 8, 0);
            var row = (DockPanel)Row($"推荐下载 · {Size(recommended.SizeMb)}", $"下载后，标注改用 {recommended.Name}", Ui2Row(more, download), minHeight: 64);
            ((StackPanel)row.Children[^1]).Children.Add(progress);
            rows.Add(row);
        }
        var downloaded = SpeechModels.Models.Count(m => m.Role == "asr" && m.Local && m.Installed && m.RunsHere);
        rows.Add(Row("全部模型", $"已下载 {downloaded} 个", Mac.Push("管理模型…", ManageModels), Icons.Layers));
        Section(content, "本机", rows);

        var cloud = new List<UIElement>();
        foreach (var service in CloudService.All.Where(s => s.Configured))
        {
            var s = service;
            cloud.Add(Row(s.Name, "支持语音识别", Mac.Push("编辑…", () => EditService(s)), Icons.Cloud));
        }
        cloud.Add(Row("添加云端模型", null, Mac.Push("添加云端模型…", () => EditService(null)), Icons.PlusCircle, 48));
        Section(content, "云端模型", cloud);

        // more model options, folded
        var arrow = Mac.Symbol(Icons.ChevronRight, 12, Mac.Label, 2);
        var moreBox = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 10, 0, 0) };
        var toggle = new Button
        {
            Content = Ui2Row(arrow, Mac.Text("  更多模型选项", 15, FontWeights.SemiBold)), Focusable = false, Cursor = Cursors.Arrow, HorizontalAlignment = HorizontalAlignment.Left,
            Template = Mac.Template(Brushes.Transparent, null, 6), Padding = new Thickness(Mac.GroupGap, 4, 8, 4),
        };
        toggle.Click += (_, _) =>
        {
            var show = moreBox.Visibility != Visibility.Visible;
            moreBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            arrow.RenderTransformOrigin = new Point(0.5, 0.5);
            arrow.RenderTransform = new RotateTransform(show ? 90 : 0);
        };
        content.Children.Add(toggle);
        var moreRows = new List<UIElement>
        {
            ScriptRunner.UvPath is { } uv ? Row("运行环境", "uv：" + uv, null, Icons.Chip, 48) : UvRow(),
            Row("模型文件夹", Paths.Models, Mac.Push("打开", () => { Directory.CreateDirectory(Paths.Models); Paste.OpenFolder(Paths.Models); }), Icons.Folder, 48),
        };
        Section(moreBox, "", moreRows);
        content.Children.Add(moreBox);
    }

    static string Size(double mb) => mb >= 1024 ? $"{mb / 1024:0.0} GB" : $"{mb:0} MB";

    UIElement UvRow() => Row("缺少 uv", "运行转写脚本需要它；首次转写时会自动准备 Python 和依赖。", Mac.Primary("安装 uv", InstallUv, "从 astral.sh 下载官方安装脚本并安装到你的用户目录"), Icons.Chip);

    async Task Download(string id, Button button, TextBlock progress)
    {
        var label = (TextBlock)button.Content;
        if (downloads.TryGetValue(id, out var running)) { running.Cancel(); return; }
        var cts = new CancellationTokenSource();
        downloads[id] = cts;
        label.Text = "取消";
        progress.Text = "准备下载…";
        try
        {
            await ScriptRunner.CallAsync("transcribe.py", new[] { "setup", "--model-id", id, "--parent", Environment.ProcessId.ToString() }, TimeSpan.FromHours(3), cts.Token,
                line =>
                {
                    var m = Progress.Match(line);
                    if (!m.Success) return;
                    var done = double.Parse(m.Groups[1].Value); var total = double.Parse(m.Groups[2].Value);
                    Dispatcher.BeginInvoke(() => progress.Text = total > 0 ? $"已下载 {done:0} / {total:0} MB" : $"已下载 {done:0} MB");
                });
            progress.Text = "下载好了";
            Notices.Post(SpeechModels.Title(id) + " 下载好了");
            await SpeechModels.Load();
            if (current == "模型与 API") Show("模型与 API");
        }
        catch (ScriptFailure e)
        {
            progress.Text = e.Code == "cancelled" ? "已取消（下次会接着下载）" : "下载失败：" + BoardModelStatus.FailureText(e.Code);
        }
        finally
        {
            downloads.Remove(id);
            label.Text = "下载";
        }
    }

    /// 管理模型…: every local speech model this PC can run — what it is, its size, downloaded or a download button.
    void ManageModels()
    {
        var sheet = Sheet("全部模型", 520, 460);
        var stack = new StackPanel();
        var rows = new List<UIElement>();
        foreach (var m in SpeechModels.Models.Where(m => m.Role == "asr" && m.Local && m.RunsHere))
        {
            var progress = Mac.Text("", Mac.Callout, color: Mac.Secondary);
            UIElement control;
            if (m.Installed) control = Mac.Text("已下载", Mac.Callout, color: Mac.Secondary);
            else
            {
                var b = Mac.Push("下载", () => { }, "下载到 " + Paths.Models);
                var model = m;
                b.Click += async (_, _) => await Download(model.Id, b, progress);
                control = b;
            }
            var row = (DockPanel)Row(m.Name, (m.Installed ? "" : "需要下载约 ") + Size(m.SizeMb) + (m.Id == BoardTranscription.Selected ? " · 正在使用" : ""), control, minHeight: 52);
            ((StackPanel)row.Children[^1]).Children.Add(progress);
            rows.Add(row);
        }
        Section(stack, "本机模型", rows, "模型下载到 " + Paths.Models + "。下载后可以在「语音识别模型」里选用。");
        sheet.Body(stack, ("完成", true, () => sheet.Close()));
        sheet.ShowDialog();
        if (current == "模型与 API") Show("模型与 API");
    }

    /// 添加云端模型 / 编辑…: the service, its keys (kept with Windows data protection), 测试 sends one small request.
    void EditService(CloudService? existing)
    {
        var sheet = Sheet(existing == null ? "添加云端模型" : existing.Name, 480, 420);
        var service = existing ?? CloudService.All[0];
        var stack = new StackPanel();
        var fieldsHost = new StackPanel();
        var inputs = new Dictionary<string, Func<string>>();
        var test = Mac.Text("", Mac.Callout, color: Mac.Secondary, wrap: true);
        void Fields()
        {
            fieldsHost.Children.Clear();
            inputs.Clear();
            var rows = new List<UIElement>();
            foreach (var (variable, label, secret, placeholder) in service.Fields)
            {
                Control box = secret ? new PasswordBox { Password = Secrets.Get(variable) ?? "" } : new TextBox { Text = Secrets.Get(variable) ?? "" };
                box.Width = 240; box.Height = 30; box.Padding = new Thickness(8, 4, 8, 4); box.FontSize = Mac.Body; box.VerticalContentAlignment = VerticalAlignment.Center;
                box.BorderBrush = Mac.B(0x26, 0, 0, 0); box.Background = Brushes.White; box.ToolTip = placeholder;
                inputs[variable] = box is PasswordBox p ? () => p.Password : () => ((TextBox)box).Text;
                rows.Add(Row(label, null, box, minHeight: 44));
            }
            Section(fieldsHost, "", rows, service.Note);
        }
        if (existing == null)
        {
            Section(stack, "", new[] { Row("服务", null, Popup(CloudService.All.Select(s => (s.Id, s.Name)).ToList(), service.Id, id => { service = CloudService.All.First(s => s.Id == id); Fields(); })) });
        }
        Fields();
        stack.Children.Add(fieldsHost);
        stack.Children.Add(test);
        void Save() { foreach (var (k, v) in inputs) Secrets.Set(k, v()); }
        sheet.Body(stack,
            ("测试", false, async () =>
            {
                Save();
                test.Text = "正在测试…"; test.Foreground = Mac.Secondary;
                try
                {
                    var o = await ScriptRunner.CallAsync("transcribe.py", new[] { "check-cloud", "--model-id", service.Model }, TimeSpan.FromSeconds(60));
                    test.Text = "可以用：" + (Json.String(o["text"]) is { Length: > 0 } t ? "返回「" + t + "」" : "服务已应答") + (Json.Double(o["ms"]) is { } ms ? $"，{ms:0} ms" : "");
                    test.Foreground = Mac.Accent;
                }
                catch (ScriptFailure e) { test.Text = BoardModelStatus.FailureText(e.Code); test.Foreground = Mac.Attention; }
            }),
            ("取消", false, () => sheet.Close()),
            ("保存", true, () => { Save(); sheet.Close(); _ = SpeechModels.Load(); }));
        sheet.ShowDialog();
        if (current == "模型与 API") Show("模型与 API");
    }

    void InstallUv()
    {
        if (MacAlert.Show(this, "安装 uv", "将从 astral.sh 下载 uv 的官方安装脚本并运行，uv 会装到你的用户目录（~\\.local\\bin）。", new[] { "安装", "取消" }) != 0) return;
        try
        {
            var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy ByPass -Command \"irm https://astral.sh/uv/install.ps1 | iex; Read-Host '完成，按回车关闭'\"") { UseShellExecute = true });
            p?.WaitForExitAsync().ContinueWith(_ => Dispatcher.BeginInvoke(() => { _ = SpeechModels.Load(); Show("模型与 API"); }));
        }
        catch (Exception e) { MacAlert.Show(this, "无法启动安装", e.Message, new[] { "好" }); }
    }

    SheetWindow Sheet(string title, double width, double height) => new(this, title, width, height);

    // ── 快捷键 ──

    void Shortcuts(StackPanel content)
    {
        Section(content, PointTakenInfo.NameZh, new[] { Row("多页标注", null, KeyCaps(HotkeySettings.Start, false, k => { HotkeySettings.SetStart(k); HotkeysChanged?.Invoke(); }), minHeight: 44) });
        Section(content, "录音时", new[]
        {
            Row("自由画", "按住；不会拦下任何按键", KeyCaps(HotkeySettings.Hold(InkTool.free), true, k => HotkeySettings.SetHold(InkTool.free, k))),
            Row("画矩形", "按住；不会拦下任何按键", KeyCaps(HotkeySettings.Hold(InkTool.box), true, k => HotkeySettings.SetHold(InkTool.box, k))),
        }, "按住才生效，松开就回到正常操作。只用修饰键（Ctrl Alt Shift Win）时不会拦下任何按键。点右边的按键可以重新录。");
        var reset = Mac.Push("恢复默认", () =>
        {
            HotkeySettings.SetStart(null);
            HotkeySettings.SetHold(InkTool.free, null);
            HotkeySettings.SetHold(InkTool.box, null);
            HotkeysChanged?.Invoke();
            Show("快捷键");
        });
        reset.HorizontalAlignment = HorizontalAlignment.Right;
        reset.Margin = new Thickness(0, -12, Mac.GroupGap, 0);
        content.Children.Add(reset);
    }

    /// The shortcut as keycaps; clicked, it records the next combination (Esc keeps the old one).
    UIElement KeyCaps(KeyCombo combo, bool modifiersOnly, Action<KeyCombo> save)
    {
        var caps = new StackPanel { Orientation = Orientation.Horizontal };
        void Show(KeyCombo k)
        {
            caps.Children.Clear();
            foreach (var part in k.ToString().Split('+')) caps.Children.Add(Mac.KeyCap(part));
        }
        Show(combo);
        var b = new Button { Content = caps, Focusable = true, Cursor = Cursors.Arrow, Template = Mac.Template(Brushes.Transparent, null, 8), ToolTip = "点这里，然后按下新的组合键", FocusVisualStyle = null };
        KeyCombo? held = null;
        var recording = false;
        b.Click += (_, _) =>
        {
            recording = true;
            caps.Children.Clear();
            caps.Children.Add(new Border { Child = Mac.Text("请按组合键…", Mac.Callout, color: Mac.Accent), Padding = new Thickness(10, 5, 10, 5), CornerRadius = new CornerRadius(7), BorderBrush = Mac.Accent, BorderThickness = new Thickness(1.5) });
            b.Focus();
        };
        b.LostKeyboardFocus += (_, _) => { if (recording) { recording = false; Show(combo); } };
        b.PreviewKeyDown += (_, e) =>
        {
            if (!recording) return;
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key == Key.Escape) { recording = false; Show(combo); Keyboard.ClearFocus(); return; }
            var m = Keyboard.Modifiers;
            var isMod = key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin;
            var k = new KeyCombo(m.HasFlag(ModifierKeys.Control), m.HasFlag(ModifierKeys.Alt), m.HasFlag(ModifierKeys.Shift), m.HasFlag(ModifierKeys.Windows), isMod ? Key.None : key);
            if (k.ModifiersOnly) { if (modifiersOnly && (k.Ctrl || k.Alt || k.Win)) { held = k; Show(k); } return; }
            if (modifiersOnly || (!k.Ctrl && !k.Alt && !k.Win)) return;
            combo = k; recording = false; Show(k); save(k); Keyboard.ClearFocus();
        };
        b.PreviewKeyUp += (_, _) =>
        {
            if (!recording || !modifiersOnly || held is not { } h || Keyboard.Modifiers != ModifierKeys.None) return;
            combo = h; recording = false; Show(h); save(h); held = null; Keyboard.ClearFocus();
        };
        return b;
    }

    // ── 权限 ──

    void Permissions(StackPanel content)
    {
        var mic = MicrophoneAllowed();
        var missing = mic == false ? 1 : 0;
        if (missing > 0)
        {
            var warn = new StackPanel { Margin = new Thickness(Mac.GroupGap, -20, 0, 24) };
            warn.Children.Add(Mac.Text($"还有 {missing} 项必需权限没有开启", 15, FontWeights.SemiBold, Mac.Attention));
            warn.Children.Add(Mac.Text("点对应的「打开系统设置…」，允许后回到这里。", Mac.Callout, color: Mac.Secondary));
            content.Children.Add(warn);
        }
        UIElement Status(bool? ok, string? uri)
        {
            if (ok == true || uri == null)
            {
                var row = Ui2Row(Mac.Symbol(Icons.Checkmark, 12, Mac.Accent, 2.2), Mac.Text(" 已允许", Mac.Callout, color: Mac.Accent));
                return row;
            }
            return Mac.Push("打开系统设置…", () => Paste.Open(uri));
        }
        Section(content, "必需", new[]
        {
            Row("屏幕录制", "保存你标注的页面", Status(true, null), Icons.Photo),
            Row("麦克风", "录下你的讲解", Status(mic, "ms-settings:privacy-microphone"), Icons.Waveform),
            Row("辅助功能", "把结果粘贴到你选择的应用", Status(true, null), Icons.Hand),
        }, "在「设置 › 隐私和安全性」里改动后，这里会自动更新。Windows 的截图和粘贴不需要单独授权。",
        new Border { Child = Mac.Push("重新检查", () => Show("权限")), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, Mac.Inner, Mac.GroupGap, 0) });
    }

    static bool? MicrophoneAllowed()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone");
            if (k?.GetValue("Value") is string v)
            {
                if (v == "Deny") return false;
                using var desktop = k.OpenSubKey("NonPackaged");
                if (desktop?.GetValue("Value") is string dv) return dv != "Deny";
                return true;
            }
        }
        catch { }
        return null;
    }
}

/// The cloud speech services Settings can add (CloudSpeechSheet): their keys and what they need.
public sealed record CloudService(string Id, string Name, string Model, (string Variable, string Label, bool Secret, string Placeholder)[] Fields, string Note)
{
    public bool Configured => Fields.Where(f => f.Secret || f.Variable.EndsWith("APP_ID")).All(f => !string.IsNullOrEmpty(Secrets.Get(f.Variable)));

    public static readonly CloudService[] All =
    {
        new("volcengine", "豆包语音（火山引擎）", "volcengine-seedasr",
            new[] { ("VOLC_APP_ID", "App ID", false, "粘贴 App ID"), ("VOLC_ACCESS_TOKEN", "Access Token", true, "粘贴 Access Token") },
            "App ID 和 Access Token 用 Windows 数据保护加密保存在本机。"),
        new("dashscope", "阿里云百炼（Qwen3-ASR）", "qwen3-asr-flash",
            new[] { ("DASHSCOPE_API_KEY", "API Key", true, "粘贴 API Key") },
            "API Key 用 Windows 数据保护加密保存在本机。"),
        new("openai", "OpenAI 兼容服务", "openai-compatible",
            new[] { ("POINT_TAKEN_ASR_API_KEY", "API Key", true, "粘贴 API Key"), ("POINT_TAKEN_ASR_BASE_URL", "接口地址", false, "https://api.openai.com/v1"), ("POINT_TAKEN_ASR_MODEL", "模型", false, "whisper-1") },
            "API Key 用 Windows 数据保护加密保存在本机。"),
    };
}

/// A sheet (NSWindow.beginSheet): a small modal window over its parent with its buttons at the bottom right.
public sealed class SheetWindow : Window
{
    readonly DockPanel root = new() { Margin = new Thickness(24, 20, 24, 20) };
    public SheetWindow(Window owner, string title, double width, double height)
    {
        Owner = owner; Title = title; Width = width; MaxHeight = height + 200; SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false; FontFamily = Mac.Font;
        var head = Mac.Text(title, Mac.Title3, FontWeights.SemiBold);
        head.Margin = new Thickness(0, 0, 0, 16);
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);
        Content = new Border
        {
            Child = root, Background = Mac.B(0xFC, 0xFB, 0xFB, 0xFB), CornerRadius = new CornerRadius(16), BorderBrush = Mac.B(0x26, 0, 0, 0), BorderThickness = new Thickness(0.5),
            Margin = new Thickness(20), Effect = Mac.Shadow(30, 8, 0.25),
        };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        MouseLeftButtonDown += (_, e) => { if (e.OriginalSource is Border or StackPanel or DockPanel) try { DragMove(); } catch { } };
    }

    public void Body(UIElement content, params (string title, bool primary, Action run)[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var (title, primary, run) in buttons)
        {
            var b = primary ? Mac.Primary(title, run, height: 30, size: Mac.Callout) : Mac.Push(title, run, height: 30, size: Mac.Callout);
            b.Margin = new Thickness(8, 0, 0, 0);
            b.MinWidth = 76;
            row.Children.Add(b);
        }
        DockPanel.SetDock(row, Dock.Bottom);
        root.Children.Add(row);
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = MaxHeight - 160 });
    }
}
