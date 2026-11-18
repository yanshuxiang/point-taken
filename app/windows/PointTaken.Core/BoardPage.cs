// One kept page and its row in 页面.json — the same fields, names and nesting the macOS app writes
// (BoardPageFiles.swift), so records open on either system. Points are normalised 0–1 from the picture's top-left.
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PointTaken.Core;

public sealed class BoardPage
{
    /// the marked picture(s) that go to the AI (full paths)
    public List<string> Images { get; set; } = new();
    public string Text { get; set; } = "";
    /// the clean screenshot the marks are drawn on
    public string? Original { get; set; }
    public List<List<double[]>> Marks { get; set; } = new();
    public bool Included { get; set; } = true;
    public string Scene { get; set; } = "";
    public double LineWidth { get; set; } = 4;
    public int FooterTrim { get; set; }
    public List<string> SourceFrames { get; set; } = new();
    public List<string> RetainedFiles { get; set; } = new();
    public List<BoardPage> Components { get; set; } = new();
    public List<int> ComponentOffsets { get; set; } = new();
    public List<string> ContextIDs { get; set; } = new();
    public List<BoardMarkEvidence> MarkEvidence { get; set; } = new();
    public bool ManuallySaved { get; set; }
    public bool ImageNeedsRepair { get; set; }
    /// session seconds when the screen picture was taken; null in older records
    public double? CapturedAt { get; set; }
    /// the user split this long picture in the review: never join its parts automatically again
    public bool KeepApart { get; set; }

    public IEnumerable<string> AllFiles =>
        Images.Concat(Original is null ? Array.Empty<string>() : new[] { Original }).Concat(SourceFrames).Concat(RetainedFiles)
            .Concat(Components.SelectMany(c => c.AllFiles)).Distinct(StringComparer.OrdinalIgnoreCase);

    public BoardPage Clone()
    {
        var c = (BoardPage)MemberwiseClone();
        c.Images = new(Images); c.Marks = Marks.Select(m => m.Select(p => (double[])p.Clone()).ToList()).ToList();
        c.SourceFrames = new(SourceFrames); c.RetainedFiles = new(RetainedFiles);
        c.Components = Components.Select(x => x.Clone()).ToList(); c.ComponentOffsets = new(ComponentOffsets);
        c.ContextIDs = new(ContextIDs); c.MarkEvidence = new(MarkEvidence);
        return c;
    }

    public JsonObject Encode()
    {
        var row = new JsonObject
        {
            ["images"] = new JsonArray(Images.Select(i => (JsonNode)Path.GetFileName(i)!).ToArray()),
            ["original"] = Original is null ? "" : Path.GetFileName(Original),
            ["marks"] = new JsonArray(Marks.Select(m => (JsonNode)new JsonArray(m.Select(p => (JsonNode)new JsonArray(p.Select(v => (JsonNode)v!).ToArray())).ToArray())).ToArray()),
            ["text"] = Text,
            ["included"] = Included,
            ["scene"] = Scene,
            ["lineWidth"] = LineWidth,
            ["footerTrim"] = FooterTrim,
            ["sourceFrames"] = new JsonArray(SourceFrames.Select(i => (JsonNode)Path.GetFileName(i)!).ToArray()),
            ["retainedFiles"] = new JsonArray(RetainedFiles.Select(i => (JsonNode)Path.GetFileName(i)!).ToArray()),
            ["components"] = new JsonArray(Components.Select(c => (JsonNode)c.Encode()).ToArray()),
            ["componentOffsets"] = new JsonArray(ComponentOffsets.Select(o => (JsonNode)o).ToArray()),
            ["contextIDs"] = new JsonArray(ContextIDs.Select(i => (JsonNode)i!).ToArray()),
            ["manuallySaved"] = ManuallySaved,
            ["imageNeedsRepair"] = ImageNeedsRepair,
            ["markEvidence"] = JsonNode.Parse(JsonSerializer.Serialize(MarkEvidence, BoardEvidence.Options)),
        };
        if (CapturedAt is { } at) row["capturedAt"] = at;
        if (KeepApart) row["keepApart"] = true;
        return (JsonObject)Json.Sorted(row)!;
    }

    public static BoardPage? Decode(JsonObject row, string directory, int depth = 0)
    {
        if (depth >= 32) return null;
        string? PathOf(string? name) =>
            string.IsNullOrEmpty(name) || Path.GetFileName(name) != name ? null : Path.Combine(directory, name);
        string? FileOf(string? name) => PathOf(name) is { } p && File.Exists(p) ? p : null;
        List<string> Names(JsonNode? n) => n is JsonArray a ? a.Select(x => Json.String(x)).Where(x => x != null).Select(x => x!).ToList() : new();

        var images = Names(row["images"]).Select(PathOf).Where(p => p != null).Select(p => p!).ToList();
        if (images.Count == 0) return null;
        var marks = new List<List<double[]>>();
        if (row["marks"] is JsonArray ma)
            foreach (var stroke in ma)
                if (stroke is JsonArray sa)
                    marks.Add(sa.OfType<JsonArray>().Select(p => p.Select(v => Json.Double(v) ?? 0).ToArray()).ToList());
        List<BoardMarkEvidence> evidence = new();
        try { if (row["markEvidence"] is JsonArray ea) evidence = JsonSerializer.Deserialize<List<BoardMarkEvidence>>(ea.ToJsonString(), BoardEvidence.Options) ?? new(); }
        catch (JsonException) { }
        return new BoardPage
        {
            Images = images,
            Text = Json.String(row["text"]) ?? "",
            Original = PathOf(Json.String(row["original"])),
            Marks = marks,
            Included = Json.Bool(row["included"]) ?? true,
            Scene = Json.String(row["scene"]) ?? "",
            LineWidth = Json.Double(row["lineWidth"]) ?? 4,
            FooterTrim = Json.Int(row["footerTrim"]) ?? 0,
            SourceFrames = Names(row["sourceFrames"]).Select(FileOf).Where(p => p != null).Select(p => p!).ToList(),
            RetainedFiles = Names(row["retainedFiles"]).Select(FileOf).Where(p => p != null).Select(p => p!).ToList(),
            Components = (row["components"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(c => Decode(c, directory, depth + 1)).Where(c => c != null).Select(c => c!).ToList(),
            ComponentOffsets = (row["componentOffsets"] as JsonArray ?? new JsonArray()).Select(x => Json.Int(x) ?? 0).ToList(),
            ContextIDs = Names(row["contextIDs"]),
            MarkEvidence = evidence,
            ManuallySaved = Json.Bool(row["manuallySaved"]) ?? false,
            ImageNeedsRepair = Json.Bool(row["imageNeedsRepair"]) ?? false,
            CapturedAt = Json.Double(row["capturedAt"]),
            KeepApart = Json.Bool(row["keepApart"]) ?? false,
        };
    }

    public const string Filename = "页面.json";

    public static List<BoardPage> LoadAll(string directory)
    {
        try
        {
            if (JsonNode.Parse(File.ReadAllText(Path.Combine(directory, Filename))) is JsonArray rows)
                return rows.OfType<JsonObject>().Select(r => Decode(r, directory)).Where(p => p != null).Select(p => p!).ToList();
        }
        catch { /* an unreadable file: no pages */ }
        return new();
    }

    public static void SaveAll(string directory, IEnumerable<BoardPage> pages) =>
        AtomicFile.WriteJson(Path.Combine(directory, Filename), new JsonArray(pages.Select(p => (JsonNode)p.Encode()).ToArray()));

    /// 图1 / 图2 …: the label each picture gets, and the words of its page under the first one.
    public static List<(string? image, string label, string text)> Labelled(IReadOnlyList<BoardPage> pages)
    {
        var result = new List<(string?, string, string)>();
        var n = 0;
        foreach (var p in pages)
        {
            if (p.Images.Count == 0) { result.Add((null, "补充", p.Text)); continue; }
            for (var i = 0; i < p.Images.Count; i++)
            {
                n++;
                result.Add((p.Images[i], $"图{n}", i == 0 ? p.Text : "（和上一张是同一页的另一块屏幕）"));
            }
        }
        return result;
    }

    public static string Markdown(IReadOnlyList<BoardPage> pages) => string.Join("\n\n", Labelled(pages).Select(e =>
    {
        var body = e.text.Length == 0 ? "（此页没有单独的语音摘录，完整说明见上方转写）" : e.text;
        return e.image != null ? $"![{e.label}]({Path.GetFileName(e.image)})\n\n{e.label}：{body}" : $"{e.label}：{body}";
    }));

    public static List<BoardReadablePage> Readable(IEnumerable<BoardPage> pages) =>
        pages.Where(p => p.Included).Select(p => new BoardReadablePage(p.Images, p.ContextIDs, p.MarkEvidence)).ToList();
}

/// One page's marks as the review window edits them: each stroke kept with its number, times and note.
public sealed class BoardMarkSheet
{
    public sealed record Mark(List<double[]> Points, BoardMarkEvidence Evidence);
    public List<Mark> Marks { get; }

    public BoardMarkSheet(IReadOnlyList<List<double[]>> strokes, IReadOnlyList<BoardMarkEvidence> evidence, int firstFree)
    {
        var next = firstFree;
        Marks = strokes.Select((points, i) => i < evidence.Count ? new Mark(points, evidence[i]) : new Mark(points, new BoardMarkEvidence(next++))).ToList();
    }

    public List<List<double[]>> Strokes => Marks.Select(m => m.Points).ToList();
    public List<BoardMarkEvidence> Evidence => Marks.Select(m => m.Evidence).ToList();
    public int IndexOf(int number) => Marks.FindIndex(m => m.Evidence.Number == number);
    public void Add(List<double[]> points, int number) => Marks.Add(new Mark(points, new BoardMarkEvidence(number, added: true)));
    public bool Remove(int number) { var i = IndexOf(number); if (i < 0) return false; Marks.RemoveAt(i); return true; }
    public bool SetNote(string text, int number)
    {
        var i = IndexOf(number);
        if (i < 0) return false;
        var trimmed = text.Trim();
        string? value = trimmed.Length == 0 ? null : trimmed;
        if (Marks[i].Evidence.Note == value) return false;
        Marks[i] = Marks[i] with { Evidence = Marks[i].Evidence with { Note = value } };
        return true;
    }

    /// Where a mark's number badge sits in a `width`×`height` picture: up and left of where the stroke began, kept inside.
    public static Pt? BadgeCenter(IReadOnlyList<double[]> points, double width, double height, double diameter)
    {
        if (points.Count == 0 || points[0].Length != 2) return null;
        var r = diameter / 2;
        var x = Math.Min(Math.Max(r, points[0][0] * width - r), width - r);
        var y = Math.Min(Math.Max(r, points[0][1] * height - r), height - r);
        return new Pt(x, y);
    }

    /// The mark under `p` (picture pixels): its badge first, then its line within `tolerance`. The last drawn wins.
    public int? Hit(Pt p, double width, double height, double tolerance, double ring, double badge)
    {
        for (var i = Marks.Count - 1; i >= 0; i--)
            if (BadgeCenter(Marks[i].Points, width, height, badge) is { } c && p.DistanceTo(c) <= badge / 2 + 2) return Marks[i].Evidence.Number;
        for (var i = Marks.Count - 1; i >= 0; i--)
        {
            var pts = Marks[i].Points.Where(q => q.Length == 2).Select(q => new Pt(q[0] * width, q[1] * height)).ToList();
            if (pts.Count == 0) continue;
            if (pts.Count == 1) { if (p.DistanceTo(pts[0]) <= ring + tolerance) return Marks[i].Evidence.Number; continue; }
            for (var k = 1; k < pts.Count; k++) if (Distance(p, pts[k - 1], pts[k]) <= tolerance) return Marks[i].Evidence.Number;
        }
        return null;
    }

    static double Distance(Pt p, Pt a, Pt b)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y, len = dx * dx + dy * dy;
        if (len <= 0) return p.DistanceTo(a);
        var t = Math.Max(0, Math.Min(1, ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len));
        return p.DistanceTo(new Pt(a.X + t * dx, a.Y + t * dy));
    }
}

/// Whether a page goes to the AI after its marks changed: gaining its first mark checks it, losing its last unchecks it.
public static class BoardPageInclusion
{
    public static bool After(int before, int after, bool included) =>
        before == 0 && after > 0 ? true : before > 0 && after == 0 ? false : included;
}
