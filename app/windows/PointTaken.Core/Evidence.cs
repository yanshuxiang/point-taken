// 时间线.json and the per-mark times in 页面.json: the same JSON the macOS app writes (BoardEvidence.swift), so a record
// made on either system opens on the other. Audio positions come from samples actually written, never from callback
// arrival times; session time excludes pauses.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PointTaken.Core;

public sealed record BoardMoment
{
    [JsonPropertyName("elapsed")] public double Elapsed { get; init; }
    [JsonPropertyName("audio")] public double? Audio { get; init; }
    public BoardMoment() { }
    public BoardMoment(double elapsed, double? audio = null) { Elapsed = elapsed; Audio = audio; }
}

public sealed record BoardMarkEvidence
{
    [JsonPropertyName("number")] public int Number { get; init; }
    [JsonPropertyName("start")] public BoardMoment? Start { get; init; }
    [JsonPropertyName("end")] public BoardMoment? End { get; init; }
    /// what the user wrote for this mark in the review window (null: nothing written)
    [JsonPropertyName("note")] public string? Note { get; init; }
    /// drawn in the review window after recording (no recording time by design, not by loss)
    [JsonPropertyName("added")] public bool? Added { get; init; }

    public BoardMarkEvidence() { }
    public BoardMarkEvidence(int number, BoardMoment? start = null, BoardMoment? end = null, string? note = null, bool? added = null)
    { Number = number; Start = start; End = end; Note = note; Added = added; }

    [JsonIgnore] public string? WrittenNote => string.IsNullOrWhiteSpace(Note) ? null : Note.Trim();
    [JsonIgnore] public bool IsAdded => Added == true;
}

public sealed record BoardSpeechSegment
{
    [JsonPropertyName("start")] public double Start { get; init; }
    [JsonPropertyName("end")] public double End { get; init; }
    [JsonPropertyName("text")] public string Text { get; init; } = "";
    public BoardSpeechSegment() { }
    public BoardSpeechSegment(double start, double end, string text) { Start = start; End = end; Text = text; }
    [JsonIgnore] public bool Valid => double.IsFinite(Start) && double.IsFinite(End) && Start >= 0 && End > Start;
}

public sealed record BoardVisit
{
    [JsonPropertyName("pageID")] public string PageID { get; init; } = "";
    [JsonPropertyName("app")] public string App { get; init; } = "";
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("start")] public BoardMoment Start { get; init; } = new();
    [JsonPropertyName("end")] public BoardMoment End { get; init; } = new();
}

public enum BoardInputKind { scroll, click, key }

public sealed record BoardInput
{
    [JsonPropertyName("kind"), JsonConverter(typeof(JsonStringEnumConverter))] public BoardInputKind Kind { get; init; }
    /// session seconds (the same clock as BoardMoment.Elapsed)
    [JsonPropertyName("at")] public double At { get; init; }
    /// scroll only: how far the content moved; negative reveals what is below
    [JsonPropertyName("dy")] public double? Dy { get; init; }
}

public static class BoardScrollInput
{
    /// Consecutive wheel events closer than this are kept as one entry.
    public const double CoalesceWindow = 0.15;

    public static void Append(BoardInput input, List<BoardInput> inputs)
    {
        if (input.Kind == BoardInputKind.scroll && inputs.Count > 0 && inputs[^1] is { Kind: BoardInputKind.scroll } last
            && input.At - last.At <= CoalesceWindow)
        {
            inputs[^1] = last with { Dy = (last.Dy ?? 0) + (input.Dy ?? 0), At = input.At };
            return;
        }
        inputs.Add(input);
    }

    /// True only when, strictly between the two captures, the wheel was used, nothing else was, and the content moved
    /// down the document overall.
    public static bool OnlyScrolledDown(IReadOnlyList<BoardInput> inputs, double start, double end)
    {
        if (end <= start) return false;
        var between = inputs.Where(i => i.At > start && i.At < end).ToList();
        if (between.Count == 0 || between.Any(i => i.Kind != BoardInputKind.scroll)) return false;
        return between.Sum(i => i.Dy ?? 0) < 0;
    }
}

public sealed class BoardEvidence
{
    public const string Filename = "时间线.json";

    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("visits")] public List<BoardVisit> Visits { get; set; } = new();
    [JsonPropertyName("speech")] public List<BoardSpeechSegment> Speech { get; set; } = new();
    [JsonPropertyName("speechTimingSource")] public string SpeechTimingSource { get; set; } = "unavailable";
    /// scrolls, clicks and key presses that went to other apps (no keys, no positions). null in older records.
    [JsonPropertyName("inputs")] public List<BoardInput>? Inputs { get; set; }

    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public BoardEvidence Clone() => JsonSerializer.Deserialize<BoardEvidence>(JsonSerializer.Serialize(this, Options), Options)!;

    public static BoardEvidence? Load(string directory)
    {
        try { return JsonSerializer.Deserialize<BoardEvidence>(File.ReadAllText(Path.Combine(directory, Filename)), Options); }
        catch { return null; }
    }

    public void Save(string directory) =>
        AtomicFile.WriteText(Path.Combine(directory, Filename), JsonSerializer.Serialize(this, Options));

    public static string Stamp(double seconds)
    {
        var t = Math.Max(0, seconds);
        return $"{(int)t / 60:00}:{t % 60:00.0}";
    }

    public static string Range(BoardMoment start, BoardMoment end)
    {
        if (start.Audio is { } a && end.Audio is { } b) return $"音频 {Stamp(a)}–{Stamp(Math.Max(a, b))}";
        return $"会话 {Stamp(start.Elapsed)}–{Stamp(Math.Max(start.Elapsed, end.Elapsed))}（此段无完整音频定位）";
    }

    /// Whole recognition phrases plus nearby context; a candidate set, never a semantic assignment.
    public List<BoardSpeechSegment> Nearby(BoardMarkEvidence mark)
    {
        if (mark.Start?.Audio is not { } start || mark.End?.Audio is not { } end) return new();
        var valid = Speech.Where(s => double.IsFinite(s.Start) && double.IsFinite(s.End) && s.End > s.Start).OrderBy(s => s.Start).ToList();
        var first = valid.FindIndex(s => s.End >= start - 5 && s.Start <= end + 5);
        var last = valid.FindLastIndex(s => s.End >= start - 5 && s.Start <= end + 5);
        if (first < 0 || last < 0) return new();
        var lower = first > 0 && start - valid[first - 1].End <= 10 ? first - 1 : first;
        var upper = last + 1 < valid.Count && valid[last + 1].Start - end <= 10 ? last + 1 : last;
        return valid.GetRange(lower, upper - lower + 1);
    }

    /// how near (s) a sentence that doesn't overlap any drawing must be to a mark to be about it
    public const double SaidReach = 3.0;
    /// the longest pause (s) after which a following sentence still goes on about the same mark
    public const double SaidPause = 2.0;

    static readonly HashSet<string> Fillers = new() { "嗯", "啊", "呃", "额", "哦", "唔", "嗯嗯", "啊啊" };
    static readonly HashSet<char> Enders = new() { '。', '？', '！', '?', '!', '.', '…' };

    static string TrimPunct(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && (char.IsWhiteSpace(s[a]) || char.IsPunctuation(s[a]))) a++;
        while (b > a && (char.IsWhiteSpace(s[b - 1]) || char.IsPunctuation(s[b - 1]))) b--;
        return s[a..b];
    }

    /// What was said about each mark of one page, by time only (the macOS app's rules, BoardEvidence.said):
    /// a sentence said while a mark was drawn is that mark's (the most-overlapped one); otherwise the nearest mark within
    /// SaidReach; otherwise it goes on about the previous sentence's mark after a short pause with no other mark drawn in
    /// between; half a sentence followed right away by the rest goes where the rest went. Fillers are left out; marks
    /// without recording times get nothing. Keyed by mark number, sentences in order.
    public Dictionary<int, List<BoardSpeechSegment>> Said(IReadOnlyList<BoardMarkEvidence> marks, IReadOnlyList<string> onPage)
    {
        var sentences = Speech.Where(s =>
        {
            var t = TrimPunct(s.Text);
            return s.Valid && t.Length > 0 && !Fillers.Contains(t);
        }).OrderBy(s => s.Start).ToList();
        var stays = Visits.Where(v => onPage.Contains(v.PageID)).Select(v =>
            v.Start.Audio is { } a && v.End.Audio is { } b && double.IsFinite(a) && double.IsFinite(b) ? (a, Math.Max(a, b)) : ((double, double)?)null)
            .Where(x => x != null).Select(x => x!.Value).ToList();
        var timed = marks.Select(m => m.Start?.Audio is { } a && m.End?.Audio is { } b && double.IsFinite(a) && double.IsFinite(b)
                ? (number: m.Number, start: a, end: Math.Max(a, b)) : ((int number, double start, double end)?)null)
            .Where(x => x != null).Select(x => x!.Value).OrderBy(x => x.start).ToList();
        var windows = timed.Select(mark =>
        {
            var stay = stays.Cast<(double, double)?>().FirstOrDefault(s => s!.Value.Item1 - 0.05 <= mark.start && mark.start <= s.Value.Item2 + 0.05);
            return (lo: Math.Min(stay?.Item1 ?? mark.start - 10, mark.start), hi: Math.Max(stay?.Item2 ?? mark.end + 10, mark.end));
        }).ToList();
        static double Overlap(BoardSpeechSegment s, double a, double b) => Math.Min(s.End, b) - Math.Max(s.Start, a);
        double Gap(BoardSpeechSegment s, int m) => Math.Max(Math.Max(timed[m].start - s.End, s.Start - timed[m].end), 0);

        var owner = new int?[sentences.Count];
        for (var k = 0; k < sentences.Count; k++)
        {
            var s = sentences[k];
            var reachable = Enumerable.Range(0, timed.Count).Where(i => Overlap(s, windows[i].lo, windows[i].hi) > 0).ToList();
            var drawing = reachable.Where(i => Overlap(s, timed[i].start, timed[i].end) > 0).ToList();
            if (drawing.Count > 0)
            {
                var best = drawing[0];
                foreach (var i in drawing) if (Overlap(s, timed[i].start, timed[i].end) > Overlap(s, timed[best].start, timed[best].end)) best = i;
                owner[k] = best;
            }
            else if (reachable.Where(i => Gap(s, i) <= SaidReach).ToList() is { Count: > 0 } near)
            {
                var best = near[0];
                foreach (var i in near) if (Gap(s, i) < Gap(s, best)) best = i;
                owner[k] = best;
            }
            else if (k > 0 && owner[k - 1] is { } m && reachable.Contains(m) && s.Start - sentences[k - 1].End <= SaidPause
                     && !Enumerable.Range(0, timed.Count).Any(i => i != m && timed[i].start >= timed[m].start && timed[i].start < s.Start))
            {
                owner[k] = m;
            }
        }
        for (var k = sentences.Count - 2; k >= 0; k--)
        {
            var text = sentences[k].Text.Trim();
            if (text.Length == 0 || Enders.Contains(text[^1]) || owner[k + 1] is not { } next) continue;
            if (sentences[k + 1].Start - sentences[k].End > SaidPause) continue;
            if (Overlap(sentences[k], windows[next].lo, windows[next].hi) <= 0) continue;
            owner[k] = next;
        }
        var result = new Dictionary<int, List<BoardSpeechSegment>>();
        for (var i = 0; i < timed.Count; i++)
        {
            var mine = Enumerable.Range(0, sentences.Count).Where(k => owner[k] == i).ToList();
            if (mine.Count == 0) mine = Enumerable.Range(0, sentences.Count).Where(k => Overlap(sentences[k], timed[i].start, timed[i].end) > 0).ToList();
            result[timed[i].number] = mine.Select(k => sentences[k]).ToList();
        }
        return result;
    }
}

/// Session time with pauses left out.
public sealed class BoardCaptureClock
{
    readonly double began;
    double excluded;
    double? pauseStart;
    public BoardCaptureClock(double now) { began = now; }
    public void Pause(double now) { pauseStart ??= now; }
    public void Resume(double now)
    {
        if (pauseStart is { } s) { excluded += Math.Max(0, now - s); pauseStart = null; }
    }
    public double Elapsed(double now) => Math.Max(0, (pauseStart ?? now) - began - excluded);
}

/// A monotonic clock in seconds (the macOS app's systemUptime).
public static class Uptime
{
    static readonly System.Diagnostics.Stopwatch watch = System.Diagnostics.Stopwatch.StartNew();
    public static double Now => watch.Elapsed.TotalSeconds;
}
