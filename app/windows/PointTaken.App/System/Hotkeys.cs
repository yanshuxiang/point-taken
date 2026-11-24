// Keyboard shortcuts. The start shortcut (Alt+N by default, record.board.start_key) is a global hotkey registered only
// while idle: during a recording every key belongs to the app being marked up. The hold-to-draw keys are modifiers
// only (Ctrl = freehand, Ctrl+Shift = box by default, record.board.hold_keys.*): watched, never taken from the app in
// front. Ctrl rather than the macOS ⌥: on Windows a lone Alt press opens the menu bar of the app below.
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App;

public readonly record struct KeyCombo(bool Ctrl, bool Alt, bool Shift, bool Win, Key Key)
{
    public bool ModifiersOnly => Key == Key.None;

    public override string ToString()
    {
        var parts = new List<string>();
        if (Ctrl) parts.Add("Ctrl");
        if (Alt) parts.Add("Alt");
        if (Shift) parts.Add("Shift");
        if (Win) parts.Add("Win");
        if (Key != Key.None) parts.Add(KeyName(Key));
        return string.Join("+", parts);
    }

    static string KeyName(Key k) => k switch
    {
        >= Key.D0 and <= Key.D9 => ((int)(k - Key.D0)).ToString(),
        Key.OemTilde => "`", Key.OemMinus => "-", Key.OemPlus => "=", Key.Space => "Space", Key.Return => "Enter",
        _ => k.ToString(),
    };

    public static KeyCombo? Parse(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        bool c = false, a = false, sh = false, w = false; var key = Key.None;
        foreach (var raw in s.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl": case "control": c = true; break;
                case "alt": a = true; break;
                case "shift": sh = true; break;
                case "win": w = true; break;
                case "`": key = Key.OemTilde; break;
                case "-": key = Key.OemMinus; break;
                case "=": key = Key.OemPlus; break;
                case "enter": key = Key.Return; break;
                default:
                    if (raw.Length == 1 && char.IsDigit(raw[0])) key = Key.D0 + (raw[0] - '0');
                    else if (Enum.TryParse<Key>(raw, true, out var k)) key = k;
                    else return null;
                    break;
            }
        }
        if (!c && !a && !sh && !w && key == Key.None) return null;
        return new KeyCombo(c, a, sh, w, key);
    }

    public uint Mods => (Ctrl ? Native.MOD_CONTROL : 0) | (Alt ? Native.MOD_ALT : 0) | (Shift ? Native.MOD_SHIFT : 0) | (Win ? Native.MOD_WIN : 0);
    public uint VirtualKey => (uint)KeyInterop.VirtualKeyFromKey(Key);
}

public static class HotkeySettings
{
    public static readonly KeyCombo DefaultStart = new(false, true, false, false, Key.N);
    public static readonly Dictionary<InkTool, KeyCombo> DefaultHold = new()
    {
        [InkTool.free] = new KeyCombo(true, false, false, false, Key.None),
        [InkTool.box] = new KeyCombo(true, false, true, false, Key.None),
    };

    public static KeyCombo Start => KeyCombo.Parse(Config.Shared.GetString("record.board.start_key")) ?? DefaultStart;
    public static void SetStart(KeyCombo? k) => Config.Shared.Set("record.board.start_key", k?.ToString());

    public static KeyCombo Hold(InkTool tool) =>
        KeyCombo.Parse(Config.Shared.GetString("record.board.hold_keys." + tool)) is { ModifiersOnly: true } k ? k : DefaultHold.GetValueOrDefault(tool, DefaultHold[InkTool.free]);
    public static void SetHold(InkTool tool, KeyCombo? k) => Config.Shared.Set("record.board.hold_keys." + tool, k?.ToString());
}

/// Global hotkeys through RegisterHotKey on a message-only window.
public sealed class HotkeyCenter : IDisposable
{
    readonly HwndSource source;
    readonly Dictionary<int, Action> actions = new();
    int nextId = 1;

    public HotkeyCenter()
    {
        source = new HwndSource(new HwndSourceParameters("PointTakenHotkeys") { ParentWindow = new IntPtr(-3) /* HWND_MESSAGE */, Width = 0, Height = 0 });
        source.AddHook(WndProc);
    }

    IntPtr WndProc(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && actions.TryGetValue(w.ToInt32(), out var a)) { handled = true; a(); }
        return IntPtr.Zero;
    }

    /// Registers a hotkey; returns its id, or null when another program holds it.
    public int? Register(KeyCombo k, Action action)
    {
        if (k.ModifiersOnly) return null;
        var id = nextId++;
        if (!Native.RegisterHotKey(source.Handle, id, k.Mods | Native.MOD_NOREPEAT, k.VirtualKey)) return null;
        actions[id] = action;
        return id;
    }

    public void Unregister(int? id)
    {
        if (id is not { } i) return;
        Native.UnregisterHotKey(source.Handle, i);
        actions.Remove(i);
    }

    public void Dispose()
    {
        foreach (var id in actions.Keys.ToList()) Native.UnregisterHotKey(source.Handle, id);
        actions.Clear();
        source.Dispose();
    }
}

/// Hold-to-draw during a session: holding the freehand key turns on freehand (the box key the box) for as many strokes
/// as are drawn while it is held; letting go returns to what was on before. A quick tap (nothing drawn) arms the tool
/// for one stroke. A key pressed while the modifiers are down makes it a shortcut for the app in front: no pen then.
public sealed class HoldKeys
{
    public Func<InkTool, (bool ok, InkTool? before)>? Hold;
    public Action<InkTool?>? Release;
    public Action<InkTool>? Tap;
    const double Settle = 0.15, TapTime = 0.35;

    readonly DispatcherTimer timer;
    (InkTool tool, InkTool? before)? held;
    InkTool? pendingTool;
    double pendingSince;
    double pressedAt;
    bool shortcut;
    bool drewWhileHeld;
    public bool Holding => held != null;

    public HoldKeys()
    {
        timer = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(33) };
        timer.Tick += (_, _) => Poll();
    }

    public void Start() { held = null; pendingTool = null; shortcut = false; timer.Start(); }
    public void Stop() { timer.Stop(); held = null; pendingTool = null; }
    public void StrokeDrawn() { if (held != null) drewWhileHeld = true; }

    /// A non-modifier key went down somewhere: whatever modifiers are held now are a shortcut.
    public void KeyPressed(int vk)
    {
        if (Capture.ScreenFeed.IsModifier(vk)) return;
        if (Native.Down(Native.VK_CONTROL) || Native.Down(Native.VK_MENU) || Native.Down(Native.VK_LWIN) || Native.Down(Native.VK_RWIN))
            Interrupt();
    }

    /// The modifiers held now are a shortcut for the app in front (Ctrl+C, Ctrl+wheel): no pen for this press, and a
    /// pen the hold already turned on goes back to what was on before, so the overlay stops taking the mouse.
    public void Interrupt()
    {
        if (Match() == null) return;
        shortcut = true;
        pendingTool = null;
        if (held is { } h) { held = null; Release?.Invoke(h.before); }
    }

    /// Lets go of a held tool without restoring anything (the user picked a tool in the capsule).
    public void ReleaseHold() { held = null; pendingTool = null; }

    /// The tool whose keys are held down right now, unless they became a shortcut for the app in front.
    public InkTool? Pressed() => shortcut ? null : Match();

    /// The mouse went down with the keys held before the hold settled: the tool is held from now on, so the press is
    /// the pen's and never the app's (a Ctrl+drag would otherwise drag a picture or a file in the app below).
    public bool HoldNow(InkTool tool)
    {
        if (held is { } h) return h.tool == tool;
        if (Hold?.Invoke(tool) is not { ok: true } r) return false;
        held = (tool, r.before);
        pressedAt = Uptime.Now;
        drewWhileHeld = false;
        pendingTool = null;
        return true;
    }

    static InkTool? Match()
    {
        var now = new KeyCombo(Native.Down(Native.VK_CONTROL), Native.Down(Native.VK_MENU), Native.Down(Native.VK_SHIFT),
                               Native.Down(Native.VK_LWIN) || Native.Down(Native.VK_RWIN), System.Windows.Input.Key.None);
        if (!now.Ctrl && !now.Alt && !now.Win) return null;
        // the more specific combination first (Ctrl+Shift before Ctrl)
        foreach (var tool in new[] { InkTool.box, InkTool.free })
            if (HotkeySettings.Hold(tool) == now) return tool;
        return null;
    }

    void Poll()
    {
        var match = Match();
        var t = Uptime.Now;
        if (match == null)
        {
            shortcut = false;
            pendingTool = null;
            if (held is { } h)
            {
                held = null;
                var quick = t - pressedAt < TapTime && !drewWhileHeld;
                if (quick) Tap?.Invoke(h.tool);
                else Release?.Invoke(h.before);
            }
            return;
        }
        if (shortcut) return;
        if (held is { } current)
        {
            if (current.tool != match)
            {
                // Ctrl → Ctrl+Shift mid-hold: the tool follows the keys
                if (Hold?.Invoke(match.Value) is { ok: true }) held = (match.Value, current.before);
            }
            return;
        }
        if (pendingTool != match) { pendingTool = match; pendingSince = t; return; }
        if (t - pendingSince < Settle) return;
        if (Hold?.Invoke(match.Value) is { ok: true } r)
        {
            held = (match.Value, r.before);
            pressedAt = pendingSince;
            drewWhileHeld = false;
        }
        pendingTool = null;
    }
}
