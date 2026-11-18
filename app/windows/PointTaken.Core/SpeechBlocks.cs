// What was said, in order, grouped by the screen it was said on (BoardSpeechBlock in BoardReview.swift): a kept page,
// a screen that wasn't kept, or none. Built from the record's own timeline: page visits and sentences in audio seconds.
namespace PointTaken.Core;

public sealed class BoardSpeechBlock
{
    public enum KindTag { Page, Screen, None }
    public KindTag Kind { get; init; }
    public int PageIndex { get; init; } = -1;
    public string ScreenName { get; init; } = "";
    public double Start { get; set; }
    public double End { get; set; }
    public List<BoardSpeechSegment> Segments { get; } = new();

    bool SameKind(BoardSpeechBlock o) => Kind == o.Kind && PageIndex == o.PageIndex && ScreenName == o.ScreenName;

    /// 0:42, or 1:02:03 past an hour.
    public static string Clock(double seconds)
    {
        var t = (int)Math.Floor(Math.Max(0, seconds));
        return t >= 3600 ? $"{t / 3600}:{t / 60 % 60:00}:{t % 60:00}" : $"{t / 60}:{t % 60:00}";
    }

    public static List<BoardSpeechBlock> Build(IReadOnlyList<BoardPage> pages, BoardEvidence? evidence)
    {
        if (evidence == null) return new();
        var speech = evidence.Speech.Where(s => double.IsFinite(s.Start) && double.IsFinite(s.End) && s.End >= s.Start && s.Text.Trim().Length > 0)
            .OrderBy(s => s.Start).ToList();
        var blocks = new List<BoardSpeechBlock>();
        var visits = evidence.Visits.Where(v => v.Start.Audio is { } a && v.End.Audio is { } b && double.IsFinite(a) && double.IsFinite(b))
            .Select(v => (v, a: v.Start.Audio!.Value, b: Math.Max(v.Start.Audio!.Value, v.End.Audio!.Value))).OrderBy(x => x.a);
        foreach (var (v, a, b) in visits)
        {
            var page = pages.Select((p, i) => (p, i)).FirstOrDefault(x => x.p.ContextIDs.Contains(v.PageID), (null!, -1)).i;
            var block = page >= 0
                ? new BoardSpeechBlock { Kind = KindTag.Page, PageIndex = page, Start = a, End = b }
                : new BoardSpeechBlock { Kind = KindTag.Screen, ScreenName = string.Join(" · ", new[] { v.App, v.Title }.Where(s => s.Length > 0)), Start = a, End = b };
            if (blocks.Count > 0 && blocks[^1].SameKind(block) && a - blocks[^1].End < 1.5) blocks[^1].End = Math.Max(blocks[^1].End, b);
            else blocks.Add(block);
        }
        var loose = new List<BoardSpeechBlock>();
        var lastWasLoose = false;
        foreach (var s in speech)
        {
            var mid = (s.Start + s.End) / 2;
            var home = blocks.FirstOrDefault(x => mid >= x.Start && mid <= x.End);
            if (home != null) { home.Segments.Add(s); lastWasLoose = false; }
            else if (lastWasLoose && loose.Count > 0) { loose[^1].Segments.Add(s); loose[^1].End = s.End; }
            else
            {
                var b = new BoardSpeechBlock { Kind = KindTag.None, Start = s.Start, End = s.End };
                b.Segments.Add(s);
                loose.Add(b);
                lastWasLoose = true;
            }
        }
        var output = new List<BoardSpeechBlock>();
        foreach (var b in blocks.Concat(loose).OrderBy(x => x.Start))
        {
            if (b.Segments.Count == 0 && b.Kind != KindTag.Page) continue;
            if (output.Count > 0 && output[^1].SameKind(b))
            {
                output[^1].End = Math.Max(output[^1].End, b.End);
                output[^1].Segments.AddRange(b.Segments);
            }
            else output.Add(b);
        }
        return output.Any(b => b.Segments.Count > 0) ? output : new();
    }

    /// A page's stretches: "0:12 – 0:31", or "0:12 – 0:31（2 段）".
    public static string Times(IReadOnlyList<BoardSpeechBlock> blocks, int page)
    {
        var mine = blocks.Where(b => b.Kind == KindTag.Page && b.PageIndex == page).ToList();
        if (mine.Count == 0) return "";
        return Clock(mine[0].Start) + " – " + Clock(mine[^1].End) + (mine.Count > 1 ? $"（{mine.Count} 段）" : "");
    }
}
