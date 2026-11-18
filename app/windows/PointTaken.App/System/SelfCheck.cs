// Checks that run the real code paths without a microphone, the user's clipboard or their records:
//   PointTaken.exe --self-check <out dir>      capture exclusion, marked PNGs, record files, capsule / review renders
//   PointTaken.exe --live-probe <wav> <out dir>  the selected model's live captions + final pass on a given WAV
// Each prints one JSON line per check and exits 0 when all passed.
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NAudio.Wave;
using PointTaken.App.Capture;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App;

public static class SelfCheck
{
    static int failures;

    static void Report(string name, bool ok, string detail = "")
    {
        if (!ok) failures++;
        Console.WriteLine(new JsonObject { ["check"] = name, ["ok"] = ok, ["detail"] = detail }.ToJsonString(Json.Pretty).Replace("\n", "").Replace("  ", " "));
    }

    public static int Run(string outDir, Application app)
    {
        Directory.CreateDirectory(outDir);
        BoardSession.Install(app.Dispatcher);
        try { CaptureExclusion(outDir); } catch (Exception e) { Report("capture_exclusion", false, e.Message); }
        try { RecordFiles(outDir); } catch (Exception e) { Report("record_files", false, e.ToString()); }
        try { CapsuleRender(outDir); } catch (Exception e) { Report("capsule_render", false, e.ToString()); }
        try { ReviewRender(outDir); } catch (Exception e) { Report("review_render", false, e.ToString()); }
        try { Microphone(); } catch (Exception e) { Report("microphone", false, e.Message); }
        Report("uv", ScriptRunner.UvPath != null, ScriptRunner.UvPath ?? "missing");
        Report("scripts", File.Exists(Path.Combine(Paths.Scripts, "board_live.py")), Paths.Scripts);
        return failures == 0 ? 0 : 1;
    }

    /// A window of ours over the screen must not be in the capture; a plain one must.
    static void CaptureExclusion(string outDir)
    {
        var m = MonitorInfo.All().First();
        Window Make(bool exclude, System.Windows.Media.Color c)
        {
            var w = new Window
            {
                WindowStyle = WindowStyle.None, ShowInTaskbar = false, Topmost = true, Background = new SolidColorBrush(c), ShowActivated = false,
                Left = m.X / m.Scale + 40, Top = m.Y / m.Scale + 40, Width = 200, Height = 200, ResizeMode = ResizeMode.NoResize,
            };
            w.SourceInitialized += (_, _) => { if (exclude) Native.MakePanel(new System.Windows.Interop.WindowInteropHelper(w).Handle, clickThrough: true); };
            w.Show();
            return w;
        }
        var plain = Make(false, Colors.Lime);
        Pump(400);
        var withPlain = GdiCapture.Grab(m);
        plain.Close();
        var ours = Make(true, System.Windows.Media.Color.FromRgb(255, 0, 255));
        Pump(400);
        var withOurs = GdiCapture.Grab(m);
        ours.Close();
        int Px(Pixels p, int x, int y) { var i = y * p.Stride + x * 4; return p.Data[i] | p.Data[i + 1] << 8 | p.Data[i + 2] << 16; }
        var cx = (int)(140 * m.Scale); var cy = (int)(140 * m.Scale);
        var plainSeen = Px(withPlain, cx, cy) == 0x00FF00;
        var oursHidden = Px(withOurs, cx, cy) != 0xFF00FF;
        MarkRenderer.WritePng(withOurs, Path.Combine(outDir, "capture-excluded.png"));
        Report("capture_plain_window_visible", plainSeen, $"pixel #{Px(withPlain, cx, cy):X6}");
        Report("capture_own_window_excluded", oursHidden, $"pixel #{Px(withOurs, cx, cy):X6}");
        Report("fingerprint", withOurs.Fingerprint().Values.Length == 64 * 40, $"{withOurs.Width}x{withOurs.Height}");
    }

    static void Pump(int ms)
    {
        var frame = new System.Windows.Threading.DispatcherFrame();
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        t.Tick += (_, _) => { t.Stop(); frame.Continue = false; };
        t.Start();
        System.Windows.Threading.Dispatcher.PushFrame(frame);
    }

    static Pixels Sample(int w, int h)
    {
        var data = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var i = (y * w + x) * 4;
                data[i] = (byte)(240 - y * 60 / h); data[i + 1] = (byte)(245 - x * 40 / w); data[i + 2] = 250; data[i + 3] = 255;
                if (y > h / 4 && y < h / 4 + 40 && x > w / 5 && x < w / 5 + 300) { data[i] = 220; data[i + 1] = 120; data[i + 2] = 40; }
            }
        return new Pixels(w, h, data);
    }

    static BoardRecord SampleRecord(string outDir)
    {
        var dir = Path.Combine(outDir, "record", DateTime.Now.ToString(Paths.SessionStampFormat));
        Directory.CreateDirectory(dir);
        var image = Sample(1600, 1000);
        var original = Path.Combine(dir, "原图-A.png");
        var marked = Path.Combine(dir, "标注-A.png");
        MarkRenderer.WritePng(image, original);
        var box = InkFit.Points(new InkShape.Box(new InkRect(300, 230, 420, 120))).Select(p => new[] { p.X / 1600, p.Y / 1000 }).ToList();
        var ell = InkFit.Points(new InkShape.Ellipse(new InkRect(900, 500, 300, 200))).Select(p => new[] { p.X / 1600, p.Y / 1000 }).ToList();
        var evidence = new BoardEvidence { SpeechTimingSource = "original-audio-file" };
        evidence.Speech.Add(new BoardSpeechSegment(0.5, 3.2, "先说一下背景：这是给老人用的。"));
        evidence.Speech.Add(new BoardSpeechSegment(4.0, 6.5, "这个按钮太小了，改大一点。"));
        evidence.Speech.Add(new BoardSpeechSegment(8.0, 10.0, "这里换成圆角。"));
        evidence.Visits.Add(new BoardVisit { PageID = "P1", App = "Microsoft Edge", Title = "设置 - 示例", Start = new(0, 0), End = new(12, 12) });
        var page = new BoardPage
        {
            Images = { marked }, Original = original, Marks = { box, ell }, LineWidth = 5, SourceFrames = { original }, ContextIDs = { "P1" },
            MarkEvidence = { new BoardMarkEvidence(1, new(4.2, 4.2), new(5.0, 5.0)), new BoardMarkEvidence(2, new(8.1, 8.1), new(9.0, 9.0)) }, CapturedAt = 4,
        };
        BoardFileWriter.Marked(image, page, marked);
        var rec = new BoardRecord(dir) { Pages = { page }, Evidence = evidence, OriginalTranscript = string.Join(" ", evidence.Speech.Select(s => s.Text)) };
        File.WriteAllText(Path.Combine(dir, "完整转写.txt"), rec.OriginalTranscript);
        rec.WriteNotes();
        BoardFileWriter.Flush();
        return rec;
    }

    static void RecordFiles(string outDir)
    {
        var rec = SampleRecord(outDir);
        foreach (var f in new[] { "页面.json", "说明.md", "时间线.json", "标注-A.png" })
            Report("record_file " + f, File.Exists(Path.Combine(rec.Directory, f)));
        var back = BoardRecord.Load(rec.Directory);
        Report("record_reload", back.Pages.Count == 1 && back.Pages[0].Marks.Count == 2 && back.Evidence?.Speech.Count == 3);
        var notes = File.ReadAllText(Path.Combine(rec.Directory, "说明.md"));
        Report("handoff_mark_quote", notes.Contains("| 标记 1 |") && notes.Contains("这个按钮太小了"), notes.Length + " chars");
        var bundle = back.Export();
        Report("export_folder", File.Exists(Path.Combine(bundle.Directory, "图1.png")) && bundle.Text.Contains(Path.Combine(bundle.Directory, "图1.png")), bundle.Directory);
    }

    static void Render(FrameworkElement e, string path, double w, double h)
    {
        e.Measure(new Size(w, h));
        e.Arrange(new Rect(0, 0, w, h));
        e.UpdateLayout();
        var bmp = new RenderTargetBitmap((int)w, (int)h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(e);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var f = File.Create(path);
        enc.Save(f);
    }

    static void CapsuleRender(string outDir)
    {
        var capsule = BoardSession.Shared.Capsule;
        capsule.PreviewSource = () => (Array.Empty<BoardPage>(), "", Array.Empty<System.Windows.Media.Imaging.BitmapSource?>());
        capsule.BeginSession();
        capsule.SetControls(new List<Capsule.Control>
        {
            new("自由画", Icons.Scribble, "", () => { }, On: true), new("矩形", Icons.Rectangle, "", () => { }), new("圆圈", Icons.Circle, "", () => { }),
            new("撤销", Icons.Undo, "", () => { }), new("暂停", Icons.PauseFill, "", () => { }, Filled: true), new("完成", null, "", () => { }, Primary: true),
        });
        capsule.SetTray(new System.Windows.Media.Imaging.BitmapSource?[] { null, null });
        capsule.Update(2, "这个邮件通知的开关默认应该关掉，不然大家会被邮件刷屏。保存按钮太小了", Capsule.Mic.Live, new[] { new Capsule.Warning("麦克风未获准，不能保存录音", BoardPermission.Microphone) }, "Ctrl");
        capsule.Tip("第 1 页已存，切到下一页接着标");
        Pump(500);
        var content = (FrameworkElement)capsule.Content;
        var path = Path.Combine(outDir, "capsule.png");
        Render(content, path, Math.Max(200, content.ActualWidth), Math.Max(60, content.ActualHeight));
        Report("capsule_render", File.Exists(path), $"{content.ActualWidth:0}x{content.ActualHeight:0} at ({capsule.Left:0},{capsule.Top:0})");
        Report("capsule_never_focused", !capsule.IsActive && (Native.GetWindowLong(new System.Windows.Interop.WindowInteropHelper(capsule).Handle, Native.GWL_EXSTYLE) & Native.WS_EX_NOACTIVATE) != 0);
        capsule.Hide();
    }

    static void ReviewRender(string outDir)
    {
        var rec = SampleRecord(outDir);
        var window = new Review.ReviewWindow(BoardRecord.Load(rec.Directory), finalizing: false, warning: null) { ShowActivated = false, Left = -4000, Top = 0 };
        window.Show();
        Pump(800);
        var content = (FrameworkElement)window.Content;
        var path = Path.Combine(outDir, "review.png");
        Render(content, path, content.ActualWidth, content.ActualHeight);
        Report("review_render", File.Exists(path), $"{content.ActualWidth:0}x{content.ActualHeight:0}");
        window.Close();
        Report("review_saved_on_close", File.Exists(Path.Combine(rec.Directory, "页面.json")));
    }

    static void Microphone()
    {
        var device = new NAudio.CoreAudioApi.MMDeviceEnumerator().GetDefaultAudioEndpoint(NAudio.CoreAudioApi.DataFlow.Capture, NAudio.CoreAudioApi.Role.Console);
        Report("microphone", true, device.FriendlyName + " · " + device.AudioClient.MixFormat);
    }


    /// Renders every window and the tray menu to PNGs (for comparing with the macOS screenshots).
    public static int RenderUi(string outDir, Application app)
    {
        Directory.CreateDirectory(outDir);
        BoardSession.Install(app.Dispatcher);
        var load = SpeechModels.Load();
        var frame = new System.Windows.Threading.DispatcherFrame();
        load.ContinueWith(_ => frame.Continue = false);
        System.Windows.Threading.Dispatcher.PushFrame(frame);
        Pump(300);
        void Shot(Window w, string name)
        {
            w.ShowActivated = false;
            w.Left = -6000; w.Top = 0;
            if (!w.IsVisible) w.Show();
            Pump(700);
            var c = (FrameworkElement)w.Content;
            Render(c, Path.Combine(outDir, name + ".png"), c.ActualWidth, c.ActualHeight);
            Report("render " + name, true, $"{c.ActualWidth:0}x{c.ActualHeight:0}");
        }
        History.HistoryWindow.ShowWindow();
        foreach (Window w in app.Windows) if (w is History.HistoryWindow h) { Shot(h, "history"); h.Close(); break; }
        foreach (var pane in new[] { "通用", "模型与 API", "快捷键", "权限" })
        {
            Settings.SettingsWindow.ShowWindow(pane);
            foreach (Window w in app.Windows) if (w is Settings.SettingsWindow s) { Shot(s, "settings-" + pane.Replace(" ", "")); }
        }
        foreach (Window w in app.Windows.Cast<Window>().ToList()) w.Close();
        // the tray menu, laid out on its own
        var menuApp = (TrayApp?)null;
        var menu = TrayMenu.Create();
        menu.Items.Add(TrayMenu.Item("开始标注", () => { }, "Alt+N"));
        menu.Items.Add(new System.Windows.Controls.Separator());
        var model = TrayMenu.Item("识别模型：" + SpeechModels.Title(Capture.BoardTranscription.Selected), null);
        model.IsEnabled = true;
        model.Items.Add(TrayMenu.Item("x", () => { }));
        menu.Items.Add(model);
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(TrayMenu.Item("历史记录…", () => { }));
        menu.Items.Add(TrayMenu.Item("设置…", () => { }, "Ctrl+,"));
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(TrayMenu.Item("退出", () => { }, "Ctrl+Q"));
        var host = new Window { WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = System.Windows.Media.Brushes.Transparent, Left = -6000, Top = 0, Width = 10, Height = 10, ShowActivated = false };
        host.Show();
        menu.PlacementTarget = host; menu.IsOpen = true;
        Pump(500);
        ((System.Windows.Controls.MenuItem)menu.Items[2]).IsSubmenuOpen = false;
        Render(menu, Path.Combine(outDir, "tray-menu.png"), Math.Max(10, menu.ActualWidth), Math.Max(10, menu.ActualHeight));
        Report("render tray-menu", true, $"{menu.ActualWidth:0}x{menu.ActualHeight:0}");
        menu.IsOpen = false; host.Close();
        _ = menuApp;
        return failures == 0 ? 0 : 1;
    }

    // ── the live bridge ──

    public static int LiveProbe(string wav, string outDir, Application app)
    {
        Directory.CreateDirectory(outDir);
        var dir = Path.Combine(outDir, "live-" + DateTime.Now.ToString("HHmmss"));
        Directory.CreateDirectory(dir);
        File.Copy(wav, Path.Combine(dir, "原始录音.wav"));
        var model = BoardTranscription.Selected;
        var live = new LiveSpeech(model, dir, app.Dispatcher);
        var updates = 0; string last = ""; string? error = null;
        live.OnText = (w, final) => { if (w.Length > 0) { updates++; last = w; Console.WriteLine(new JsonObject { ["event"] = final ? "segment" : "partial", ["text"] = w }.ToJsonString(Json.Pretty).Replace("\n", "")); } };
        live.OnFailure = e => error = e;
        live.Start();
        // pace the 16 kHz samples in real time, 100 ms at a time, like the microphone would
        var pcm = Pcm16k(wav);
        var done = false;
        var exit = 1;
        Task.Run(async () =>
        {
            using (var f = new FileStream(live.PcmPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
            {
                for (var i = 0; i < pcm.Length; i += 3200)
                {
                    f.Write(pcm, i, Math.Min(3200, pcm.Length - i)); f.Flush();
                    await Task.Delay(100);
                }
                f.Write(new byte[32000], 0, 32000);
            }
            await Task.Delay(500);
            await app.Dispatcher.BeginInvoke(() => live.Finish(() =>
            {
                var ok = updates > 0 && error == null;
                Console.WriteLine(new JsonObject
                {
                    ["event"] = "board_live_probe", ["ok"] = ok, ["model"] = model, ["updates"] = updates, ["last"] = last, ["error"] = error,
                    ["final"] = live.FinalFileTranscript?.Text, ["final_segments"] = live.FinalFileTranscript?.Segments.Count, ["dir"] = dir,
                }.ToJsonString(Json.Pretty).Replace("\n", ""));
                exit = ok ? 0 : 1; done = true;
            }));
        });
        var frame = new System.Windows.Threading.DispatcherFrame();
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        var started = DateTime.Now;
        timer.Tick += (_, _) => { if (done || (DateTime.Now - started).TotalMinutes > 12) { timer.Stop(); frame.Continue = false; } };
        timer.Start();
        System.Windows.Threading.Dispatcher.PushFrame(frame);
        return exit;
    }

    static byte[] Pcm16k(string wav)
    {
        using var reader = new WaveFileReader(wav);
        var samples = reader.ToSampleProvider();
        var mono = samples.WaveFormat.Channels > 1 ? new NAudio.Wave.SampleProviders.StereoToMonoSampleProvider(samples) : samples;
        var resampled = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(mono, 16000);
        var buf = new float[16000];
        using var ms = new MemoryStream();
        int n;
        while ((n = resampled.Read(buf, 0, buf.Length)) > 0)
            for (var i = 0; i < n; i++) { var v = (short)Math.Clamp((int)(buf[i] * 32767), short.MinValue, short.MaxValue); ms.WriteByte((byte)v); ms.WriteByte((byte)(v >> 8)); }
        return ms.ToArray();
    }
}
