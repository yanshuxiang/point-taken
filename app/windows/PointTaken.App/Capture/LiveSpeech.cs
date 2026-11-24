// The selected model's live captions and its final pass over the whole recording: board_live.py reads the 16 kHz PCM
// the audio writer appends (实时语音/audio.pcm), watches the `paused` / `stop` marker files, and prints JSON lines.
// No fallback to another provider. Port of BoardLiveSpeech.swift.
using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class LiveSpeech
{
    public string Model { get; }
    public string Directory { get; }
    public Action<string, bool>? OnText;
    public Action? OnReady;
    public Action<string>? OnFailure;
    public Action? OnFinalizing;

    readonly string audioUrl;
    readonly string finalWav;
    readonly Dispatcher ui;
    Process? process;
    bool cancelled, terminal, failed, receivedText;
    Action? completion;
    readonly JsonObject lastMetadata = new();
    public bool Healthy => !failed && !terminal;
    public List<BoardSpeechSegment> Segments { get; } = new();
    public bool CompletedCleanly { get; private set; }
    public bool FileFinalizationAttempted { get; private set; }
    public (string Text, List<BoardSpeechSegment> Segments)? FinalFileTranscript { get; private set; }
    /// Doubao's live session re-recognises every sentence (two-pass): its text is final quality.
    public bool FinalQuality => CompletedCleanly && !cancelled && (Json.String(lastMetadata["service_model"]) ?? "").Contains("two-pass");
    public JsonObject ReceiptMetadata => (JsonObject)lastMetadata.DeepClone();

    public string PcmPath => Path.Combine(Directory, "audio.pcm");

    /// the spoken language passed to the model (zh, en…; null: the model tells)
    readonly string? language;

    public LiveSpeech(string model, string sessionDirectory, Dispatcher ui, string? language = null)
    {
        Model = model;
        this.language = language;
        this.ui = ui;
        Directory = Path.Combine(sessionDirectory, "实时语音");
        audioUrl = Path.Combine(sessionDirectory, "原始录音.wav");
        finalWav = Path.Combine(Directory, "full-16k.wav");
        System.IO.Directory.CreateDirectory(Directory);
        File.WriteAllBytes(PcmPath, Array.Empty<byte>());
        TryDelete(Path.Combine(Directory, "stop"));
        TryDelete(Path.Combine(Directory, "paused"));
    }

    static void TryDelete(string p) { try { File.Delete(p); } catch { } }

    public void Start()
    {
        BoardModelStatus.WriteReceipt(audioUrl, "connecting", Model, filename: "实时调用.json");
        Task.Run(() =>
        {
            try
            {
                Process p;
                lock (this)
                {
                    if (cancelled) return;
                    // the final pass reads a 16 kHz WAV written at stop (no ffmpeg needed for the device's format)
                    var args = new List<string> { Directory, "--model-id", Model, "--audio-file", finalWav };
                    if (language != null) args.AddRange(new[] { "--language", language });
                    p = ScriptRunner.Start("board_live.py", args.ToArray(), cwd: Directory);
                    process = p;
                }
                p.StandardInput.Close();
                _ = Task.Run(async () => { while (await p.StandardError.ReadLineAsync() != null) { } });
                string? line;
                while ((line = p.StandardOutput.ReadLine()) != null)
                {
                    if (!line.TrimStart().StartsWith('{')) continue;
                    JsonObject? ev = null;
                    try { ev = JsonNode.Parse(line) as JsonObject; } catch { }
                    if (ev != null) ui.BeginInvoke(() => Receive(ev));
                }
                p.WaitForExit(2000);
                lock (this) process = null;
                ui.BeginInvoke(() => DidExit());
            }
            catch (ScriptFailure e)
            {
                ui.BeginInvoke(() => { Fail(e.Code); DidExit(); });
            }
            catch (Exception)
            {
                StopProcess();
                ui.BeginInvoke(() => { Fail("error"); DidExit(); });
            }
        });
    }

    public void SetPaused(bool paused)
    {
        var marker = Path.Combine(Directory, "paused");
        if (paused) { try { File.WriteAllBytes(marker, Array.Empty<byte>()); } catch { } }
        else TryDelete(marker);
    }

    /// The audio is closed: write the 16 kHz WAV for the final pass, then ask the script to finish.
    public void Finish(Action done)
    {
        BoardAudio.WrapPcmAsWav(PcmPath, finalWav);
        if (terminal) { done(); return; }
        completion = done;
        try { File.WriteAllBytes(Path.Combine(Directory, "stop"), Array.Empty<byte>()); } catch { }
        var timeout = Model == "volcengine-seedasr" ? TimeSpan.FromSeconds(25) : TimeSpan.FromSeconds(600);
        var timer = new DispatcherTimer(timeout, DispatcherPriority.Normal, (s, _) =>
        {
            ((DispatcherTimer)s!).Stop();
            if (terminal) return;
            Fail("network"); Cancel(); DidExit();
        }, ui);
        timer.Start();
    }

    public void Cancel()
    {
        try { File.WriteAllBytes(Path.Combine(Directory, "stop"), Array.Empty<byte>()); } catch { }
        lock (this) cancelled = true;
        StopProcess();
        BoardModelStatus.WriteReceipt(audioUrl, "interrupted", Model, lastMetadata, "实时调用.json");
        OnText = null; OnReady = null; OnFailure = null; OnFinalizing = null;
        terminal = true;
        var done = completion; completion = null; done?.Invoke();
    }

    void StopProcess()
    {
        Process? p;
        lock (this) { p = process; process = null; }
        if (p == null) return;
        try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { }
    }

    static List<BoardSpeechSegment>? Rows(JsonNode? node)
    {
        if (node is not JsonArray rows) return null;
        var list = new List<BoardSpeechSegment>();
        foreach (var r in rows.OfType<JsonObject>())
        {
            var s = new BoardSpeechSegment(Json.Double(r["start"]) ?? -1, Json.Double(r["end"]) ?? -1, Json.String(r["text"]) ?? "");
            if (!s.Valid || Json.String(r["text"]) == null) return null;
            list.Add(s);
        }
        return list;
    }

    void Receive(JsonObject ev)
    {
        if (terminal || cancelled) return;
        if (Json.String(ev["model"]) != Model) { Fail("bad_response"); return; }
        foreach (var key in new[] { "model", "provider", "request_id", "service_model" })
            if (Json.String(ev[key]) is { Length: > 0 } v) lastMetadata[key] = v;
        var kind = Json.String(ev["event"]);
        if (kind == "finalizing")
        {
            FileFinalizationAttempted = true;
            BoardModelStatus.WriteReceipt(audioUrl, "requested", Model, lastMetadata);
            OnFinalizing?.Invoke();
            return;
        }
        if (kind == "file_transcript")
        {
            FileFinalizationAttempted = true;
            if (Json.Bool(ev["ok"]) == false || Json.Bool(ev["looped"]) == true || Json.String(ev["text"]) is not { } text || Rows(ev["segments"]) is not { } segs)
            {
                BoardModelStatus.WriteReceipt(audioUrl, "failed", Model, ev);
                Fail(Json.String(ev["code"]) ?? "incomplete_response");
                return;
            }
            FinalFileTranscript = (text, segs);
            return;
        }
        if (Json.Bool(ev["ok"]) == false) { Fail(Json.String(ev["code"]) ?? "error"); return; }
        switch (kind)
        {
            case "connected":
                BoardModelStatus.WriteReceipt(audioUrl, "connected", Model, lastMetadata, "实时调用.json");
                OnReady?.Invoke();
                break;
            case "partial":
            case "segment":
                if (Json.String(ev["text"]) is not { } words) { Fail("bad_response"); return; }
                if (words.Length > 0 && !receivedText)
                {
                    receivedText = true;
                    BoardModelStatus.WriteReceipt(audioUrl, "receiving", Model, lastMetadata, "实时调用.json");
                }
                if (kind == "segment")
                {
                    var rows = Rows(ev["utterances"]) ?? new();
                    if (rows.Count > 0) Segments.AddRange(rows);
                    else if (Json.Double(ev["start"]) is { } s && Json.Double(ev["end"]) is { } e && e > s && words.Trim().Length > 0)
                        Segments.Add(new BoardSpeechSegment(s, e, words));
                }
                OnText?.Invoke(words, kind == "segment");
                break;
            case "done":
                if (!failed)
                {
                    BoardModelStatus.WriteReceipt(audioUrl, "success", Model, lastMetadata, "实时调用.json");
                    CompletedCleanly = true;
                }
                DidExit(confirmed: true);
                break;
        }
    }

    void Fail(string code)
    {
        if (failed || terminal) return;
        failed = true;
        var metadata = (JsonObject)lastMetadata.DeepClone();
        metadata["code"] = code;
        BoardModelStatus.WriteReceipt(audioUrl, "failed", Model, metadata, "实时调用.json");
        OnFailure?.Invoke(BoardModelStatus.FailureText(code));
    }

    void DidExit(bool confirmed = false)
    {
        if (terminal) return;
        if (!failed && !confirmed && !cancelled) Fail("network");
        terminal = true;
        var done = completion; completion = null;
        done?.Invoke();
    }
}
