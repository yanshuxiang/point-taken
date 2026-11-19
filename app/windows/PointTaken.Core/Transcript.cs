// The running transcript (live partials and finished sentences), the user's review edit kept apart from recognition,
// and the plain hand-off text for records without a timeline. Ported from BoardArchive.swift.
using System.Text.Json.Nodes;

namespace PointTaken.Core;

public sealed class BoardTranscript
{
    readonly List<string> finished = new();
    string hypothesis = "";
    bool utteranceComplete;
    int pageOffset;

    public string Text => string.Join(" ", finished.Append(hypothesis).Where(s => s.Length > 0));
    public string PageText { get { var t = Text; return t[Math.Min(pageOffset, t.Length)..]; } }

    public void Update(string words, bool final, bool utteranceComplete = false)
    {
        var next = words.Trim();
        if (next.Length > 0)
        {
            if (this.utteranceComplete && next != hypothesis && !next.StartsWith(hypothesis, StringComparison.Ordinal)) Commit();
            if (next != hypothesis) this.utteranceComplete = false;
            hypothesis = next;
        }
        if (utteranceComplete) this.utteranceComplete = true;
        if (final) Commit();
    }

    public void Commit()
    {
        if (hypothesis.Length > 0) finished.Add(hypothesis);
        hypothesis = "";
        utteranceComplete = false;
    }

    /// A completed file transcription covers the whole recording.
    public void ReplaceWithFileTranscript(string words)
    {
        finished.Clear();
        finished.Add(words);
        hypothesis = "";
        utteranceComplete = false;
    }

    public string MarkPage()
    {
        var result = PageText.Trim();
        pageOffset = Text.Length;
        return result;
    }
}

public static class BoardExport
{
    public static string Text(string transcript, IReadOnlyList<string> images, bool terminal)
    {
        var parts = new List<string>();
        if (transcript.Length > 0) parts.Add("完整语音转写（含背景说明）：\n" + transcript);
        if (images.Count > 0)
            parts.Add("标注截图：\n" + string.Join("\n", images.Select((path, i) => $"图{i + 1}" + (terminal ? "：" + path : $"：第 {i + 1} 张附件"))));
        return string.Join("\n\n", parts);
    }
}

/// Explicit review edits are separate from recognition: 转写编辑.json marks a deliberate edit (an empty one too).
public static class BoardDeliveryTranscript
{
    public static string Load(string directory)
    {
        var edit = Json.ReadObject(Path.Combine(directory, "转写编辑.json"));
        if (edit != null && Json.Bool(edit["userEdited"]) == true && Json.String(edit["text"]) is { } text) return text;
        var delivered = Path.Combine(directory, "交付转写.txt");
        if (File.Exists(delivered))
        {
            var t = File.ReadAllText(delivered);
            if (!string.IsNullOrWhiteSpace(t)) return t;
        }
        var full = Path.Combine(directory, "完整转写.txt");
        return File.Exists(full) ? File.ReadAllText(full) : "";
    }

    public static bool HasEdit(string directory)
    {
        var edit = Json.ReadObject(Path.Combine(directory, "转写编辑.json"));
        return edit != null && Json.Bool(edit["userEdited"]) == true;
    }

    public static void SaveEdit(string text, string directory)
    {
        AtomicFile.WriteJson(Path.Combine(directory, "转写编辑.json"), Json.Sorted(new JsonObject { ["userEdited"] = true, ["text"] = text })!);
        AtomicFile.WriteText(Path.Combine(directory, "交付转写.txt"), text);
    }

    /// "恢复原始转写": the edit is dropped; the original recognition is used again.
    public static void ClearEdit(string directory)
    {
        foreach (var f in new[] { "转写编辑.json", "交付转写.txt" })
        {
            try { File.Delete(Path.Combine(directory, f)); } catch { /* keep going */ }
        }
    }
}
