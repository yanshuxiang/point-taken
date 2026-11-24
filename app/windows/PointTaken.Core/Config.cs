// ~/.point-taken/config.json, shared with the Python scripts (they read record.*, asr.*, …). Only the keys the app
// changes are written; everything else in the file is kept as it is. A file that does not parse is never overwritten
// (the scripts keep running on their defaults and the user's text survives).
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PointTaken.Core;

public sealed class Config
{
    public static Config Shared { get; } = new(() => Paths.ConfigFile);

    readonly Func<string> path;
    readonly object gate = new();
    JsonObject? cached;
    (DateTime, long)? signature;
    public bool Readable { get; private set; } = true;

    public Config(Func<string> path) { this.path = path; }

    JsonObject Load()
    {
        lock (gate)
        {
            var file = path();
            var info = new FileInfo(file);
            var sig = info.Exists ? (info.LastWriteTimeUtc, info.Length) : (DateTime.MinValue, -1L);
            if (cached != null && signature == sig) return cached;
            signature = sig;
            if (!info.Exists) { Readable = true; return cached = new JsonObject(); }
            try
            {
                var node = JsonNode.Parse(File.ReadAllText(file), documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
                Readable = node is JsonObject;
                return cached = node as JsonObject ?? new JsonObject();
            }
            catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
            {
                Readable = false;
                return cached = new JsonObject();
            }
        }
    }

    /// Whether the file changed since it was last read (a stat: cheap enough for a timer).
    public bool ReloadIfChanged()
    {
        lock (gate)
        {
            var info = new FileInfo(path());
            var sig = info.Exists ? (info.LastWriteTimeUtc, info.Length) : (DateTime.MinValue, -1L);
            if (signature == sig) return false;
        }
        Load();
        return true;
    }

    public JsonNode? Get(string dotted)
    {
        JsonNode? node = Load();
        foreach (var part in dotted.Split('.'))
        {
            if (node is not JsonObject o || !o.TryGetPropertyValue(part, out node)) return null;
        }
        return node?.DeepClone();
    }

    public string? GetString(string dotted) => Get(dotted) is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public bool? GetBool(string dotted) => Get(dotted) is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
    public int? GetInt(string dotted) => Get(dotted) is JsonValue v && v.TryGetValue<int>(out var i) ? i : null;

    /// Sets (or with null removes) one dotted key and writes the file atomically. False when the file could not be
    /// read as JSON (it is left alone) or could not be written.
    public bool Set(string dotted, JsonNode? value)
    {
        lock (gate)
        {
            var root = Load();
            if (!Readable) return false;
            root = (JsonObject)root.DeepClone();
            var parts = dotted.Split('.');
            var o = root;
            for (var i = 0; i < parts.Length - 1; i++)
            {
                if (o[parts[i]] is not JsonObject child) { child = new JsonObject(); o[parts[i]] = child; }
                o = child;
            }
            if (value is null) o.Remove(parts[^1]); else o[parts[^1]] = value.DeepClone();
            try
            {
                var file = path();
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                AtomicFile.WriteText(file, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
                cached = null; signature = null;
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        }
    }

    public bool Set(string dotted, string? value) => Set(dotted, value is null ? null : JsonValue.Create(value));
    public bool Set(string dotted, bool? value) => Set(dotted, value is null ? null : JsonValue.Create(value.Value));
}

/// Write to a temporary file next to the target, then replace it: a reader never sees half a file.
public static class AtomicFile
{
    public static void WriteText(string path, string text) => WriteBytes(path, new System.Text.UTF8Encoding(false).GetBytes(text));

    public static void WriteBytes(string path, byte[] data)
    {
        var dir = Path.GetDirectoryName(path)!;
        var tmp = Path.Combine(dir, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, path, overwrite: true);
        }
        finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { /* best effort */ } }
    }

    public static void WriteJson(string path, JsonNode node) =>
        WriteText(path, node.ToJsonString(Json.Pretty));
}

public static class Json
{
    /// Pretty, keys as given, CJK kept readable (the records are read by people too).
    public static readonly JsonSerializerOptions Pretty = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// Sorted keys, like the macOS app's JSONSerialization(.sortedKeys): the same record diffs the same.
    public static JsonNode? Sorted(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject o:
                var sorted = new JsonObject();
                foreach (var kv in o.OrderBy(k => k.Key, StringComparer.Ordinal)) sorted[kv.Key] = Sorted(kv.Value?.DeepClone());
                return sorted;
            case JsonArray a:
                var arr = new JsonArray();
                foreach (var item in a) arr.Add(Sorted(item?.DeepClone()));
                return arr;
            default:
                return node?.DeepClone();
        }
    }

    public static JsonObject? ReadObject(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject; }
        catch { return null; }
    }

    public static double? Double(JsonNode? n) =>
        n is JsonValue v ? (v.TryGetValue<double>(out var d) ? d : v.TryGetValue<int>(out var i) ? i : v.TryGetValue<long>(out var l) ? l : null) : null;
    public static string? String(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public static bool? Bool(JsonNode? n) => n is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
    public static int? Int(JsonNode? n) => n is JsonValue v ? (v.TryGetValue<int>(out var i) ? i : v.TryGetValue<double>(out var d) && d == Math.Floor(d) ? (int)d : null) : null;
}
