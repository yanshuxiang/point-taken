// The speech models this PC can use (transcribe.py models), read once in the background and kept: the tray's
// 识别模型 submenu and Settings → 模型与 API list them (SpeechModel.shared in the macOS app).
using System.Text.Json.Nodes;
using PointTaken.App.Capture;
using PointTaken.Core;

namespace PointTaken.App;

public sealed record SpeechModelInfo(string Id, string Name, bool Local, bool Installed, bool RunsHere, double SizeMb, string Role, bool Default);

public static class SpeechModels
{
    public static IReadOnlyList<SpeechModelInfo> Models { get; private set; } = Array.Empty<SpeechModelInfo>();
    public static bool Loading { get; private set; }
    public static string? Error { get; private set; }
    public static bool LocalOnly { get; private set; }
    public static event Action? Changed;
    static Task? running;

    public static Task Load()
    {
        if (running != null) return running;
        Loading = true;
        Changed?.Invoke();
        running = Task.Run(async () =>
        {
            try
            {
                var o = await ScriptRunner.CallAsync("transcribe.py", new[] { "models" }, TimeSpan.FromMinutes(6));
                LocalOnly = Json.Bool(o["local_only"]) == true;
                Models = (o["models"] as JsonArray ?? new()).OfType<JsonObject>().Select(m => new SpeechModelInfo(
                    Json.String(m["id"]) ?? "", Json.String(m["name"]) ?? Json.String(m["id"]) ?? "", Json.Bool(m["local"]) != false,
                    Json.Bool(m["installed"]) == true, Json.Bool(m["runs_here"]) != false, Json.Double(m["size_mb"]) ?? 0,
                    Json.String(m["role"]) ?? "asr", Json.Bool(m["default"]) == true)).ToList();
                Error = null;
            }
            catch (ScriptFailure e) { Error = BoardModelStatus.FailureText(e.Code); }
            catch (Exception e) { Error = e.Message; }
            finally
            {
                Loading = false;
                running = null;
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => Changed?.Invoke());
            }
        });
        return running;
    }

    /// The models the tray and the Settings picker offer: speech models that run here and are ready (downloaded, or
    /// a cloud service with its key), plus the one selected now.
    public static List<SpeechModelInfo> Choices(string current)
    {
        var list = Models.Where(m => m.Role == "asr" && m.RunsHere && m.Installed && (m.Local || !LocalOnly)).ToList();
        if (list.All(m => m.Id != current)) list.Add(Find(current));
        return list;
    }

    public static SpeechModelInfo Find(string id) =>
        Models.FirstOrDefault(m => m.Id == id) ?? new SpeechModelInfo(id, BoardModelStatus.Name(id), id != "volcengine-seedasr" && !id.Contains("flash") && id != "openai-compatible", false, true, 0, "asr", false);

    public static string Title(string id) => id == "volcengine-seedasr" ? BoardModelStatus.Name(id) : Find(id).Name;
    public static bool IsLocal(string id) => Find(id).Local;
}
