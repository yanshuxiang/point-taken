// Cloud speech keys, kept per Windows user with DPAPI (the macOS app uses the keychain). Handed to the scripts as the
// environment variables they read (VOLC_APP_ID, VOLC_ACCESS_TOKEN, DASHSCOPE_API_KEY, POINT_TAKEN_ASR_*), never
// written to config.json, logs or the records.
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PointTaken.Core;

namespace PointTaken.App;

public static class Secrets
{
    static string File => Path.Combine(Paths.Home, "secrets.dat");
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("point-taken windows secrets v1");
    static readonly object gate = new();

    /// The variables the speech services read, and what Settings calls them.
    public static readonly (string Variable, string Label, bool Secret)[] Known =
    {
        ("VOLC_APP_ID", "豆包 App ID", false),
        ("VOLC_ACCESS_TOKEN", "豆包 Access Token", true),
        ("DASHSCOPE_API_KEY", "阿里云百炼 API Key", true),
        ("POINT_TAKEN_ASR_API_KEY", "OpenAI 兼容 API Key", true),
        ("POINT_TAKEN_ASR_BASE_URL", "OpenAI 兼容服务地址", false),
        ("POINT_TAKEN_ASR_MODEL", "OpenAI 兼容模型名", false),
    };

    public static Dictionary<string, string> All()
    {
        lock (gate)
        {
            try
            {
                if (!System.IO.File.Exists(File)) return new();
                var plain = ProtectedData.Unprotect(System.IO.File.ReadAllBytes(File), Entropy, DataProtectionScope.CurrentUser);
                return JsonSerializer.Deserialize<Dictionary<string, string>>(plain) ?? new();
            }
            catch { return new(); }
        }
    }

    public static string? Get(string variable) => All().GetValueOrDefault(variable);

    public static void Set(string variable, string? value)
    {
        lock (gate)
        {
            var all = All();
            if (string.IsNullOrWhiteSpace(value)) all.Remove(variable); else all[variable] = value.Trim();
            Directory.CreateDirectory(Paths.Home);
            var data = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(all), Entropy, DataProtectionScope.CurrentUser);
            AtomicFile.WriteBytes(File, data);
        }
    }

    /// For ScriptRunner.ExtraEnvironment.
    public static IDictionary<string, string> Environment() => All();
}

/// Messages that would otherwise pop up while idle: kept here and shown in Settings → 消息 (nothing floats).
public static class Notices
{
    public sealed record Notice(DateTime At, string Text);
    static readonly List<Notice> items = new();
    public static event Action? Changed;
    public static IReadOnlyList<Notice> Items { get { lock (items) return items.ToList(); } }

    public static void Clear()
    {
        lock (items) items.Clear();
        Changed?.Invoke();
    }

    public static void Post(string text)
    {
        lock (items)
        {
            items.Insert(0, new Notice(DateTime.Now, text));
            if (items.Count > 100) items.RemoveAt(items.Count - 1);
        }
        Changed?.Invoke();
    }
}
