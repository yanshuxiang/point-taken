// One annotation record on disk (~/Point Taken/连标/<time>/): its pages, timeline and transcripts, and the notes
// written from them. Shared by the live session, the review window and History, so every path writes the same files.
using System.Windows.Media.Imaging;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class BoardRecord
{
    public string Directory { get; }
    public List<BoardPage> Pages { get; set; } = new();
    public BoardEvidence? Evidence { get; set; }
    /// what recognition produced (完整转写.txt)
    public string OriginalTranscript { get; set; } = "";
    /// the user's explicit edit in the review window; null: none
    public string? ReviewedTranscript { get; set; }
    public string DeliveryTranscript => ReviewedTranscript ?? OriginalTranscript;
    readonly Dictionary<string, BitmapSource> thumbs = new(StringComparer.OrdinalIgnoreCase);

    public BoardRecord(string directory) { Directory = directory; }

    public string AudioPath => Path.Combine(Directory, "原始录音.wav");
    public DateTime? Date => DateTime.TryParseExact(Path.GetFileName(Directory), Paths.SessionStampFormat, null, System.Globalization.DateTimeStyles.None, out var d) ? d : null;

    public static BoardRecord Load(string directory)
    {
        var r = new BoardRecord(directory)
        {
            Pages = BoardPage.LoadAll(directory),
            Evidence = BoardEvidence.Load(directory),
        };
        var full = Path.Combine(directory, "完整转写.txt");
        r.OriginalTranscript = File.Exists(full) ? File.ReadAllText(full) : "";
        if (BoardDeliveryTranscript.HasEdit(directory)) r.ReviewedTranscript = BoardDeliveryTranscript.Load(directory);
        else
        {
            var delivered = Path.Combine(directory, "交付转写.txt");
            if (File.Exists(delivered) && File.ReadAllText(delivered) is { } t && !string.IsNullOrWhiteSpace(t) && t != r.OriginalTranscript) r.ReviewedTranscript = t;
        }
        return r;
    }

    public BitmapSource? Thumb(BoardPage page)
    {
        if (page.Images.Count == 0) return null;
        var key = page.Images[0];
        if (thumbs.TryGetValue(key, out var t)) return t;
        var loaded = MarkRenderer.Thumbnail(key) ?? (page.Original is { } o ? MarkRenderer.Thumbnail(o) : null);
        if (loaded != null) thumbs[key] = loaded;
        return loaded;
    }

    public void SetThumb(BoardPage page, BitmapSource thumb)
    {
        if (page.Images.Count > 0) thumbs[page.Images[0]] = thumb;
    }

    public void ForgetThumb(BoardPage page)
    {
        if (page.Images.Count > 0) thumbs.Remove(page.Images[0]);
    }

    /// 说明.md, 页面.json, 时间线.json and the edited transcript, through the serial writer.
    public void WriteNotes()
    {
        var dir = Directory;
        var pages = Pages.Select(p => p.Clone()).ToList();
        var transcript = DeliveryTranscript;
        var evidence = Evidence?.Clone();
        var reviewed = ReviewedTranscript;
        if (evidence != null) BoardFileWriter.Enqueue(Path.Combine(dir, BoardEvidence.Filename), () => { try { evidence.Save(dir); return true; } catch { return false; } });
        BoardFileWriter.Text(Path.Combine(dir, "说明.md"), () =>
            BoardReadableExport.Text(BoardPage.Readable(pages), transcript, evidence) + "\n\n" + BoardPage.Markdown(pages));
        BoardFileWriter.Enqueue(Path.Combine(dir, BoardPage.Filename), () => { try { BoardPage.SaveAll(dir, pages); return true; } catch { return false; } });
        if (reviewed != null)
            BoardFileWriter.Enqueue(Path.Combine(dir, "交付转写.txt"), () => { try { BoardDeliveryTranscript.SaveEdit(reviewed, dir); return true; } catch { return false; } });
    }

    public static IEnumerable<string> Files(IEnumerable<BoardPage> pages) => pages.SelectMany(p => p.AllFiles);

    /// The hand-off text for the clipboard (no export folder: images as attachment numbers).
    public string HandoffText(IEnumerable<BoardPage>? pages = null) =>
        BoardReadableExport.Text(BoardPage.Readable(pages ?? Pages), DeliveryTranscript, Evidence);

    public BoardFolderExport.Bundle Export(IEnumerable<BoardPage>? pages = null) =>
        BoardFolderExport.Create(Paths.Exports, BoardPage.Readable(pages ?? Pages), DeliveryTranscript, Evidence);

    /// The state line History shows for this record.
    public string StateLine()
    {
        var state = BoardModelStatus.Read(Path.Combine(Directory, "转写状态.json"));
        if (state == null) return "";
        return BoardModelStatus.Result(state, BoardModelStatus.Read(Path.Combine(Directory, "转写调用.json")))
            .Replace("最近记录：", "").Replace("本次：", "");
    }
}
