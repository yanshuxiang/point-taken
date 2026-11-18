// The hand-off text (说明.md, the clipboard, the paste) and the independent export folder. Same wording and layout as
// the macOS app (BoardReadableExport.swift, BoardFolderExport.swift), so an AI receiving it reads the same thing.
namespace PointTaken.Core;

public sealed record BoardReadablePage(IReadOnlyList<string> Images, IReadOnlyList<string> ContextIDs, IReadOnlyList<BoardMarkEvidence> Marks);

public static class BoardReadableExport
{
    public static string Text(IReadOnlyList<BoardReadablePage> pages, string transcript, BoardEvidence? evidence, bool terminal = false)
    {
        var images = pages.SelectMany(p => p.Images).ToList();
        if (evidence == null) return BoardExport.Text(transcript, images, terminal);
        var count = pages.SelectMany(p => p.Marks).Select(m => m.Number).Distinct().Count();
        var imageReference = terminal ? "图号对应下方本地图片路径" : "图号对应附件顺序";
        var sections = new List<string>
        {
            $"# 界面反馈\n\n{images.Count} 张截图 · {count} 个标记\n\n{imageReference}，标记号对应图中编号。时间与语音参考只是线索，可能跨页，请结合全文判断；页面名称取自窗口标题。",
        };
        var segments = evidence.Speech.Where(s => s.Valid).OrderBy(s => s.Start).ToList();
        if (transcript.Length > 0)
        {
            var joined = segments.Select(s => s.Text).ToList();
            var timed = segments.Count > 0 && (transcript == string.Concat(joined) || transcript == string.Join(" ", joined));
            var body = timed ? string.Join("\n\n", segments.Select(s => $"**{Span(s.Start, s.End)}**　{s.Text}")) : transcript;
            sections.Add("## 完整转写\n\n" + body);
        }
        if (pages.Count > 0) sections.Add("## 按图查看");
        var imageIndex = 1;
        var linked = pages.SelectMany(p => p.ContextIDs).ToHashSet();
        foreach (var page in pages)
        {
            var names = Enumerable.Range(0, page.Images.Count).Select(i => $"图{imageIndex + i}").ToList();
            var name = names.Count == 0 ? "未附图片" : string.Join("、", names);
            var visits = evidence.Visits.Where(v => page.ContextIDs.Contains(v.PageID)).ToList();
            var contexts = Unique(visits.Select(Context));
            var caption = contexts.Count == 0 ? "" : " · " + Inline(string.Join(" / ", contexts));
            var lines = new List<string> { $"### {name}{caption}" };
            var times = Unique(visits.Select(v => Range(v.Start, v.End)));
            if (times.Count > 0) lines.AddRange(new[] { "", "页面停留：" + string.Join("；", times) });
            if (terminal)
            {
                lines.Add("");
                lines.AddRange(names.Zip(page.Images, (n, p) => $"{n}：{p}"));
            }
            if (page.Marks.Count > 0)
            {
                var noted = page.Marks.Any(m => m.WrittenNote != null);
                var around = evidence.Said(page.Marks, page.ContextIDs);
                lines.AddRange(new[] { "", noted ? "| 标记 | 时间 | 说明 / 语音参考 |" : "| 标记 | 时间 | 语音参考 |", "| --- | --- | --- |" });
                foreach (var mark in page.Marks)
                {
                    string time;
                    if (mark.Start is { } s && mark.End is { } e) time = Range(s, e);
                    else time = mark.IsAdded ? "补画" : "未记录";
                    var quote = Quotes(around.TryGetValue(mark.Number, out var said) ? said : new());
                    string text;
                    if (mark.WrittenNote is { } note) text = "说明：" + note + (quote != null ? $"（这时说的：{quote}）" : "");
                    else text = quote ?? "—";
                    lines.Add($"| 标记 {mark.Number} | {time} | {Cell(text)} |");
                }
                if (page.Marks.Any(m => m.IsAdded && (m.Start == null || m.End == null)))
                    lines.AddRange(new[] { "", "*“补画”表示录音结束后在检查窗口补上的标记，没有录音时间，以说明为准。*" });
                if (page.Marks.Any(m => !m.IsAdded && (m.Start == null || m.End == null)))
                    lines.AddRange(new[] { "", "*“未记录”表示旧版标记，没有录音时间。*" });
            }
            else lines.AddRange(new[] { "", "手动保留的截图，没有标记。" });
            sections.Add(string.Join("\n", lines));
            imageIndex += page.Images.Count;
        }
        var unlinked = evidence.Visits.Where(v => !linked.Contains(v.PageID)).ToList();
        if (unlinked.Count > 0)
            sections.Add("## 其他页面停留（无截图）\n\n" + string.Join("\n", unlinked.Select(v => $"- {Range(v.Start, v.End)} · {Inline(Context(v))}")));
        sections.Add("*时间默认对应原始录音，暂停不计入；标注“会话”的时间没有完整音频定位。表中语音按时间归到标记：画的时候说的、紧挨着画说的，以及停顿很短的接着说的话；一句只归一个标记，离哪个标记都远的话只在全文里。“—”表示这段时间没有说话。*");
        return string.Join("\n\n", sections);
    }

    /// Marks the AI would get with nothing to go on: no written note and nothing said around them on their page.
    public static List<BoardMarkEvidence> Unexplained(IReadOnlyList<BoardMarkEvidence> marks, IReadOnlyList<string> onPage, BoardEvidence? evidence)
    {
        var around = evidence?.Said(marks, onPage) ?? new();
        return marks.Where(m => m.WrittenNote == null && (!around.TryGetValue(m.Number, out var s) || s.Count == 0)).ToList();
    }

    static string? Quotes(List<BoardSpeechSegment> said)
    {
        if (said.Count == 0) return null;
        var shown = string.Join(" ", said.Take(3).Select(s => Excerpt(s.Text)));
        return said.Count > 3 ? shown + $"（另有 {said.Count - 3} 句，见全文）" : shown;
    }
    static string Span(double start, double end) => BoardEvidence.Stamp(start) + "–" + BoardEvidence.Stamp(Math.Max(start, end));
    static string Range(BoardMoment start, BoardMoment end) =>
        start.Audio is { } a && end.Audio is { } b ? Span(a, b) : "会话 " + Span(start.Elapsed, end.Elapsed);
    static string Context(BoardVisit visit)
    {
        var parts = new[] { visit.App, visit.Title }.Where(s => s.Length > 0).ToList();
        return parts.Count == 0 ? "标题不可用" : string.Join(" · ", parts);
    }
    static List<string> Unique(IEnumerable<string> strings) { var seen = new HashSet<string>(); return strings.Where(seen.Add).ToList(); }
    static string Excerpt(string text)
    {
        text = text.Replace("\n", " ").Trim();
        var info = new System.Globalization.StringInfo(text);
        return "“" + (info.LengthInTextElements > 64 ? info.SubstringByTextElements(0, 64) + "…" : text) + "”";
    }
    static string Inline(string text) => text.Replace("\r", " ").Replace("\n", " ").Replace("\\", "\\\\").Replace("*", "\\*")
        .Replace("_", "\\_").Replace("[", "\\[").Replace("<", "&lt;").Replace(">", "&gt;").Replace("`", "\\`");
    static string Cell(string text) => Inline(text).Replace("|", "\\|");
}

/// An independent snapshot: later archive edits or deletions cannot invalidate a hand-off.
public static class BoardFolderExport
{
    public sealed record Bundle(string Directory, IReadOnlyList<string> Images, string Text);

    public const string Intro = "图片已保存为本地文件，请读取下列完整路径对应的图片，结合转写与标记理解反馈。需要接收端能够访问这台电脑的文件。";

    public static Bundle Create(string root, IReadOnlyList<BoardReadablePage> pages, string transcript, BoardEvidence? evidence)
    {
        Directory.CreateDirectory(root);
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        var destination = Path.Combine(root, DateTime.Now.ToString("yyyy-MM-dd HH.mm.ss") + " " + id);
        var staging = Path.Combine(root, ".preparing-" + id);
        Directory.CreateDirectory(staging);
        try
        {
            var exported = new List<BoardReadablePage>();
            var index = 0;
            foreach (var page in pages)
            {
                var images = new List<string>();
                foreach (var source in page.Images)
                {
                    index++;
                    var info = new FileInfo(source);
                    if (!info.Exists || info.Length == 0) throw new IOException("图片找不到了：" + Path.GetFileName(source));
                    var name = $"图{index}.png";
                    File.Copy(source, Path.Combine(staging, name));
                    images.Add(Path.Combine(destination, name));
                }
                exported.Add(page with { Images = images });
            }
            var text = Intro + "\n\n" + BoardReadableExport.Text(exported, transcript, evidence, terminal: true);
            File.WriteAllText(Path.Combine(staging, "说明.md"), text, new System.Text.UTF8Encoding(false));
            Directory.Move(staging, destination);
            return new Bundle(destination, exported.SelectMany(p => p.Images).ToList(), text);
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { /* best effort */ }
        }
    }
}
