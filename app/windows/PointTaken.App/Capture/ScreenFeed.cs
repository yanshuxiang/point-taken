// Captures the display under the pointer about 5 times a second with this app's own windows left out (every window
// of ours is WDA_EXCLUDEFROMCAPTURE, Windows 10 2004+), decides page boundaries (BoardPageGate + BoardMotionMask) and
// watches — never consumes — scrolls, clicks and key presses that go to other apps. Port of BoardScreenFeed.swift.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class ScreenFeed
{
    public Action<ScreenFrame, bool>? OnObserve;
    /// an input that went to another app: kind, scroll delta (negative reveals what is below), uptime
    public Action<BoardInputKind, double?, double>? OnInput;
    public Action<ScreenFrame>? OnLeave;
    public Func<ScreenFrame, ScreenFrame, bool, bool>? OnTransition;
    public Action<string>? OnFailure;
    /// any key went down (another app's); the hold-to-draw keys use it to tell a shortcut from a hold
    public Action<int>? OnKeyDown;
    /// the wheel turned (with a hold-to-draw key down it is Ctrl+wheel for the app, not drawing)
    public Action? OnWheel;

    public BoardMotionMask Motion { get; } = new();
    public ScreenFrame? Current { get; private set; }
    ScreenFrame? reference;
    BoardPageGate gate = new();
    double lastScroll = double.NegativeInfinity, lastPress = double.NegativeInfinity;
    volatile bool capturePaused;
    /// a frame waiting for the UI thread: no new capture until it is taken (bounds memory when the UI is busy)
    int delivering;
    bool paused;
    public bool Paused { get => paused; set { paused = value; capturePaused = value; } }

    readonly Dispatcher ui;
    CancellationTokenSource? cancel;
    IntPtr mouseHook, keyHook;
    Native.HookProc? mouseProc, keyProc;   // kept alive while hooked

    public ScreenFeed(Dispatcher ui) { this.ui = ui; }

    bool Quiet(double now) => now - lastPress > 3.0 && now - lastScroll > 0.8;

    public void Start()
    {
        Stop();
        Paused = false;
        InstallHooks();
        var cts = new CancellationTokenSource();
        cancel = cts;
        var thread = new Thread(() => CaptureLoop(cts.Token)) { IsBackground = true, Name = "point-taken screen feed", Priority = ThreadPriority.BelowNormal };
        thread.Start();
    }

    public void Stop()
    {
        cancel?.Cancel(); cancel = null;
        RemoveHooks();
        Current = null; reference = null; gate = new BoardPageGate(); Motion.Reset();
    }

    public void ResetBoundary() { reference = Current; gate = new BoardPageGate(); }

    void CaptureLoop(CancellationToken token)
    {
        var failures = 0;
        while (!token.IsCancellationRequested)
        {
            var began = Stopwatch.GetTimestamp();
            if (!capturePaused && Volatile.Read(ref delivering) == 0)
            {
                try
                {
                    var display = MonitorInfo.AtCursor();
                    if (display != null)
                    {
                        var pixels = GdiCapture.Grab(display);
                        var print = pixels.Fingerprint();
                        var context = WindowContext.Front();
                        var at = Uptime.Now;
                        Interlocked.Exchange(ref delivering, 1);
                        ui.BeginInvoke(() =>
                        {
                            Interlocked.Exchange(ref delivering, 0);
                            Deliver(new ScreenFrame
                            {
                                Image = pixels, Display = display, Scene = context.Scene + ":" + display.Device,
                                AppName = context.App, Title = context.Title, Fingerprint = print, CapturedAt = at,
                            }, token);
                        });
                        failures = 0;
                    }
                }
                catch (Exception e)
                {
                    if (++failures == 5) ui.BeginInvoke(() => OnFailure?.Invoke(e.Message));
                }
            }
            var spent = Stopwatch.GetElapsedTime(began).TotalMilliseconds;
            Thread.Sleep(Math.Max(20, 200 - (int)spent));
        }
    }

    void Deliver(ScreenFrame frame, CancellationToken token)
    {
        if (token.IsCancellationRequested || Paused) return;
        var old = Current;
        Current = frame;
        if (old != null)
        {
            if (old.Scene != frame.Scene || old.Title != frame.Title) Motion.Reset();
            else if (Quiet(frame.CapturedAt)) Motion.Learn(old.Fingerprint, frame.Fingerprint);
        }
        if (old != null && OnTransition?.Invoke(old, frame, Uptime.Now - lastScroll < 1.2) == true)
        {
            reference = frame; gate = new BoardPageGate(); return;
        }
        switch (gate.Observe(frame.Fingerprint, frame.Scene + "|" + frame.Title, Uptime.Now, Motion))
        {
            case BoardPageGate.Decision.Reference:
                OnObserve?.Invoke(frame, false);
                reference = frame;
                break;
            case BoardPageGate.Decision.Leave:
                Motion.Reset();
                if (reference != null) OnLeave?.Invoke(reference);
                OnObserve?.Invoke(frame, true);
                reference = frame;
                break;
        }
    }

    // ── input hooks: observe only, always pass the event on ──

    void InstallHooks()
    {
        var module = Native.GetModuleHandle(null);
        mouseProc = MouseHook;
        keyProc = KeyHook;
        mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, mouseProc, module, 0);
        keyHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, keyProc, module, 0);
    }

    void RemoveHooks()
    {
        if (mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(mouseHook);
        if (keyHook != IntPtr.Zero) Native.UnhookWindowsHookEx(keyHook);
        mouseHook = keyHook = IntPtr.Zero;
    }

    IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && !Paused)
        {
            var msg = (int)wParam;
            if (msg == Native.WM_MOUSEWHEEL)
            {
                var data = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
                var delta = (short)(data.mouseData >> 16);
                var now = Uptime.Now;
                lastScroll = now;
                Motion.Reset();
                OnWheel?.Invoke();
                // wheel up (positive) shows what is above: content moves down, dy positive, like the macOS sign
                if (delta != 0) OnInput?.Invoke(BoardInputKind.scroll, delta / 120.0 * 10, now);
                gate.Interaction(now, scroll: true);
            }
            else if (msg == Native.WM_LBUTTONUP || msg == Native.WM_RBUTTONUP)
            {
                var now = Uptime.Now;
                WindowContext.Invalidate();
                lastPress = now;
                OnInput?.Invoke(BoardInputKind.click, null, now);
                gate.Interaction(now, scroll: false);
            }
        }
        return Native.CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    IntPtr KeyHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && ((int)wParam == Native.WM_KEYDOWN || (int)wParam == Native.WM_SYSKEYDOWN))
        {
            var data = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            OnKeyDown?.Invoke((int)data.vkCode);
            if (!Paused && !IsModifier((int)data.vkCode))
            {
                var now = Uptime.Now;
                WindowContext.Invalidate();
                lastPress = now;
                OnInput?.Invoke(BoardInputKind.key, null, now);
                gate.Interaction(now, scroll: false);
            }
        }
        return Native.CallNextHookEx(keyHook, code, wParam, lParam);
    }

    public static bool IsModifier(int vk) => vk is 0x10 or 0x11 or 0x12 or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5 or 0x5B or 0x5C or 0x14;
}

/// BitBlt of one display into a top-down 32-bit DIB. Windows marked WDA_EXCLUDEFROMCAPTURE are left out.
static class GdiCapture
{
    public static Pixels Grab(MonitorInfo m)
    {
        var screen = Native.GetDC(IntPtr.Zero);
        var mem = Native.CreateCompatibleDC(screen);
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<Native.BITMAPINFOHEADER>(), biWidth = m.Width, biHeight = -m.Height,
            biPlanes = 1, biBitCount = 32, biCompression = 0,
        };
        var dib = Native.CreateDIBSection(screen, ref header, 0, out var bits, IntPtr.Zero, 0);
        if (dib == IntPtr.Zero) { Native.DeleteDC(mem); Native.ReleaseDC(IntPtr.Zero, screen); throw new InvalidOperationException("无法读取屏幕"); }
        var old = Native.SelectObject(mem, dib);
        try
        {
            if (!Native.BitBlt(mem, 0, 0, m.Width, m.Height, screen, m.X, m.Y, Native.SRCCOPY))
                throw new InvalidOperationException("截图失败");
            var data = new byte[m.Width * m.Height * 4];
            Marshal.Copy(bits, data, 0, data.Length);
            // GDI leaves alpha at 0: make every pixel opaque
            for (var i = 3; i < data.Length; i += 4) data[i] = 255;
            return new Pixels(m.Width, m.Height, data);
        }
        finally
        {
            Native.SelectObject(mem, old);
            Native.DeleteObject(dib);
            Native.DeleteDC(mem);
            Native.ReleaseDC(IntPtr.Zero, screen);
        }
    }
}

/// The window in front: its identity (for page boundaries), its app's name and its title. Never a URL: one in a title
/// is replaced. No browser history, no accessibility tree.
public static class WindowContext
{
    static readonly Regex UrlPattern = new(@"(?:https?|file)://\S+|\bwww\.\S+", RegexOptions.Compiled);
    static (IntPtr hwnd, double at, (string Scene, string App, string Title) value)? cached;
    static (string Scene, string App, string Title)? lastOther;
    static readonly Dictionary<uint, string> appNames = new();
    static readonly object gate = new();

    public static void Invalidate() { lock (gate) cached = null; }

    public static (string Scene, string App, string Title) Front()
    {
        var hwnd = Native.GetForegroundWindow();
        var now = Uptime.Now;
        lock (gate)
        {
            if (cached is { } c && c.hwnd == hwnd && now - c.at < 0.35) return c.value;
        }
        if (hwnd == IntPtr.Zero) return ("desktop", "桌面", "");
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        // our own windows (the review, settings, a menu) are never the page being marked: keep the last other one
        if (pid == (uint)Environment.ProcessId)
        {
            lock (gate) return lastOther ?? ("desktop", "桌面", "");
        }
        var title = UrlPattern.Replace(Native.WindowText(hwnd), "[网址省略]").Replace("\n", " ");
        if (title.Length > 240) title = title[..240];
        var cls = Native.ClassName(hwnd);
        var app = cls is "Progman" or "WorkerW" ? "桌面" : AppName(pid);
        var value = ($"{pid}:{hwnd.ToInt64()}", app, title);
        lock (gate) { cached = (hwnd, now, value); lastOther = value; }
        return value;
    }

    public static string AppName(uint pid)
    {
        lock (gate) if (appNames.TryGetValue(pid, out var n)) return n;
        var name = "应用";
        try
        {
            var path = Native.ProcessPath(pid);
            if (path.Length > 0)
            {
                var info = FileVersionInfo.GetVersionInfo(path);
                name = !string.IsNullOrWhiteSpace(info.FileDescription) ? info.FileDescription!.Trim()
                    : !string.IsNullOrWhiteSpace(info.ProductName) ? info.ProductName!.Trim()
                    : Path.GetFileNameWithoutExtension(path);
            }
            else name = Process.GetProcessById((int)pid).ProcessName;
        }
        catch { }
        lock (gate) appNames[pid] = name;
        return name;
    }
}
