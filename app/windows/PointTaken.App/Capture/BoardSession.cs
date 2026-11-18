// The multi-page annotation session (BoardSession in Board.swift): start → mark up and talk while using other apps →
// pages are kept as you mark them (a stroke on a new screen starts a new page; leaving a screen keeps what was said
// over it, unchecked) → 完成 opens the review while the whole recording is transcribed → paste into the app you pick,
// never sent. Originals, editable marks, the continuous audio and the full transcript are kept apart.
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class BoardSession
{
    public static BoardSession Shared { get; private set; } = null!;
    public static void Install(Dispatcher ui) => Shared = new BoardSession(ui);

    readonly Dispatcher ui;
    public bool Active { get; private set; }
    public bool Paused { get; private set; }
    bool busy;
    public bool Finalizing { get; private set; }
    public string? CurrentTranscriptionModel => Active || Finalizing ? speech.TranscriptionModel : null;
    BoardRecord? record;
    List<BoardPage> Pages => record?.Pages ?? new List<BoardPage>();
    readonly List<InkOverlay> overlays = new();
    public Capsule Capsule { get; } = new();
    readonly BoardSpeech speech;
    BoardTimeline? timeline;
    BoardCaptureClock clock = new(Uptime.Now);
    BoardMoment? strokeStart;
    ScreenFrame? strokeFrame;
    int nextMarkNumber = 1;
    DispatcherTimer? ticker, slowTicker;
    InkTool? selectedTool;
    bool penOn;
    string? penDisplay;
    readonly HoldKeys holdKeys = new();
    readonly ScreenFeed screenFeed;
    /// the page being marked while its screen is still up (the macOS app's live scroll at offset 0)
    (int index, ScreenFrame frame)? live;
    Review.ReviewWindow? review;
    string? screenWarning;
    readonly Dictionary<string, (BoardFrameFingerprint print, int w, int h)> originalPrints = new(StringComparer.OrdinalIgnoreCase);
    int wordsAtScreen, pagesAtScreen;
    List<BoardSpeechSegment>? copiedSegments;

    public event Action? StateChanged;
    public Func<int?>? SuspendStartHotkey;
    public Action? ResumeStartHotkey;

    BoardMoment Moment => new(clock.Elapsed(Uptime.Now), speech.AudioSeconds);

    BoardSession(Dispatcher ui)
    {
        this.ui = ui;
        speech = new BoardSpeech(ui);
        screenFeed = new ScreenFeed(ui);
        Capsule.PreviewSource = () => (Pages, speech.FullText, Pages.Select(p => record?.Thumb(p)).ToList());
        Capsule.OnOpen = () => { if (Active) Capsule.TogglePreview(); };
        Capsule.OnPermission = OpenPermission;
        BoardFileWriter.OnFailure = text => ui.BeginInvoke(() => Notices.Post(text));
    }

    public static string Locale => Config.Shared.GetString("record.board.locale") ?? "zh-CN";

    public static void OpenPermission(BoardPermission p) =>
        Paste.Open(p == BoardPermission.Microphone ? "ms-settings:privacy-microphone" : "ms-settings:privacy");

    // ── start / stop ──

    public void Hotkey() { if (!Active) Start(); }

    public void Start()
    {
        if (review != null) { review.ShowAndActivate(); return; }
        if (Finalizing) { OpenReview(); return; }
        if (Active) return;
        var dir = Path.Combine(Paths.Records, DateTime.Now.ToString(Paths.SessionStampFormat));
        try { System.IO.Directory.CreateDirectory(dir); }
        catch (Exception e)
        {
            Notices.Post("无法创建记录文件夹：" + e.Message);
            Capsule.Message("无法创建记录文件夹：" + e.Message, Mac.Warn, Icons.Triangle, 8);
            return;
        }
        Active = true; Paused = false; busy = false;
        record = new BoardRecord(dir);
        timeline = new BoardTimeline();
        record.Evidence = timeline.Evidence;
        clock = new BoardCaptureClock(Uptime.Now);
        nextMarkNumber = 1; strokeStart = null;
        screenWarning = null;
        originalPrints.Clear();
        live = null;
        selectedTool = null;
        ResumeStartHotkey?.Invoke();   // released while recording
        SuspendStartHotkey?.Invoke();

        holdKeys.Hold = tool =>
        {
            if (!Active || Paused || busy) return (false, null);
            var before = selectedTool;
            SelectTool(tool);
            return (true, before);
        };
        holdKeys.Release = before => { if (Active) SelectTool(before); };
        holdKeys.Tap = tool => { if (Active && !Paused && !busy) SelectTool(tool); };
        holdKeys.Start();

        foreach (var m in MonitorInfo.All())
        {
            var overlay = new InkOverlay(m);
            overlay.OnStrokeBegan = () => { strokeStart = Moment; strokeFrame = screenFeed.Current; };
            overlay.OnStrokeCompleted = () => StrokeCompleted(overlay);
            overlay.ShowPanel();
            overlays.Add(overlay);
        }

        ticker = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(50) };
        ticker.Tick += (_, _) => SyncPen();
        ticker.Start();
        slowTicker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        slowTicker.Tick += (_, _) => SlowTick();
        slowTicker.Start();

        Capsule.BeginSession();
        ConfigureControls();
        speech.OnText = _ => { review?.UpdateTranscript(speech.FullText); Refresh(); };
        speech.OnStatus = _ => Refresh();
        speech.OnLevel = l => Capsule.SetLevel(l);
        Refresh();
        wordsAtScreen = 0; pagesAtScreen = 0; copiedSegments = null;
        speech.Start(Locale, dir);

        screenFeed.OnObserve = (frame, boundary) =>
        {
            if (!Active || Paused) return;
            timeline?.Observe(frame.Scene, frame.AppName, frame.Title, frame.Fingerprint, boundary, Moment);
            if (boundary) WriteNotes();
        };
        screenFeed.OnInput = (kind, dy, at) =>
        {
            if (!Active || Paused || timeline == null) return;
            timeline.Evidence.Inputs ??= new();
            lock (timeline.Evidence.Inputs) BoardScrollInput.Append(new BoardInput { Kind = kind, At = clock.Elapsed(at), Dy = dy }, timeline.Evidence.Inputs);
        };
        screenFeed.OnKeyDown = vk => holdKeys.KeyPressed(vk);
        screenFeed.OnTransition = (old, next, scrolling) => Transition(old, next, scrolling);
        screenFeed.OnLeave = frame => { AutoPage(frame); KeepSpoken(frame, speech.FullText.Length); };
        screenFeed.OnFailure = error => { screenWarning = "自动留页不可用：" + error; Refresh(); };
        screenFeed.Start();
        StateChanged?.Invoke();
    }

    void End()
    {
        timeline?.Close(Moment);
        Active = false; busy = false;
        ticker?.Stop(); ticker = null;
        slowTicker?.Stop(); slowTicker = null;
        screenFeed.Stop();
        penOn = false; selectedTool = null;
        holdKeys.Stop();
        foreach (var o in overlays) o.Close();
        overlays.Clear();
        ResumeStartHotkey?.Invoke();
        StateChanged?.Invoke();
    }

    public void Cancel()
    {
        if (!Active || busy) return;
        KeepPage(always: false, then: _ => { }, finishing: true);
        Finalizing = true;
        var dir = record?.Directory;
        speech.Stop(_ =>
        {
            Finalizing = false;
            WriteNotes();
            var message = speech.ArchiveWarning is { } w ? "已停止，未粘贴。" + w
                : speech.FinalTranscriptVerified ? "已停止，录音和完整转写已保留，未粘贴" : "已停止，已保留可用录音与文字，未粘贴";
            BoardFileWriter.WhenFinished(() => Notices.Post(BoardFileWriter.Warning(dir) is { } fw ? "已停止，未粘贴。" + fw : message), ui);
            StateChanged?.Invoke();
        });
        End();
        Capsule.Hide();
    }

    /// Normal quit: audio and the live transcript are flushed before the app exits.
    public void PrepareForQuit(Action done)
    {
        review?.CloseSaving();
        if (Finalizing) { speech.StopForQuit(_ => BoardFileWriter.WhenFinished(done, ui)); return; }
        if (!Active) { BoardFileWriter.WhenFinished(done, ui); return; }
        KeepPage(always: false, then: _ => { }, finishing: true);
        speech.StopForQuit(_ => { WriteNotes(); End(); BoardFileWriter.WhenFinished(done, ui); });
    }

    // ── tools and the pen ──

    void SelectTool(InkTool? tool)
    {
        selectedTool = tool;
        SyncPen();
        ConfigureControls();
    }

    /// The capsule's one row (Board.swift capsuleControls): the three shapes (click one to keep drawing with it, again
    /// to go back to normal operation), undo, pause, 完成.
    void ConfigureControls()
    {
        Capsule.Control Shape(InkTool tool, System.Windows.Media.Geometry symbol, string name)
        {
            var key = HotkeySettings.DefaultHold.ContainsKey(tool) ? HotkeySettings.Hold(tool).ToString() : null;
            var tip = key != null ? $"{name}：点一下一直保持，再点取消；按住 {key} 临时画，松开回到正常操作" : $"{name}：点一下一直保持，再点取消";
            return new Capsule.Control(name, symbol, tip, () =>
            {
                holdKeys.ReleaseHold();
                if (selectedTool == tool) SelectTool(null); else { SelectTool(tool); KeyTip(tool); }
            }, On: selectedTool == tool);
        }
        Capsule.SetControls(new List<Capsule.Control>
        {
            Shape(InkTool.free, Icons.Scribble, "自由画"),
            Shape(InkTool.box, Icons.Rectangle, "矩形"),
            Shape(InkTool.ellipse, Icons.Circle, "圆圈"),
            new("撤销", Icons.Undo, "撤销上一笔", Undo),
            new(Paused ? "继续" : "暂停", Paused ? Icons.PlayFill : Icons.PauseFill, Paused ? "继续录音" : "暂停录音（暂停期间不录音、不截图）", TogglePause, On: Paused, Filled: true),
            new("完成", null, "结束录音，打开检查窗口", Finish, Primary: true),
        });
    }

    /// A tool turned on by clicking: a short tip that it can be drawn with its key held, the first few times per tool.
    void KeyTip(InkTool tool)
    {
        if (!HotkeySettings.DefaultHold.ContainsKey(tool)) return;
        var seen = "record.board.key_tip." + tool;
        var shown = Config.Shared.GetInt(seen) ?? 0;
        if (shown >= 5) return;
        Config.Shared.Set(seen, System.Text.Json.Nodes.JsonValue.Create(shown + 1));
        var key = HotkeySettings.Hold(tool).ToString();
        Capsule.Tip(tool == InkTool.box ? $"下次可以直接按住 {key} 画矩形，松开就停" : $"下次可以直接按住 {key} 画，松开就停");
    }

    void TogglePause()
    {
        if (!Active || busy) return;
        if (!Paused) { SealPage(); timeline?.Close(Moment); clock.Pause(Uptime.Now); }
        else clock.Resume(Uptime.Now);
        Paused = !Paused;
        SelectTool(null);
        speech.SetPaused(Paused);
        screenFeed.Paused = Paused;
        if (!Paused) screenFeed.ResetBoundary();
        ConfigureControls(); Refresh();
    }

    void SyncPen()
    {
        if (!Active) return;
        var on = !busy && !Paused && screenFeed.Current != null && review == null && selectedTool != null;
        if (selectedTool is { } t) foreach (var o in overlays) o.Tool = t;
        if (overlays.Any(o => o.Drawing)) return;
        var display = screenFeed.Current?.DisplayKey;
        if (on == penOn && display == penDisplay) return;
        penOn = on; penDisplay = display;
        // a display's pen waits for that display's clean frame: a stroke always has pixels to keep
        foreach (var o in overlays) o.SetPen(on && o.Display.Key == display);
    }

    void SlowTick()
    {
        if (!Active || Paused) return;
        if (screenFeed.Current == null)
        {
            var c = WindowContext.Front();
            timeline?.Observe(c.Scene, c.App, c.Title, null, false, Moment);
        }
        WriteEvidence();
        Capsule.Topmost = true;
    }

    void Undo()
    {
        if (live is { } l && l.index < Pages.Count)
        {
            var page = Pages[l.index];
            if (page.Marks.Count == 0) return;
            page.Marks.RemoveAt(page.Marks.Count - 1);
            if (page.MarkEvidence.Count > 0) page.MarkEvidence.RemoveAt(page.MarkEvidence.Count - 1);
            var overlay = overlays.FirstOrDefault(o => o.Display.Key == l.frame.DisplayKey);
            overlay?.Load(page.Marks);
            if (page.Marks.Count == 0 && !page.ManuallySaved)
            {
                Pages.RemoveAt(l.index);
                live = null;
                overlay?.Clear();
                var retained = BoardRecord.Files(Pages).ToHashSet(StringComparer.OrdinalIgnoreCase);
                BoardFileWriter.Remove(page.AllFiles.Where(f => !retained.Contains(f)));
            }
            else Redraw(page, l.frame.Image);
            UpdateTray(); WriteNotes();
            return;
        }
        overlays.OrderByDescending(o => o.LastStrokeAt).FirstOrDefault()?.Undo();
    }

    void NextPage()
    {
        if (!Active || busy || Paused || review != null) return;
        KeepPage(always: true, kept =>
        {
            busy = false;
            if (kept)
            {
                SelectTool(null);
                overlays.FirstOrDefault(o => o.Display.Key == screenFeed.Current?.DisplayKey)?.Flash();
                Capsule.Toast($"第 {Pages.Count} 页已存，切到下一页接着标");
            }
            else Capsule.Toast("这一页还没画也没说，先标一下再点“存页”");
            Refresh();
        });
    }

    // ── pages ──

    void StrokeCompleted(InkOverlay overlay)
    {
        holdKeys.StrokeDrawn();
        try
        {
            var frame = strokeFrame ?? screenFeed.Current;
            if (!Active || Paused || frame == null || frame.DisplayKey != overlay.Display.Key || overlay.NormalizedStrokes.Count == 0) return;
            var stroke = overlay.NormalizedStrokes[^1];
            var evidence = new BoardMarkEvidence(nextMarkNumber++, strokeStart ?? Moment, Moment);
            Place(stroke, evidence, frame, overlay);
        }
        finally
        {
            strokeStart = null; strokeFrame = null;
            if (!holdKeys.Holding) SelectTool(null);
        }
    }

    bool SamePicture(BoardFrameFingerprint a, BoardFrameFingerprint b, double within = 0.002) => screenFeed.Motion.Distance(a, b) < within;

    /// Files a stroke: onto the page being marked when the screen still shows it, else as a new page. A stroke on a
    /// part that moves by itself (a carousel) must sit on the picture it was drawn on.
    void Place(List<double[]> stroke, BoardMarkEvidence evidence, ScreenFrame frame, InkOverlay? overlay)
    {
        var motion = screenFeed.Motion;
        var sameViewport = live is not { } lv || (lv.frame.DisplayKey == frame.DisplayKey && SamePicture(lv.frame.Fingerprint, frame.Fingerprint));
        var onChangedMovingPart = live is { } l0 && sameViewport && motion.Touches(stroke) && motion.MovingDistance(l0.frame.Fingerprint, frame.Fingerprint) > 0.01;
        var startsNewPage = !sameViewport;
        if (onChangedMovingPart && live is { } l1)
        {
            var earlier = Pages[l1.index].Marks.Any(m => motion.Touches(m));
            startsNewPage = earlier || !RefreshPicture(l1.index, frame);
        }
        timeline?.Observe(frame.Scene, frame.AppName, frame.Title, frame.Fingerprint, startsNewPage, Moment);
        timeline?.Anchor(frame.Fingerprint);
        if (!startsNewPage && live is { } l && l.index < Pages.Count)
        {
            var page = Pages[l.index];
            page.Marks.Add(stroke);
            page.MarkEvidence.Add(evidence);
            Redraw(page, live.Value.frame.Image);
            WriteNotes();
        }
        else
        {
            var marks = new List<List<double[]>>();
            var metadata = new List<BoardMarkEvidence>();
            if (live is { } old && sameViewport && !onChangedMovingPart && old.index < Pages.Count)
            {
                marks.AddRange(Pages[old.index].Marks);
                metadata.AddRange(Pages[old.index].MarkEvidence);
            }
            marks.Add(stroke); metadata.Add(evidence);
            var index = Save(frame.Image, frame, marks, included: true, metadata, capturedAt: clock.Elapsed(frame.CapturedAt), fresh: onChangedMovingPart);
            if (index is { } i)
            {
                SealPage(clearInk: false);
                live = (i, frame);
                overlay?.Load(Pages[i].Marks);
            }
        }
        wordsAtScreen = speech.FullText.Length; pagesAtScreen = Pages.Count;
        UpdateTray();
    }

    /// The page being marked takes `frame` as its picture (a carousel turned): marks redrawn on the new picture.
    bool RefreshPicture(int index, ScreenFrame frame)
    {
        var page = Pages[index];
        if (page.Original is not { } original || page.Components.Count > 0 || live is not { } l || l.frame.Image.Width != frame.Image.Width || l.frame.Image.Height != frame.Image.Height) return false;
        BoardFileWriter.Png(frame.Image, original);
        originalPrints[original] = (frame.Fingerprint, frame.Image.Width, frame.Image.Height);
        live = (index, frame);
        Redraw(page, frame.Image);
        return true;
    }

    void Redraw(BoardPage page, Pixels image)
    {
        if (page.Images.Count == 0) return;
        BoardFileWriter.Marked(image, page, page.Images[0]);
        using var thumb = MarkRenderer.Render(image, page.Marks, page.MarkEvidence, page.LineWidth, 96);
        record?.SetThumb(page, MarkRenderer.ToSource(thumb));
    }

    /// The page on screen is done with: its ink leaves the overlay (unless the caller reloads it).
    void SealPage(bool clearInk = true)
    {
        if (live is { } l && clearInk) overlays.Where(o => o.Display.Key == l.frame.DisplayKey).ToList().ForEach(o => o.Clear());
        live = null;
        WriteNotes();
    }

    bool Transition(ScreenFrame old, ScreenFrame next, bool scrolling)
    {
        if (!Active || busy || Paused || live is not { } l || l.index >= Pages.Count) return false;
        if (overlays.Any(o => o.Drawing)) return true;
        // a carousel or a video turning over is the page moving by itself, not navigation
        if (old.Scene == next.Scene && old.Title == next.Title && !scrolling && SamePicture(old.Fingerprint, next.Fingerprint, 0.045)) return false;
        if (old.Scene == next.Scene && old.Title == next.Title && l.frame.Fingerprint.Distance(next.Fingerprint) < 0.001) return true;
        // navigation, or a scroll: stale ink must never sit over new content (the long picture is joined in the review)
        screenFeed.Motion.Reset();
        SealPage(); SelectTool(null);
        timeline?.Observe(next.Scene, next.AppName, next.Title, next.Fingerprint, true, Moment);
        wordsAtScreen = speech.FullText.Length; pagesAtScreen = Pages.Count;
        WriteNotes();
        return true;
    }

    /// A recovery boundary: strokes not yet kept (normally each stroke is kept as it ends).
    void AutoPage(ScreenFrame frame)
    {
        if (!Active || busy || Paused || review != null || live != null) return;
        var overlay = overlays.FirstOrDefault(o => o.Display.Key == frame.DisplayKey);
        if (overlay == null) return;
        if (overlay.Drawing) { overlay.End(); return; }
        if (overlay.NormalizedStrokes.Count == 0) return;
        var marks = overlay.NormalizedStrokes.Select(m => m.ToList()).ToList();
        var evidence = marks.Select(_ => new BoardMarkEvidence(nextMarkNumber++)).ToList();
        if (Save(frame.Image, frame, marks, true, evidence, capturedAt: clock.Elapsed(frame.CapturedAt)) != null)
        {
            overlay.Clear(); SelectTool(null); Refresh();
        }
    }

    /// A screen that was talked over but not marked: kept as a page, unchecked (it goes to the AI only if checked in
    /// the review), so the words said there have their picture.
    void KeepSpoken(ScreenFrame frame, int wordCount)
    {
        try
        {
            var unsaved = live is not { } l || l.frame.DisplayKey != frame.DisplayKey || !SamePicture(l.frame.Fingerprint, frame.Fingerprint);
            if (!Active || Paused || busy || !unsaved || Pages.Count != pagesAtScreen || wordCount - wordsAtScreen < 4) return;
            timeline?.Observe(frame.Scene, frame.AppName, frame.Title, frame.Fingerprint, live != null, Moment);
            Save(frame.Image, frame, new(), included: false, new(), manual: true, capturedAt: clock.Elapsed(frame.CapturedAt));
        }
        finally { wordsAtScreen = wordCount; pagesAtScreen = Pages.Count; }
    }

    /// Freezes pixels and strokes before anything waits, so later navigation can't pair old ink with new pixels.
    void KeepPage(bool always, Action<bool> then, bool finishing = false)
    {
        foreach (var o in overlays.Where(o => o.Drawing)) o.End();
        if (live is { } l && l.index < Pages.Count && (screenFeed.Current is not { } cur || (cur.DisplayKey == l.frame.DisplayKey && SamePicture(cur.Fingerprint, l.frame.Fingerprint))))
        {
            if (always) Pages[l.index].ManuallySaved = true;
            SealPage(); screenFeed.ResetBoundary(); then(true); return;
        }
        if (!always)
        {
            if (finishing && screenFeed.Current is { } f) KeepSpoken(f, speech.FullText.Length);
            SealPage(); then(false); return;
        }
        busy = true;
        if (screenFeed.Current is not { } frame) { WriteNotes(); then(false); return; }
        timeline?.Observe(frame.Scene, frame.AppName, frame.Title, frame.Fingerprint, false, Moment);
        var marks = live is { } lv && lv.index < Pages.Count ? Pages[lv.index].Marks.ToList() : new();
        var evidence = live is { } le && le.index < Pages.Count ? Pages[le.index].MarkEvidence.ToList() : new();
        var kept = Save(frame.Image, frame, marks, true, evidence, manual: true, capturedAt: clock.Elapsed(frame.CapturedAt)) != null;
        if (kept) { SealPage(); screenFeed.ResetBoundary(); }
        then(kept);
    }

    (BoardFrameFingerprint print, int w, int h)? OriginalPrint(string path)
    {
        if (originalPrints.TryGetValue(path, out var p)) return p;
        BoardFileWriter.Flush();
        if (Pixels.Load(path) is not { } image) return null;
        var v = (image.Fingerprint(), image.Width, image.Height);
        originalPrints[path] = v;
        return v;
    }

    int? Save(Pixels image, ScreenFrame frame, List<List<double[]>> marks, bool included, List<BoardMarkEvidence> evidence,
              bool manual = false, double? capturedAt = null, bool fresh = false)
    {
        if (record is not { } rec || (marks.Count == 0 && !manual)) return null;
        var contextIDs = timeline?.CurrentID is { } id ? new List<string> { id } : new List<string>();
        var print = frame.Fingerprint;
        var motion = screenFeed.Motion;
        // a confidently matched unchanged screen seen again: one picture, all visits
        if (!fresh)
        {
            for (var i = 0; i < Pages.Count; i++)
            {
                var page = Pages[i];
                if (contextIDs.Count == 0 || !page.ContextIDs.SequenceEqual(contextIDs) || page.Scene != frame.Scene || page.Original is not { } url) continue;
                if (OriginalPrint(url) is not { } old || old.w != image.Width || old.h != image.Height) continue;
                if (motion.Distance(old.print, print) >= 0.002) continue;
                if (marks.Any(m => motion.Touches(m)) && motion.MovingDistance(old.print, print) > 0.01) continue;
                if (page.Images.Count == 0) continue;
                var known = page.MarkEvidence.Select(e => e.Number).ToHashSet();
                var before = page.Marks.Count;
                foreach (var (mark, item) in marks.Zip(evidence))
                    if (!known.Contains(item.Number)) { page.Marks.Add(mark); page.MarkEvidence.Add(item); }
                page.Included = BoardPageInclusion.After(before, page.Marks.Count, page.Included);
                page.ManuallySaved |= manual;
                Redraw(page, image);
                UpdateTray(); WriteNotes();
                return i;
            }
        }
        var uid = Guid.NewGuid().ToString().ToUpperInvariant();
        var original = Path.Combine(rec.Directory, $"原图-{uid}.png");
        var output = Path.Combine(rec.Directory, $"标注-{uid}.png");
        // the line in image pixels: 4 points on a display of this width
        var width = Math.Max(2, image.Width / Math.Max(1.0, frame.Display.Width / frame.Display.Scale) * 4);
        var newPage = new BoardPage
        {
            Images = new() { output }, Original = original, Marks = marks, Included = included, Scene = frame.Scene, LineWidth = width,
            SourceFrames = new() { original }, ContextIDs = contextIDs, MarkEvidence = evidence, ManuallySaved = manual, CapturedAt = capturedAt,
        };
        BoardFileWriter.Png(image, original);
        originalPrints[original] = (print, image.Width, image.Height);
        Pages.Add(newPage);
        Redraw(newPage, image);
        UpdateTray(); WriteNotes();
        return Pages.Count - 1;
    }

    void UpdateTray() => Capsule.SetTray(Pages.Select(p => record?.Thumb(p)).ToList());

    void WriteEvidence()
    {
        if (record is not { } rec || timeline == null) return;
        if (Active && !Paused) timeline.Touch(Moment);
        if (!speech.TimedSegments.SequenceEqual(copiedSegments ?? new()) || !speech.HasReliableAudioTimeline)
        {
            copiedSegments = speech.TimedSegments.ToList();
            speech.UpdateTiming(timeline.Evidence);
        }
        var evidence = timeline.Evidence.Clone();
        var dir = rec.Directory;
        BoardFileWriter.Enqueue(Path.Combine(dir, BoardEvidence.Filename), () => { try { evidence.Save(dir); return true; } catch { return false; } });
    }

    void WriteNotes()
    {
        if (record is not { } rec) return;
        if (timeline != null)
        {
            if (Active && !Paused) timeline.Touch(Moment);
            speech.UpdateTiming(timeline.Evidence);
            rec.Evidence = timeline.Evidence;
        }
        if (rec.ReviewedTranscript == null || !Active) rec.OriginalTranscript = speech.FullText.Length > 0 || !File.Exists(Path.Combine(rec.Directory, "完整转写.txt")) ? speech.FullText : rec.OriginalTranscript;
        rec.WriteNotes();
    }

    // ── finish → review → paste ──

    public void Finish()
    {
        if (!Active || busy) return;
        KeepPage(always: false, finishing: true, then: _ =>
        {
            Finalizing = true;
            var rec = record;
            speech.Stop(_ =>
            {
                Finalizing = false;
                if (rec != null) rec.OriginalTranscript = speech.FullText;
                WriteNotes();
                var warnings = new[] { speech.ArchiveWarning, BoardFileWriter.Warning(rec?.Directory) }.Where(w => w != null).ToList();
                review?.FinishTranscript(rec?.DeliveryTranscript ?? "", rec?.Evidence, warnings.Count == 0 ? null : string.Join("\n", warnings));
                StateChanged?.Invoke();
            });
            End();
            Capsule.Hide();
            WriteNotes();
            OpenReview(allowEmpty: true);
        });
    }

    public void OpenReview(bool allowEmpty = false)
    {
        if (review != null) { review.ShowAndActivate(); return; }
        if (Active) { Capsule.TogglePreview(); return; }
        if (record is not { } rec) return;
        BoardFileWriter.WhenFinished(() =>
        {
            if (review != null) return;
            if (!allowEmpty && !Finalizing && rec.Pages.Count == 0 && rec.DeliveryTranscript.Length == 0) return;
            var warnings = new[] { rec.ReviewedTranscript == null ? speech.ArchiveWarning : null, BoardFileWriter.Warning(rec.Directory) }.Where(w => w != null).ToList();
            var window = new Review.ReviewWindow(rec, finalizing: Finalizing, warning: warnings.Count == 0 ? null : string.Join("\n", warnings));
            review = window;
            window.Closed += (_, _) => { review = null; StateChanged?.Invoke(); };
            window.ShowAndActivate();
        }, ui);
    }

    public bool IsReviewing(string directory) =>
        string.Equals(record?.Directory, directory, StringComparison.OrdinalIgnoreCase) && (review != null || Active || Finalizing);

    /// History → 打开: the review window for a saved record.
    public void OpenArchive(string directory)
    {
        if (IsReviewing(directory)) { if (review != null) review.ShowAndActivate(); else if (Active) Capsule.TogglePreview(); return; }
        var rec = BoardRecord.Load(directory);
        var window = new Review.ReviewWindow(rec, finalizing: false, warning: null);
        window.ShowAndActivate();
    }

    // ── the capsule ──

    void Refresh()
    {
        if (!Active) return;
        var warnings = new List<Capsule.Warning>();
        if (speech.Current is { Kind: BoardSpeech.StatusKind.Off, Why.Length: > 0 } off) warnings.Add(new(off.Why, off.Permission));
        if (screenWarning is { } sw) warnings.Add(new(sw, null));
        if (speech.ArchiveWarning is { } aw) warnings.Add(new(aw, null));
        var mic = speech.IsRecording ? Capsule.Mic.Live : speech.Current.Kind switch
        {
            BoardSpeech.StatusKind.Listening => Capsule.Mic.Live,
            BoardSpeech.StatusKind.Starting => Capsule.Mic.Starting,
            _ => Capsule.Mic.Off,
        };
        if (speech.Current.Kind == BoardSpeech.StatusKind.Off && speech.IsRecording) mic = Capsule.Mic.Live;
        Capsule.Update(Pages.Count + 1, Paused ? "已暂停 · 语音与画面都已停止记录" : speech.PageText, Paused ? Capsule.Mic.Off : mic, warnings, HotkeySettings.Hold(InkTool.free).ToString());
    }
}
