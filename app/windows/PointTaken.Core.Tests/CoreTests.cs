using System.Text.Json.Nodes;
using PointTaken.Core;
using Xunit;

namespace PointTaken.Core.Tests;

public class EvidenceTests
{
    static BoardMarkEvidence Mark(int n, double a, double b) => new(n, new BoardMoment(a, a), new BoardMoment(b, b));

    [Fact]
    public void SentenceDuringDrawingBelongsToThatMark()
    {
        var e = new BoardEvidence { Speech = { new(1, 3, "这里改成红色。"), new(10, 12, "这个按钮太小了。") } };
        var said = e.Said(new[] { Mark(1, 2, 4), Mark(2, 10.5, 11) }, Array.Empty<string>());
        Assert.Equal("这里改成红色。", Assert.Single(said[1]).Text);
        Assert.Equal("这个按钮太小了。", Assert.Single(said[2]).Text);
    }

    [Fact]
    public void FillersAreLeftOut()
    {
        var e = new BoardEvidence { Speech = { new(1, 2, "嗯。"), new(2.1, 3, "改大一点。") } };
        var said = e.Said(new[] { Mark(1, 1, 3) }, Array.Empty<string>());
        Assert.Equal("改大一点。", Assert.Single(said[1]).Text);
    }

    [Fact]
    public void HalfSentenceFollowsTheRest()
    {
        var e = new BoardEvidence { Speech = { new(0, 1, "然后这些"), new(1.2, 3, "这些按钮吧，让它居中。") } };
        var said = e.Said(new[] { Mark(1, 1.5, 2.5) }, Array.Empty<string>());
        Assert.Equal(2, said[1].Count);
    }

    [Fact]
    public void EvidenceRoundTripsWithMacKeys()
    {
        var e = new BoardEvidence();
        e.Visits.Add(new BoardVisit { PageID = "A", App = "Edge", Title = "t", Start = new(1, null), End = new(2, 1.5) });
        e.Inputs = new() { new BoardInput { Kind = BoardInputKind.scroll, At = 1, Dy = -3 } };
        var dir = Directory.CreateTempSubdirectory().FullName;
        e.Save(dir);
        var json = File.ReadAllText(Path.Combine(dir, BoardEvidence.Filename));
        Assert.Contains("\"pageID\"", json);
        Assert.Contains("\"speechTimingSource\"", json);
        Assert.Contains("\"kind\": \"scroll\"", json);
        Assert.DoesNotContain("\"audio\": null", json);
        var back = BoardEvidence.Load(dir)!;
        Assert.Equal(1.5, back.Visits[0].End.Audio);
        Assert.Null(back.Visits[0].Start.Audio);
    }

    [Fact]
    public void Stamps() => Assert.Equal("01:05.5", BoardEvidence.Stamp(65.5));

    [Fact]
    public void ClockLeavesPausesOut()
    {
        var c = new BoardCaptureClock(10);
        c.Pause(12); c.Resume(20);
        Assert.Equal(5, c.Elapsed(23), 3);
    }
}

public class TranscriptTests
{
    [Fact]
    public void KeepsSettledUtteranceWhenRecognizerStartsOver()
    {
        var t = new BoardTranscript();
        t.Update("第一句", false, utteranceComplete: true);
        t.Update("第二句", false);
        Assert.Equal("第一句 第二句", t.Text);
    }

    [Fact]
    public void DeliveryEditIsExplicit()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        File.WriteAllText(Path.Combine(dir, "完整转写.txt"), "原文");
        Assert.Equal("原文", BoardDeliveryTranscript.Load(dir));
        BoardDeliveryTranscript.SaveEdit("", dir);
        Assert.Equal("", BoardDeliveryTranscript.Load(dir));
        BoardDeliveryTranscript.ClearEdit(dir);
        Assert.Equal("原文", BoardDeliveryTranscript.Load(dir));
    }
}

public class ExportTests
{
    [Fact]
    public void ReadableTextHasTranscriptPagesAndMarks()
    {
        var e = new BoardEvidence { Speech = { new(1, 3, "这里改成红色。") }, SpeechTimingSource = "original-audio-file" };
        e.Visits.Add(new BoardVisit { PageID = "P", App = "Edge", Title = "首页", Start = new(0, 0), End = new(5, 5) });
        var pages = new[] { new BoardReadablePage(new[] { @"C:\x\图1.png" }, new[] { "P" }, new[] { new BoardMarkEvidence(1, new(2, 2), new(2.5, 2.5)) }) };
        var text = BoardReadableExport.Text(pages, "这里改成红色。", e, terminal: true);
        Assert.Contains("1 张截图 · 1 个标记", text);
        Assert.Contains("**00:01.0–00:03.0**　这里改成红色。", text);
        Assert.Contains("### 图1 · Edge · 首页", text);
        Assert.Contains(@"图1：C:\x\图1.png", text);
        Assert.Contains("| 标记 1 | 00:02.0–00:02.5 | “这里改成红色。” |", text);
    }

    [Fact]
    public void FolderExportCopiesImagesInOrder()
    {
        var src = Directory.CreateTempSubdirectory().FullName;
        var a = Path.Combine(src, "a.png"); File.WriteAllBytes(a, new byte[] { 1 });
        var b = Path.Combine(src, "b.png"); File.WriteAllBytes(b, new byte[] { 2, 2 });
        var root = Directory.CreateTempSubdirectory().FullName;
        var bundle = BoardFolderExport.Create(root, new[] { new BoardReadablePage(new[] { a, b }, Array.Empty<string>(), Array.Empty<BoardMarkEvidence>()) }, "说的话", null);
        Assert.Equal(new byte[] { 2, 2 }, File.ReadAllBytes(Path.Combine(bundle.Directory, "图2.png")));
        Assert.True(File.Exists(Path.Combine(bundle.Directory, "说明.md")));
        Assert.Empty(Directory.GetDirectories(root, ".preparing-*"));
    }

    [Fact]
    public void FolderExportFailsCleanlyOnMissingImage()
    {
        var root = Directory.CreateTempSubdirectory().FullName;
        Assert.Throws<IOException>(() => BoardFolderExport.Create(root, new[] { new BoardReadablePage(new[] { @"C:\nope\missing.png" }, Array.Empty<string>(), Array.Empty<BoardMarkEvidence>()) }, "", null));
        Assert.Empty(Directory.GetFileSystemEntries(root));
    }
}

public class InkTests
{
    [Fact]
    public void RoughLoopSnapsToBox()
    {
        var pts = new List<Pt>();
        for (var x = 0; x <= 100; x += 5) pts.Add(new(x, 0));
        for (var y = 0; y <= 60; y += 5) pts.Add(new(100, y));
        for (var x = 100; x >= 0; x -= 5) pts.Add(new(x, 60));
        for (var y = 60; y >= 0; y -= 5) pts.Add(new(0, y));
        Assert.IsType<InkShape.Box>(InkFit.Fit(pts));
    }

    [Fact]
    public void StraightStrokeSnapsToLevelLine()
    {
        var pts = Enumerable.Range(0, 30).Select(i => new Pt(i * 5, i % 2)).ToList();
        var line = Assert.IsType<InkShape.Line>(InkFit.Fit(pts));
        Assert.Equal(line.A.Y, line.B.Y);
    }

    [Fact]
    public void BoxCornersAreDoubled() => Assert.Equal(10, InkFit.Points(new InkShape.Box(new InkRect(0, 0, 10, 10))).Count);

    [Fact]
    public void TapIsOnePoint()
    {
        var s = new InkStroke(new Pt(5, 5), InkTool.free, 0);
        Assert.Single(s.Kept());
    }
}

public class PageTests
{
    [Fact]
    public void PageRoundTripsThroughJson()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        var img = Path.Combine(dir, "标注-1.png"); File.WriteAllBytes(img, new byte[] { 1 });
        var page = new BoardPage
        {
            Images = { img }, Original = Path.Combine(dir, "原图-1.png"),
            Marks = { new() { new[] { 0.1, 0.2 }, new[] { 0.3, 0.4 } } },
            MarkEvidence = { new BoardMarkEvidence(3, new(1, 0.5), new(2, 1.5)) },
            ContextIDs = { "C" }, CapturedAt = 4.5, Included = false,
        };
        BoardPage.SaveAll(dir, new[] { page });
        var json = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, BoardPage.Filename)))!.AsArray()[0]!.AsObject();
        Assert.Equal("标注-1.png", json["images"]![0]!.GetValue<string>());
        Assert.Equal(new[] { "capturedAt", "componentOffsets", "components", "contextIDs", "footerTrim", "imageNeedsRepair", "images", "included",
            "lineWidth", "manuallySaved", "markEvidence", "marks", "original", "retainedFiles", "scene", "sourceFrames", "text" }, json.Select(k => k.Key).ToArray());
        var back = Assert.Single(BoardPage.LoadAll(dir));
        Assert.Equal(0.3, back.Marks[0][1][0]);
        Assert.Equal(3, back.MarkEvidence[0].Number);
        Assert.False(back.Included);
        Assert.Equal(4.5, back.CapturedAt);
    }

    [Fact]
    public void MarkSheetHitsBadgeFirst()
    {
        var sheet = new BoardMarkSheet(new[] { new List<double[]> { new[] { 0.5, 0.5 }, new[] { 0.9, 0.5 } } }, new[] { new BoardMarkEvidence(7) }, 8);
        var c = BoardMarkSheet.BadgeCenter(sheet.Marks[0].Points, 100, 100, 22)!.Value;
        Assert.Equal(7, sheet.Hit(c, 100, 100, 4, 18, 22));
        Assert.Null(sheet.Hit(new Pt(10, 90), 100, 100, 4, 18, 22));
    }
}

public class PagingTests
{
    static BoardFrameFingerprint Flat(byte v) => new(Enumerable.Repeat(v, 64 * 40).ToArray());

    [Fact]
    public void ContextChangeLeavesThenSettles()
    {
        var g = new BoardPageGate();
        Assert.Equal(BoardPageGate.Decision.Reference, g.Observe(Flat(10), "a", 0));
        Assert.Equal(BoardPageGate.Decision.Leave, g.Observe(Flat(10), "b", 1));
        Assert.Equal(BoardPageGate.Decision.Settling, g.Observe(Flat(10), "b", 1.1));
        Assert.Equal(BoardPageGate.Decision.Reference, g.Observe(Flat(10), "b", 1.5));
    }

    [Fact]
    public void MaskIgnoresMovingWidget()
    {
        var a = Flat(100); var bv = (byte[])a.Values.Clone();
        for (var i = 0; i < 64; i++) bv[i] = 200;
        var b = new BoardFrameFingerprint(bv);
        var mask = new BoardMotionMask();
        mask.Learn(a, b);
        Assert.True(mask.Usable);
        Assert.Equal(0, mask.Distance(a, b));
        Assert.True(mask.Touches(new List<double[]> { new[] { 0.5, 0.0 } }));
    }
}
