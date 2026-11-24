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

    /// a take ended here (the microphone was turned off, or the recording paused): what follows is a new paragraph
    const string Take = "\n";

    public string Text => Join(finished.Append(hypothesis));

    /// Parts joined as one text: a space between them (each piece of recognition ends at a pause), none after a
    /// sentence mark of Chinese or Japanese, which carries its own pause; an empty line between takes.
    public static string Join(IEnumerable<string> parts)
    {
        var text = new System.Text.StringBuilder();
        var take = false;
        foreach (var part in parts)
        {
            if (part == Take) { take = text.Length > 0; continue; }
            var p = part.Trim();
            if (p.Length == 0) continue;
            if (text.Length > 0) text.Append(take ? "\n\n" : "，。！？；：、）」』”…".Contains(text[^1]) ? "" : " ");
            take = false;
            text.Append(p);
        }
        return text.ToString();
    }

    /// The silence written between two takes of a recording (seconds): longer than any pause the recognisers' cutting
    /// bridges (transcribe.py: SenseVoice joins speech across up to 1.0 s, a pause of about 1.55 s always ends a piece),
    /// so no piece of recognition holds the end of one take and the start of the next.
    public const double TakeGap = 2.0;

    /// The recording's segments as one text with an empty line where a take begins (`breaks`: its seconds, each just
    /// after its gap). A segment starting in the gap or later is the new take's: a model that is handed whole spans
    /// (Fun-ASR-Nano) starts its piece in the middle of the gap, one that is handed the VAD's speech just before the words.
    public static string WithTakes(IEnumerable<BoardSpeechSegment> segments, IReadOnlyList<double> breaks)
    {
        var parts = new List<string>();
        var next = 0;
        var ordered = breaks.OrderBy(b => b).ToList();
        foreach (var s in segments.OrderBy(s => s.Start))
        {
            var newTake = false;
            while (next < ordered.Count && s.Start >= ordered[next] - TakeGap - 0.05) { next++; newTake = true; }
            if (newTake) parts.Add(Take);
            parts.Add(s.Text);
        }
        return Join(parts);
    }

    /// A take ends: what is recognised next starts a new paragraph. The recogniser still owes the take's last words
    /// (its final version of the piece it was hearing comes after the pause), so the paragraph ends with that final
    /// version — or, when none comes, at the next take's first words.
    public void Break()
    {
        if (finished.Count > 0 || hypothesis.Length > 0) takePending = true;
    }

    bool takePending;

    void EndTake()
    {
        takePending = false;
        if (finished.Count > 0 && finished[^1] != Take) finished.Add(Take);
    }
    public string PageText { get { var t = Text; return t[Math.Min(pageOffset, t.Length)..]; } }

    public void Update(string words, bool final, bool utteranceComplete = false)
    {
        var next = words.Trim();
        if (takePending && next.Length > 0)
        {
            if (final) { hypothesis = next; Commit(); EndTake(); return; }   // the ended take's last words
            Commit(); EndTake();                                               // the next take has begun
        }
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
        if (hypothesis.Length > 0 && hypothesis != Take) finished.Add(hypothesis);
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
