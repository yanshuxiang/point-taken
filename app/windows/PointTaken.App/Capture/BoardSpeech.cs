// Continuous audio and transcript, independent of page boundaries (BoardSpeech in Board.swift). The model chosen when
// recording starts does the live captions and the final pass over the whole recording; a failure never switches
// provider and never deletes the original audio or the live text. Writes 完整转写.txt, 实时转写.txt, 转写状态.json.
using System.Text.Json.Nodes;
using System.Windows.Threading;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public static class BoardTranscription
{
    /// The default on Windows: SenseVoice Small, local, runs on any CPU (needs a ~230 MB download once).
    public const string DefaultModel = "sensevoice-small";
    public static string Selected => Config.Shared.GetString("record.board.transcriptionModel") is { Length: > 0 } m && m != "board-apple-speech" ? m : DefaultModel;
    public static void Select(string id) => Config.Shared.Set("record.board.transcriptionModel", id);

    /// The 16 kHz WAV of a record when there is one (no ffmpeg needed), else the original.
    public static string AudioFor(string directory)
    {
        var fast = Path.Combine(directory, "实时语音", "full-16k.wav");
        return File.Exists(fast) && new FileInfo(fast).Length > 44 ? fast : Path.Combine(directory, "原始录音.wav");
    }

    /// The whole recording through `model` (History's 重新转写; the fallback final pass).
    public static async Task<(string Text, List<BoardSpeechSegment> Segments)> TranscribeAsync(string directory, string model, CancellationToken cancel = default)
    {
        var original = Path.Combine(directory, "原始录音.wav");
        BoardModelStatus.WriteReceipt(original, "requested", model);
        try
        {
            var o = await ScriptRunner.CallAsync("transcribe.py", new[] { "note", AudioFor(directory), "--model-id", model, "--segments", "--no-download" },
                                                 TimeSpan.FromSeconds(590), cancel);
            if (Json.String(o["model"]) != model || Json.String(o["text"]) is not { } text || o["segments"] is not JsonArray rows || Json.Bool(o["looped"]) == true)
            {
                BoardModelStatus.WriteReceipt(original, "failed", model, new JsonObject { ["code"] = "incomplete_response" });
                throw new ScriptFailure("incomplete_response", "模型返回不完整，已保留原始录音和实时文字。");
            }
            var segments = rows.OfType<JsonObject>().Select(r => new BoardSpeechSegment(Json.Double(r["start"]) ?? -1, Json.Double(r["end"]) ?? -1, Json.String(r["text"]) ?? "")).ToList();
            if (segments.Count != rows.Count || segments.Any(s => !s.Valid))
            {
                BoardModelStatus.WriteReceipt(original, "failed", model, new JsonObject { ["code"] = "incomplete_response" });
                throw new ScriptFailure("incomplete_response", "模型返回的转写时间不完整，已保留原始录音和实时文字。");
            }
            BoardModelStatus.WriteReceipt(original, "success", model, o);
            return (text, segments);
        }
        catch (ScriptFailure e) when (e.Code != "incomplete_response")
        {
            BoardModelStatus.WriteReceipt(original, "failed", model, new JsonObject { ["code"] = e.Code });
            throw new ScriptFailure(e.Code, BoardModelStatus.FailureText(e.Code));
        }
    }
}

public sealed class BoardSpeech
{
    public enum StatusKind { Starting, Listening, Off }
    public sealed record Status(StatusKind Kind, string Why = "", BoardPermission? Permission = null);

    public Status Current { get; private set; } = new(StatusKind.Off);
    public string? ArchiveWarning { get; private set; }
    public Action<string>? OnText;
    public Action<Status>? OnStatus;
    public Action<float>? OnLevel;

    readonly Dispatcher ui;
    BoardAudio? audio;
    LiveSpeech? live;
    LiveSpeech? finishedLive;
    BoardTranscript transcript = new();
    string? directory;
    string locale = "zh-CN";
    string finalModel = BoardTranscription.Selected;
    public string TranscriptionModel => finalModel;
    bool running, paused, finalizing, skipFileFinalization;
    readonly List<Action<string>> stopping = new();
    int generation;
    Guid liveID = Guid.NewGuid();
    double? savedAudioSeconds;
    DispatcherTimer? persistTimer;
    string? persistedTranscript;
    public bool FinalTranscriptVerified { get; private set; }
    public List<BoardSpeechSegment> TimedSegments { get; private set; } = new();
    bool audioArchiveIncomplete;
    public bool HasReliableAudioTimeline => !audioArchiveIncomplete && !(audio?.ArchiveIncomplete ?? false);
    public double? AudioSeconds => HasReliableAudioTimeline ? (audio?.Seconds ?? savedAudioSeconds) : null;
    public bool IsRecording => running && !paused && audio?.Running == true;
    public string PageText => transcript.PageText;
    public string FullText => transcript.Text;

    public BoardSpeech(Dispatcher ui) { this.ui = ui; }

    public void UpdateTiming(BoardEvidence evidence)
    {
        evidence.Speech = HasReliableAudioTimeline ? new(TimedSegments) : new();
        evidence.SpeechTimingSource = evidence.Speech.Count == 0 ? "unavailable" : "original-audio-file";
    }

    void Set(Status s) { Current = s; OnStatus?.Invoke(s); }

    void Changed() { Persist(); OnText?.Invoke(PageText); }

    void Persist(Action? completion = null)
    {
        if (directory is not { } dir) { completion?.Invoke(); return; }
        if (completion != null) { persistTimer?.Stop(); persistTimer = null; WriteTranscript(FullText, dir); completion(); return; }
        if (persistTimer != null) return;
        // throttled: partials reach the disk every 250 ms
        persistTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background, (s, _) =>
        {
            ((DispatcherTimer)s!).Stop(); persistTimer = null;
            if (directory == dir) WriteTranscript(FullText, dir);
        }, ui);
        persistTimer.Start();
    }

    void WriteTranscript(string text, string dir)
    {
        if (persistedTranscript == text) return;
        try { AtomicFile.WriteText(Path.Combine(dir, "完整转写.txt"), text); persistedTranscript = text; }
        catch (Exception e) { FinalTranscriptVerified = false; ArchiveWarning = "转写保存失败：" + e.Message; OnStatus?.Invoke(Current); }
    }

    public void Start(string locale, string directory)
    {
        this.directory = directory;
        this.locale = locale;
        liveID = Guid.NewGuid();
        finalModel = BoardTranscription.Selected;
        transcript = new BoardTranscript();
        persistedTranscript = null;
        audioArchiveIncomplete = false;
        TimedSegments = new(); savedAudioSeconds = null;
        finishedLive = null; paused = false; finalizing = false; skipFileFinalization = false;
        FinalTranscriptVerified = false; ArchiveWarning = null;
        Persist();
        PersistState("recording");
        Set(new Status(StatusKind.Starting));
        BeginAudio();
    }

    void BeginAudio()
    {
        var dir = directory!;
        LiveSpeech? source = null;
        try
        {
            source = new LiveSpeech(finalModel, dir, ui);
            var id = liveID;
            source.OnText = (words, final) => { if (id != liveID) return; transcript.Update(words, final); Changed(); };
            source.OnReady = () => { if (id == liveID && running && !paused) Set(new Status(StatusKind.Listening)); };
            source.OnFailure = message => { if (id == liveID) Set(new Status(StatusKind.Off, BoardModelStatus.Name(finalModel) + " 实时字幕失败：" + message + "。不影响录音。")); };
            source.OnFinalizing = () => { if (id != liveID) return; PersistState("finalizing"); Set(new Status(StatusKind.Off, "正在根据原始录音整理完整转写…")); };
        }
        catch { Set(new Status(StatusKind.Off, "所选模型实时字幕无法启动，不影响录音。")); source = null; }

        var a = new BoardAudio();
        a.OnLevel = l => ui.BeginInvoke(() => OnLevel?.Invoke(l));
        a.OnWriteWarning = w => ui.BeginInvoke(() =>
        {
            audioArchiveIncomplete = true; FinalTranscriptVerified = false; ArchiveWarning = w;
            Set(new Status(StatusKind.Off, "录音保存异常；实时文字仍保留，请检查存储空间"));
        });
        a.OnFailure = w => ui.BeginInvoke(() =>
        {
            audioArchiveIncomplete = true; ArchiveWarning = w;
            Set(new Status(StatusKind.Off, w));
        });
        try
        {
            a.Start(Path.Combine(dir, "原始录音.wav"), source?.PcmPath);
        }
        catch (Exception e)
        {
            a.Dispose();
            source?.Cancel();
            var denied = e is UnauthorizedAccessException || e.HResult == unchecked((int)0x80070005);
            Set(denied ? new Status(StatusKind.Off, "麦克风未获准，不能保存录音", BoardPermission.Microphone)
                       : new Status(StatusKind.Off, e is System.Runtime.InteropServices.COMException { HResult: unchecked((int)0x80070490) } ? "没找到可用的麦克风" : "麦克风打不开：" + e.Message));
            return;
        }
        audio = a;
        running = true;
        if (source != null) { live = source; Set(new Status(StatusKind.Starting)); source.Start(); }
    }

    public void SetPaused(bool value)
    {
        paused = value;
        audio?.SetPaused(value);
        live?.SetPaused(value);
        if (value) Set(new Status(StatusKind.Off, "已暂停"));
        else if (running)
            Set(live?.Healthy == true ? new Status(StatusKind.Listening) : new Status(StatusKind.Off, "所选模型实时字幕不可用，不影响录音。"));
    }

    public string Cut() { var w = transcript.MarkPage(); Changed(); return w; }

    string KeptNote => (FullText.Trim().Length == 0 ? "原始录音已保存" : "原始录音和实时文字已保存") + "，可在「历史记录」里重新转写。";

    /// Quitting saves audio and live text without waiting for the long final pass (History can redo it).
    public void StopForQuit(Action<string> done)
    {
        skipFileFinalization = true;
        if (!audioArchiveIncomplete) ArchiveWarning = "原始录音已保存；完整转写没做，可从历史重新转写。";
        liveID = Guid.NewGuid();
        live?.Cancel(); live = null;
        if (finalizing) { generation++; stopping.Add(done); FinishFinalization(); }
        else Stop(done);
    }

    /// Stops the microphone at once, then the captions' tail and the final pass.
    public void Stop(Action<string> done)
    {
        stopping.Add(done);
        if (stopping.Count != 1) return;
        running = false;
        var a = audio;
        Task.Run(() =>
        {
            a?.Stop();
            ui.BeginInvoke(() =>
            {
                savedAudioSeconds = a?.Seconds;
                if (a?.ArchiveIncomplete == true) audioArchiveIncomplete = true;
                audio = null;
                FinishAudioStop();
            });
        });
    }

    void FinishAudioStop()
    {
        if (live is { } l)
        {
            l.Finish(() => { live = null; finishedLive = l; CompleteStop(); });
            return;
        }
        CompleteStop();
    }

    void CompleteStop()
    {
        if (finalizing) return;
        finalizing = true;
        generation++;
        transcript.Commit();
        Changed();
        if (directory is not { } dir) { FinishFinalization(); return; }
        var wav = Path.Combine(dir, "原始录音.wav");
        if (!File.Exists(wav)) { FinishFinalization(); return; }
        try { AtomicFile.WriteText(Path.Combine(dir, "实时转写.txt"), FullText); }
        catch (Exception e) { ArchiveWarning = "实时转写备份失败：" + e.Message; }
        if (skipFileFinalization) { FinishFinalization(); return; }
        if (audioArchiveIncomplete) { FinalTranscriptVerified = false; FinishFinalization(); return; }
        if (finishedLive is { FileFinalizationAttempted: true } fl)
        {
            if (fl.FinalFileTranscript is { } file)
            {
                ApplyFileTranscript(file.Text, file.Segments);
                BoardModelStatus.WriteReceipt(wav, FinalTranscriptVerified ? "success" : "failed", finalModel, fl.ReceiptMetadata);
            }
            else ArchiveWarning = "完整转写未完成。" + KeptNote;
            FinishFinalization();
            return;
        }
        if (finishedLive is { FinalQuality: true } q && q.Model == finalModel && FullText.Trim().Length > 0)
        {
            TimedSegments = new(q.Segments);
            var receipt = q.ReceiptMetadata; receipt["model"] = finalModel;
            BoardModelStatus.WriteReceipt(wav, "success", finalModel, receipt);
            FinalTranscriptVerified = true;
            FinishFinalization();
            return;
        }
        PersistState("finalizing");
        Set(new Status(StatusKind.Off, "正在根据原始录音整理完整转写…"));
        var gen = generation;
        var model = finalModel;
        _ = Task.Run(async () =>
        {
            string? error = null; (string, List<BoardSpeechSegment>)? result = null;
            try { result = await BoardTranscription.TranscribeAsync(dir, model); }
            catch (ScriptFailure e) { error = e.Message; }
            catch (Exception e) { error = e.Message; }
            await ui.BeginInvoke(() =>
            {
                if (!finalizing || generation != gen) return;
                if (result is { } r) ApplyFileTranscript(r.Item1, r.Item2);
                else ArchiveWarning = "完整转写失败：" + error + "。" + KeptNote;
                FinishFinalization();
            });
        });
    }

    void ApplyFileTranscript(string text, List<BoardSpeechSegment> segments)
    {
        if (text.Trim().Length == 0 && FullText.Length > 0) { ArchiveWarning = "完整转写没有返回文字。" + KeptNote; return; }
        transcript.ReplaceWithFileTranscript(text);
        TimedSegments = segments.Where(s => s.Valid).ToList();
        FinalTranscriptVerified = true;
    }

    void PersistState(string state)
    {
        if (directory is not { } dir) return;
        var fields = new JsonObject
        {
            ["state"] = state, ["locale"] = locale, ["model"] = finalModel, ["liveModel"] = finalModel,
            ["updatedAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            ["warning"] = ArchiveWarning ?? "", ["audioTimelineAvailable"] = HasReliableAudioTimeline,
        };
        try { AtomicFile.WriteJson(Path.Combine(dir, "转写状态.json"), Json.Sorted(fields)!); }
        catch (Exception e) { ArchiveWarning = "转写状态保存失败：" + e.Message; }
    }

    void FinishFinalization()
    {
        OnText?.Invoke(PageText);
        Persist(() =>
        {
            PersistState(FinalTranscriptVerified ? "complete" : "incomplete");
            finalizing = false;
            Set(new Status(StatusKind.Off));
            var callbacks = stopping.ToList();
            stopping.Clear();
            foreach (var c in callbacks) c(PageText);
        });
    }
}

public enum BoardPermission { Microphone, Screen }
