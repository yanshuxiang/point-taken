// Runs the bundled Python CLIs (transcribe.py, board_live.py) with uv, like the macOS app's ScriptRunner. The app never
// bundles Python: uv fetches the interpreter and the declared packages on first use (each script's inline metadata).
// uv is looked for on PATH, then in ~/.point-taken/bin, then in ~/.local/bin. A failing CLI answers {"ok": false, "code": …}.
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace PointTaken.Core;

public sealed class ScriptFailure : Exception
{
    public string Code { get; }
    public ScriptFailure(string code, string message) : base(message) { Code = code; }
}

public static class ScriptRunner
{
    /// Extra variables for every script (the cloud keys the user saved; the app sets this at launch).
    public static Func<IDictionary<string, string>>? ExtraEnvironment;
    /// Called with every child process the app starts, so the app can tie it to its own lifetime (a job object).
    public static Action<Process>? Adopt;

    public static string? UvPath
    {
        get
        {
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                try { var p = Path.Combine(dir.Trim('"'), "uv.exe"); if (File.Exists(p)) return p; } catch { }
            }
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            foreach (var p in new[] { Path.Combine(Paths.Home, "bin", "uv.exe"), Path.Combine(home, ".local", "bin", "uv.exe"), Path.Combine(home, ".cargo", "bin", "uv.exe") })
                if (File.Exists(p)) return p;
            return null;
        }
    }

    public static string ScriptPath(string name)
    {
        var p = Path.Combine(Paths.Scripts, name);
        if (!File.Exists(p)) throw new ScriptFailure("no_scripts", "script not found: " + p);
        return p;
    }

    public static ProcessStartInfo StartInfo(string script, IEnumerable<string> args, string? cwd = null)
    {
        var uv = UvPath ?? throw new ScriptFailure("no_uv", "uv not found");
        var info = new ProcessStartInfo(uv)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = cwd ?? Paths.Scripts,
        };
        foreach (var a in new[] { "run", "-q", ScriptPath(script) }.Concat(args)) info.ArgumentList.Add(a);
        var env = info.Environment;
        env["PYTHONIOENCODING"] = "utf-8";
        env["PYTHONUTF8"] = "1";
        env["POINT_TAKEN_APP"] = "1";
        env["POINT_TAKEN_HOME"] = Paths.Home;
        env["POINT_TAKEN_WORKSPACE"] = Paths.Workspace;
        // uv's own cache and Python downloads go where uv normally keeps them unless the user chose otherwise
        foreach (var kv in ExtraEnvironment?.Invoke() ?? new Dictionary<string, string>()) env[kv.Key] = kv.Value;
        return info;
    }

    public static Process Start(string script, IEnumerable<string> args, string? cwd = null)
    {
        var p = Process.Start(StartInfo(script, args, cwd)) ?? throw new ScriptFailure("error", "could not start " + script);
        Adopt?.Invoke(p);
        return p;
    }

    /// Runs a CLI to the end; returns stdout. Throws ScriptFailure on a timeout or a non-zero exit (with the CLI's code).
    public static async Task<string> RunAsync(string script, IEnumerable<string> args, TimeSpan timeout, CancellationToken cancel = default,
                                              Action<string>? stderrLine = null)
    {
        using var p = Start(script, args);
        p.StandardInput.Close();
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var outTask = Task.Run(async () => { string? l; while ((l = await p.StandardOutput.ReadLineAsync()) != null) stdout.AppendLine(l); });
        var errTask = Task.Run(async () =>
        {
            string? l;
            while ((l = await p.StandardError.ReadLineAsync()) != null) { lock (stderr) stderr.AppendLine(l); stderrLine?.Invoke(l); }
        });
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(timeout);
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            throw new ScriptFailure(cancel.IsCancellationRequested ? "cancelled" : "timeout", $"{script} timed out");
        }
        await Task.WhenAll(outTask, errTask);
        var text = stdout.ToString();
        if (p.ExitCode != 0)
        {
            var o = LastJson(text);
            throw new ScriptFailure(Json.String(o?["code"]) ?? "failed", Json.String(o?["error"]) ?? Tail(stderr.ToString()));
        }
        return text;
    }

    /// RunAsync for the {"ok": …} CLIs: the decoded object, or a ScriptFailure carrying the CLI's code.
    public static async Task<JsonObject> CallAsync(string script, IEnumerable<string> args, TimeSpan timeout, CancellationToken cancel = default,
                                                   Action<string>? stderrLine = null)
    {
        var text = await RunAsync(script, args, timeout, cancel, stderrLine);
        var o = LastJson(text);
        if (o == null || Json.Bool(o["ok"]) != true)
            throw new ScriptFailure(Json.String(o?["code"]) ?? "failed", Json.String(o?["error"]) ?? script + " failed");
        return o;
    }

    /// The last JSON object a CLI printed.
    public static JsonObject? LastJson(string text)
    {
        foreach (var line in text.Split('\n').Reverse())
        {
            var t = line.Trim();
            if (!t.StartsWith('{')) continue;
            try { if (JsonNode.Parse(t) is JsonObject o) return o; } catch { }
        }
        return null;
    }

    static string Tail(string s) => s.Length > 500 ? s[^500..] : s;
}

/// Only allowlisted request metadata is saved (转写调用.json / 实时调用.json); audio, text and credentials stay out.
public static class BoardModelStatus
{
    public static string Name(string? id) => id switch
    {
        "volcengine-seedasr" => "豆包 Seed-ASR 2.0",
        "sensevoice-small" => "SenseVoice Small（本机）",
        "board-apple-speech" => "苹果系统识别",
        null or "" => "未记录模型",
        _ => id,
    };

    /// A failed call's code as a sentence people can act on.
    public static string FailureText(string? code) => code switch
    {
        "no_scripts" => "找不到转写脚本，安装不完整，请重新安装" + PointTakenInfo.NameZh,
        "no_uv" => "缺少运行转写需要的 uv，请在设置 → 模型与 API 里安装",
        "auth" => "API 密钥无效或没有权限",
        "network" => "网络连接失败",
        "privacy" => "已设置只用本机，云端语音被关闭",
        "unknown_model" => "所选模型不存在",
        "model_missing" or "not_installed" or "no_model" or "missing" => "所选模型还没下载，请在设置 → 模型与 API 里下载",
        "unsupported_language" => "所选模型不支持这种语言",
        "timeout" => "处理超时",
        "quota" => "API 额度不足",
        "audio" => "音频无法读取",
        "bad_response" or "incomplete_response" => "模型返回不完整",
        _ => "转写失败" + (string.IsNullOrEmpty(code) ? "" : $"（{code}）"),
    };

    public static void WriteReceipt(string audio, string state, string model, JsonObject? response = null, string filename = "转写调用.json")
    {
        var fields = new JsonObject { ["state"] = state, ["model"] = model, ["updatedAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 };
        foreach (var (source, target) in new[] { ("model", "actualModel"), ("provider", "provider"), ("service_model", "serviceModel"), ("request_id", "requestID"), ("code", "code") })
            if (Json.String(response?[source]) is { } v) fields[target] = v;
        try { AtomicFile.WriteJson(Path.Combine(Path.GetDirectoryName(audio)!, filename), Json.Sorted(fields)!); } catch { }
    }

    public static JsonObject? Read(string path) => Json.ReadObject(path);

    public static string Result(JsonObject state, JsonObject? receipt)
    {
        var model = Name(Json.String(state["model"]));
        switch (Json.String(state["state"]))
        {
            case "recording": return "本次：尚未调用完整转写 · " + model;
            case "finalizing": return "本次：正在完整转写 · " + model;
            case "complete":
                if (Json.String(receipt?["state"]) == "failed") return "最近记录：完整转写未完成 · " + model;
                return "最近记录：已完成 · " + model;
            case "incomplete":
                var warning = Json.String(state["warning"]) ?? "";
                return warning.Contains("可从历史重新转写") ? "最近记录：退出时保存，完整转写未完成" : "最近记录：完整转写未完成 · " + model;
            default: return "最近记录：未记录转写结果";
        }
    }
}
