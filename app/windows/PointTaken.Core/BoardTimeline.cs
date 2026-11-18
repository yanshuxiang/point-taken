// Page visits for 时间线.json: keeps only small visual signatures in memory; unmarked visits never write screenshots.
// A return to the same page needs the same window identity and a near-identical picture (BoardTimeline.swift).
namespace PointTaken.Core;

public sealed class BoardTimeline
{
    public BoardEvidence Evidence { get; set; } = new();
    sealed class Candidate { public string Id = ""; public string Scene = ""; public string Title = ""; public BoardFrameFingerprint? Print; }
    readonly List<Candidate> candidates = new();
    int? current;
    int? visit;
    public string? CurrentID => current is { } c ? candidates[c].Id : null;

    public void Observe(string scene, string app, string title, BoardFrameFingerprint? fingerprint, bool boundary, BoardMoment time)
    {
        var changed = current is not { } c || candidates[c].Scene != scene || candidates[c].Title != title;
        var audioBegan = visit is { } v && Evidence.Visits[v].Start.Audio == null && time.Audio != null;
        if (visit == null || boundary || changed || audioBegan)
        {
            Close(time);
            var matches = candidates.Select((cand, i) => (cand, i)).Where(x =>
                x.cand.Scene == scene && x.cand.Title == title && x.cand.Print != null && fingerprint != null && x.cand.Print.Distance(fingerprint) < 0.002)
                .Select(x => x.i).ToList();
            int index;
            if (audioBegan && !boundary && !changed && current is { } cur) index = cur;
            else if (matches.Count == 1) index = matches[0];
            else
            {
                index = candidates.Count;
                candidates.Add(new Candidate { Id = Guid.NewGuid().ToString().ToUpperInvariant(), Scene = scene, Title = title, Print = fingerprint });
            }
            current = index;
            Evidence.Visits.Add(new BoardVisit { PageID = candidates[index].Id, App = app, Title = title, Start = time, End = time });
            visit = Evidence.Visits.Count - 1;
        }
        else if (visit is { } open) Evidence.Visits[open] = Evidence.Visits[open] with { End = time };
    }

    public void Touch(BoardMoment time)
    {
        if (visit is { } v) Evidence.Visits[v] = Evidence.Visits[v] with { End = time };
    }

    public void Anchor(BoardFrameFingerprint fingerprint)
    {
        if (current is { } c) candidates[c].Print = fingerprint;
    }

    public void Close(BoardMoment time)
    {
        if (visit is { } v) Evidence.Visits[v] = Evidence.Visits[v] with { End = time };
        visit = null;
    }
}
