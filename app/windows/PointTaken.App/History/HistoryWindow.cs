// History (历史记录) — BoardHistoryWindow (BoardHistory.swift): every record, newest first, grouped by day (今天 / 昨天 /
// 11月12日 周四). A row: the first page's picture (112 × 70; a waveform when there is none), the time and the
// recording's length, what was said (two lines), "2 张截图 · 有录音", and its actions — open, play / stop, transcribe
// again, show in Explorer, move to the Recycle Bin. 搜索说过的话 searches the whole text; 选择 picks several to delete.
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PointTaken.App.Capture;
using PointTaken.Core;

namespace PointTaken.App.History;

public sealed class HistoryWindow : MacWindow
{
    static HistoryWindow? open;
    sealed record Entry(string Directory, DateTime? Date, string Text, int Pages, bool HasAudio, double? Length, BitmapSource? Thumb);

    readonly StackPanel list = new() { Margin = new Thickness(Mac.GroupGap, 4, Mac.GroupGap, Mac.GroupGap) };
    readonly ScrollViewer scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    readonly TextBox search = new();
    readonly TextBlock titleText = Mac.Text("历史记录", Mac.Title2, FontWeights.SemiBold);
    readonly TextBlock subtitle = Mac.Text("", Mac.Subheadline, color: Mac.Secondary);
    readonly TextBlock empty = Mac.Text("还没有记录", 15, FontWeights.Medium, Mac.Secondary);
    readonly StackPanel selectTools = new() { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
    Button selectButton = null!, allButton = null!, trashButton = null!;
    readonly HashSet<string> transcribing = new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> picked = new(StringComparer.OrdinalIgnoreCase);
    List<Entry> entries = new();
    string? selectedDir;
    bool selecting;
    MediaPlayer? player;
    string? playingDir;
    System.Windows.Threading.DispatcherTimer? statusTimer;

    public static void ShowWindow()
    {
        if (open == null) { open = new HistoryWindow(); open.Closed += (_, _) => open = null; open.Show(); }
        if (open.WindowState == WindowState.Minimized) open.WindowState = WindowState.Normal;
        open.Activate();
        open.Reload();
    }

    HistoryWindow() : base(64)
    {
        Title = "历史记录";
        Width = 780; Height = 560; MinWidth = 560; MinHeight = 380;
        var dock = new DockPanel();
        var bar = new DockPanel { Height = CaptionHeight, Margin = new Thickness(Mac.Margin, 0, MacWindow.CaptionButtonsWidth + 8, 0), LastChildFill = false };
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(titleText);
        titles.Children.Add(subtitle);
        subtitle.Visibility = Visibility.Collapsed;
        bar.Children.Add(titles);

        // the search field: a grey capsule with a magnifier
        search.BorderThickness = new Thickness(0); search.Background = Brushes.Transparent; search.FontSize = Mac.Body; search.FontFamily = Mac.Font;
        search.VerticalContentAlignment = VerticalAlignment.Center; search.Foreground = Mac.Label;
        var placeholder = Mac.Text("搜索说过的话", Mac.Body, color: Mac.Tertiary);
        placeholder.IsHitTestVisible = false; placeholder.VerticalAlignment = VerticalAlignment.Center; placeholder.Margin = new Thickness(2, 0, 0, 0);
        search.TextChanged += (_, _) => { placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; Render(); };
        var field = new Grid(); field.Children.Add(search); field.Children.Add(placeholder);
        var magnifier = Mac.Symbol(Icons.Search, 15, Mac.Secondary, 1.6);
        magnifier.Margin = new Thickness(0, 0, 8, 0);
        var searchRow = new DockPanel { Margin = new Thickness(12, 0, 12, 0) };
        DockPanel.SetDock(magnifier, Dock.Left);
        searchRow.Children.Add(magnifier); searchRow.Children.Add(field);
        var searchBox = new Border { Child = searchRow, Width = 220, Height = 32, CornerRadius = new CornerRadius(16), Background = Mac.B(0x12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Interactive(search);
        selectButton = Interactive(Mac.Push("选择", ToggleSelecting, "选择多条记录，一起移到回收站", 32));
        allButton = Interactive(Mac.Push("全选", PickAll, "选中全部记录", 32));
        trashButton = Interactive(Mac.Push("移到回收站", TrashPicked, "把选中的记录移到回收站", 32));
        allButton.Margin = trashButton.Margin = new Thickness(8, 0, 0, 0);
        selectTools.Children.Add(allButton); selectTools.Children.Add(trashButton);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(searchBox);
        selectButton.Margin = new Thickness(10, 0, 0, 0);
        right.Children.Add(selectTools);
        right.Children.Add(selectButton);
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Insert(0, right);
        DockPanel.SetDock(bar, Dock.Top);
        dock.Children.Add(bar);
        var rule = Mac.Rule();
        DockPanel.SetDock(rule, Dock.Top);
        dock.Children.Add(rule);
        var host = new Grid();
        scroll.Content = list;
        host.Children.Add(scroll);
        empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center;
        host.Children.Add(empty);
        dock.Children.Add(host);
        Body = dock;
        PreviewKeyDown += OnKey;
        Closed += (_, _) => player?.Close();
    }

    // ── the records ──

    void Reload()
    {
        var root = Paths.Records;
        var dirs = Directory.Exists(root)
            ? Directory.GetDirectories(root).Where(d => !Path.GetFileName(d).StartsWith('.')).OrderByDescending(d => Path.GetFileName(d), StringComparer.Ordinal).ToList()
            : new List<string>();
        entries = dirs.Select(Load).ToList();
        picked.RemoveWhere(p => entries.All(e => !string.Equals(e.Directory, p, StringComparison.OrdinalIgnoreCase)));
        Render();
    }

    static Entry Load(string dir)
    {
        var rec = BoardRecord.Load(dir);
        var audio = Path.Combine(dir, "原始录音.wav");
        double? length = null;
        if (File.Exists(audio))
        {
            try { using var r = new NAudio.Wave.WaveFileReader(audio); length = r.TotalTime.TotalSeconds; } catch { }
        }
        var thumb = rec.Pages.Count > 0 ? rec.Thumb(rec.Pages[0]) : null;
        return new Entry(dir, rec.Date, rec.DeliveryTranscript, rec.Pages.Sum(p => p.Images.Count), File.Exists(audio), length, thumb);
    }

    static string Day(DateTime d)
    {
        var today = DateTime.Today;
        if (d.Date == today) return "今天";
        if (d.Date == today.AddDays(-1)) return "昨天";
        var zh = new CultureInfo("zh-CN");
        return d.ToString(d.Year == today.Year ? "M月d日 ddd" : "yyyy年M月d日 ddd", zh);
    }

    void Render()
    {
        list.Children.Clear();
        var query = search.Text.Trim();
        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var shown = entries.Where(e => terms.All(t => e.Text.Contains(t, StringComparison.OrdinalIgnoreCase))).ToList();
        string? lastDay = null;
        foreach (var e in shown)
        {
            var day = e.Date is { } d ? Day(d) : "更早";
            if (day != lastDay)
            {
                var header = Mac.Text(day, Mac.Callout, FontWeights.SemiBold, Mac.Secondary);
                header.Margin = new Thickness(Mac.Inner + 4, lastDay == null ? Mac.GroupGap : Mac.Margin, 0, Mac.Inner);
                list.Children.Add(header);
                lastDay = day;
            }
            list.Children.Add(Row(e));
        }
        empty.Text = entries.Count == 0 ? "还没有记录" : "没有找到";
        empty.Visibility = shown.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateSelecting();
    }

    UIElement Row(Entry e)
    {
        var dir = e.Directory;
        var busy = transcribing.Contains(dir);
        var picture = new Border
        {
            Width = 112, Height = 70, CornerRadius = new CornerRadius(Mac.ThumbRadius), BorderBrush = Mac.Separator, BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Center,
            Background = e.Thumb != null ? new ImageBrush(e.Thumb) { Stretch = Stretch.UniformToFill } : Mac.B(0x0A, 0, 0, 0), Margin = new Thickness(0, 0, Mac.GroupGap + 2, 0),
            Child = e.Thumb == null ? Mac.Symbol(Icons.Waveform, 24, Mac.Tertiary, 1.8) : null,
        };
        var title = Mac.Text(e.Date?.ToString("HH:mm") ?? Path.GetFileName(dir), Mac.Title3, FontWeights.SemiBold, digits: true);
        var length = Mac.Text(e.Length is { } l ? BoardSpeechBlock.Clock(l) : "", Mac.Body, color: Mac.Secondary, digits: true);
        length.Margin = new Thickness(Mac.Inner, 1, 0, 0);
        var preview = e.Text.Replace("\r", "").Replace("\n", " ").Trim();
        var said = Mac.Text(preview.Length == 0 ? "没有识别出文字" : preview, Mac.Body, color: preview.Length == 0 ? Mac.Tertiary : Mac.Label, wrap: true);
        said.MaxHeight = 2 * 20; said.Margin = new Thickness(0, 3, 0, 3);
        var facts = new List<string> { e.Pages > 0 ? $"{e.Pages} 张截图" : "没有截图", e.HasAudio ? "有录音" : "没有录音" };
        if (busy) facts.Add("正在重新转写…");
        var meta = Mac.Text(string.Join(" · ", facts), Mac.Subheadline, color: Mac.Tertiary);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui2Row(title, length));
        texts.Children.Add(said);
        texts.Children.Add(meta);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(Mac.GroupGap, 0, 0, 0) };
        var playing = playingDir == dir;
        foreach (var (title2, symbol, run, enabled) in new (string, Geometry, Action, bool)[]
        {
            ("打开", Icons.SquarePencil, () => OpenRecord(dir), !busy),
            (playing ? "停止播放" : "播放录音", playing ? Icons.StopCircle : Icons.PlayCircle, () => Play(dir), e.HasAudio),
            ("重新转写", Icons.Refresh, () => _ = Retranscribe(dir), e.HasAudio && !busy),
            ("在资源管理器中显示", Icons.Folder, () => Paste.OpenFolder(dir), true),
            ("移到回收站", Icons.Trash, () => Trash(dir), !busy),
        })
        {
            var b = Mac.Icon(symbol, title2, run, Mac.Hit + 4, 19, playing && title2 == "停止播放" ? Mac.Accent : Mac.Secondary, 8);
            b.IsEnabled = enabled && !selecting;
            b.Margin = new Thickness(2, 0, 2, 0);
            actions.Children.Add(b);
        }
        actions.Visibility = selecting ? Visibility.Collapsed : Visibility.Visible;
        var row = new DockPanel { Margin = new Thickness(Mac.Inner, Mac.Inner, Mac.Inner, Mac.Inner) };
        if (selecting)
        {
            var check = Mac.Check(picked.Contains(dir));
            check.Margin = new Thickness(0, 0, Mac.Inner, 0);
            check.Click += (_, _) => { if (check.IsChecked == true) picked.Add(dir); else picked.Remove(dir); UpdateSelecting(); };
            System.Windows.Automation.AutomationProperties.SetName(check, "选择这条记录");
            DockPanel.SetDock(check, Dock.Left);
            row.Children.Add(check);
        }
        DockPanel.SetDock(picture, Dock.Left); DockPanel.SetDock(actions, Dock.Right);
        row.Children.Add(picture); row.Children.Add(actions); row.Children.Add(texts);
        var holder = new Border { Child = row, CornerRadius = new CornerRadius(12), Background = dir == selectedDir ? Mac.B(0x14, 0, 0, 0) : Brushes.Transparent, Margin = new Thickness(0, 0, 0, 2) };
        holder.MouseEnter += (_, _) => { if (dir != selectedDir) holder.Background = Mac.B(0x08, 0, 0, 0); };
        holder.MouseLeave += (_, _) => { if (dir != selectedDir) holder.Background = Brushes.Transparent; };
        holder.MouseLeftButtonDown += (_, ev) =>
        {
            if (ev.OriginalSource is DependencyObject d && IsButton(d)) return;
            if (selecting) { if (!picked.Remove(dir)) picked.Add(dir); Render(); return; }
            if (ev.ClickCount == 2) { OpenRecord(dir); return; }
            selectedDir = dir;
            Render();
        };
        return holder;
    }

    static bool IsButton(DependencyObject? d)
    {
        while (d != null) { if (d is System.Windows.Controls.Primitives.ButtonBase) return true; d = d is Visual ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d); }
        return false;
    }

    static StackPanel Ui2Row(params UIElement[] items)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var i in items) s.Children.Add(i);
        return s;
    }

    void Status(string? text)
    {
        subtitle.Text = text ?? "";
        subtitle.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        statusTimer?.Stop();
        if (text == null) return;
        statusTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
        statusTimer.Tick += (_, _) => { statusTimer!.Stop(); Status(null); };
        statusTimer.Start();
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.OriginalSource is TextBox) return;
        if (e.Key == Key.Return && selectedDir != null) { OpenRecord(selectedDir); e.Handled = true; }
        else if (e.Key == Key.Delete && selectedDir != null) { Trash(selectedDir); e.Handled = true; }
        else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { search.Focus(); e.Handled = true; }
    }

    // ── actions ──

    void OpenRecord(string dir)
    {
        if (transcribing.Contains(dir)) { Status("正在重新转写，完成后再打开"); return; }
        BoardSession.Shared.OpenArchive(dir);
    }

    void Play(string dir)
    {
        var file = Path.Combine(dir, "原始录音.wav");
        if (playingDir == dir) { StopPlayback(); return; }
        if (!File.Exists(file)) { Status("这次记录没有保存录音"); return; }
        StopPlayback();
        player = new MediaPlayer();
        player.MediaFailed += (_, _) => { StopPlayback(); Status("录音无法播放"); };
        player.MediaOpened += (_, _) => Status("正在播放 · 再点一次停止");
        player.MediaEnded += (_, _) => StopPlayback();
        player.Open(new Uri(file));
        player.Play();
        playingDir = dir;
        Status("正在打开录音…");
        Render();
    }

    void StopPlayback()
    {
        player?.Stop(); player?.Close(); player = null;
        playingDir = null;
        Render();
    }

    async Task Retranscribe(string dir)
    {
        if (BoardSession.Shared.IsReviewing(dir)) { Status("请先关闭这次记录的检查窗口，再重新转写"); return; }
        if (!File.Exists(Path.Combine(dir, "原始录音.wav"))) { Status("这次记录没有原始录音"); return; }
        transcribing.Add(dir);
        Status("正在从原始录音重新转写；已有文字和交付稿会保留");
        Reload();
        var model = BoardTranscription.Selected;
        try
        {
            var (text, segments) = await BoardTranscription.TranscribeAsync(dir, model);
            if (text.Trim().Length == 0) throw new ScriptFailure("empty", "未识别出文字，原转写保持不变。");
            var full = Path.Combine(dir, "完整转写.txt");
            if (File.Exists(full)) File.Copy(full, Path.Combine(dir, $"转写备份-{Guid.NewGuid().ToString().ToUpperInvariant()}.txt"));
            AtomicFile.WriteText(full, text);
            var evidence = BoardEvidence.Load(dir) ?? new BoardEvidence();
            evidence.Speech = segments;
            evidence.SpeechTimingSource = segments.Count == 0 ? "unavailable" : "original-audio-file";
            evidence.Save(dir);
            var state = Json.ReadObject(Path.Combine(dir, "转写状态.json")) ?? new System.Text.Json.Nodes.JsonObject();
            state["state"] = "complete"; state["model"] = model; state["warning"] = "";
            state["updatedAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            AtomicFile.WriteJson(Path.Combine(dir, "转写状态.json"), Json.Sorted(state)!);
            BoardRecord.Load(dir).WriteNotes();
            Status("重新转写已保存；旧转写已备份，手动修改的交付稿保持不变");
        }
        catch (Exception e)
        {
            Status("重新转写未完成：" + (e is ScriptFailure { Code: not "empty" } sf ? BoardModelStatus.FailureText(sf.Code) : e.Message));
        }
        finally
        {
            transcribing.Remove(dir);
            Reload();
        }
    }

    void Trash(string dir)
    {
        if (transcribing.Contains(dir) || BoardSession.Shared.IsReviewing(dir)) { Status("请先等转写结束并关闭检查窗口，再删除"); return; }
        if (playingDir == dir) StopPlayback();
        try
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(dir, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            Status("已移到回收站，需要时可以在回收站里恢复");
        }
        catch (Exception e) { Status("删除失败：" + e.Message); }
        if (selectedDir == dir) selectedDir = null;
        Reload();
    }

    // ── 选择 ──

    void ToggleSelecting()
    {
        selecting = !selecting;
        picked.Clear();
        Render();
    }

    void UpdateSelecting()
    {
        ((TextBlock)selectButton.Content).Text = selecting ? "完成" : "选择";
        selectTools.Visibility = selecting ? Visibility.Visible : Visibility.Collapsed;
        titleText.Text = selecting ? (picked.Count == 0 ? "选择记录" : $"已选择 {picked.Count} 条") : "历史记录";
        ((TextBlock)trashButton.Content).Text = picked.Count == 0 ? "移到回收站" : $"移到回收站（{picked.Count}）";
        trashButton.IsEnabled = picked.Count > 0;
        var shown = entries.Count;
        ((TextBlock)allButton.Content).Text = shown > 0 && picked.Count == shown ? "取消全选" : "全选";
    }

    void PickAll()
    {
        if (picked.Count == entries.Count) picked.Clear();
        else foreach (var e in entries) picked.Add(e.Directory);
        Render();
    }

    void TrashPicked()
    {
        if (picked.Count == 0) return;
        if (MacAlert.Show(this, $"把 {picked.Count} 条记录移到回收站？", "录音、截图和文字会一起移走。需要时可以在回收站里恢复。", new[] { "移到回收站", "取消" }, destructive: true) != 0) return;
        int moved = 0, kept = 0;
        foreach (var dir in picked.ToList())
        {
            if (transcribing.Contains(dir) || BoardSession.Shared.IsReviewing(dir)) { kept++; continue; }
            try
            {
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(dir, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
                moved++;
            }
            catch { kept++; }
        }
        picked.Clear();
        selecting = false;
        Status(kept == 0 ? $"已把 {moved} 条记录移到回收站" : $"已移走 {moved} 条；{kept} 条正在使用或删除失败，保留了");
        Reload();
    }
}
