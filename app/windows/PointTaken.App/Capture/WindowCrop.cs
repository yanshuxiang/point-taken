// What a page's picture is cut from its display: by default the window(s) the marks are on — the app being talked
// about, not the whole desktop with its taskbar and other windows — or, with 设置 → 通用 → 截图范围 → 整个屏幕, the
// whole display. A window covering (nearly) all of its display, the desktop and the taskbar keep the whole display.
using System.Runtime.InteropServices;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App.Capture;

/// The session's capture choices (record.board.*).
public static class CaptureSettings
{
    /// "window" (the default): the windows the marks are on; "screen": the whole display
    public static bool WholeScreen => Config.Shared.GetString("record.board.capture") == "screen";
    public static void SetWholeScreen(bool on) => Config.Shared.Set("record.board.capture", on ? "screen" : "window");

    /// Leaving a screen that was talked over but not marked keeps it as an unchecked page. Off by default: only what
    /// is marked, or saved with 截图, becomes a page.
    public static bool KeepSpokenScreens => Config.Shared.GetBool("record.board.keep_spoken_screens") ?? false;
    public static void SetKeepSpokenScreens(bool on) => Config.Shared.Set("record.board.keep_spoken_screens", System.Text.Json.Nodes.JsonValue.Create(on));
}

/// A rectangle in a frame's pixels.
public readonly record struct PixelRect(int X, int Y, int W, int H)
{
    public int Right => X + W;
    public int Bottom => Y + H;
    public long Area => (long)W * H;
    public PixelRect Union(PixelRect o)
    {
        int x = Math.Min(X, o.X), y = Math.Min(Y, o.Y);
        return new PixelRect(x, y, Math.Max(Right, o.Right) - x, Math.Max(Bottom, o.Bottom) - y);
    }
    public PixelRect? Clip(int width, int height)
    {
        int x = Math.Clamp(X, 0, width), y = Math.Clamp(Y, 0, height);
        int r = Math.Clamp(Right, 0, width), b = Math.Clamp(Bottom, 0, height);
        return r - x < 8 || b - y < 8 ? null : new PixelRect(x, y, r - x, b - y);
    }
}

public static class WindowCrop
{
    /// The part of `frame` the marks (0–1 points on its display) are about: the windows under them and the marks
    /// themselves; null for the whole display (the whole-screen setting, the desktop, or windows filling it anyway).
    public static PixelRect? For(ScreenFrame frame, IEnumerable<IReadOnlyList<double[]>> marks)
    {
        if (CaptureSettings.WholeScreen) return null;
        var points = marks.SelectMany(m => m).Where(p => p.Length == 2).ToList();
        if (points.Count == 0) return Front(frame);
        int fw = frame.Image.Width, fh = frame.Image.Height;
        // the marks' own box, a little wider: a circle drawn around a window's edge keeps all of its ink
        double minX = points.Min(p => p[0]), maxX = points.Max(p => p[0]), minY = points.Min(p => p[1]), maxY = points.Max(p => p[1]);
        var pad = 0.015 * Math.Max(fw, fh);
        var box = new PixelRect((int)(minX * fw - pad), (int)(minY * fh - pad), (int)((maxX - minX) * fw + 2 * pad), (int)((maxY - minY) * fh + 2 * pad));
        var crop = box;
        var windows = TopLevel(frame.Display);
        // the window under each of a few points of the marks (a stroke across two windows keeps both)
        var step = Math.Max(1, points.Count / 12);
        var samples = points.Where((_, i) => i % step == 0).Append(new[] { (minX + maxX) / 2, (minY + maxY) / 2 });
        foreach (var p in samples)
        {
            int x = (int)(p[0] * fw), y = (int)(p[1] * fh);
            var hit = windows.FirstOrDefault(w => x >= w.rect.X && x < w.rect.Right && y >= w.rect.Y && y < w.rect.Bottom);
            if (hit.wholeScreen) return null;
            if (hit.rect.W <= 0) continue;
            crop = crop.Union(hit.rect);
            // a menu, a dropdown or a tool window is about the app it belongs to: that app's window is kept too
            var owner = hit.owner != IntPtr.Zero ? hit.owner : hit.menu ? Native.GetForegroundWindow() : IntPtr.Zero;
            if (owner != IntPtr.Zero && owner != hit.hwnd && windows.FirstOrDefault(w => w.hwnd == owner) is { rect.W: > 0 } app)
            {
                if (app.wholeScreen) return null;
                crop = crop.Union(app.rect);
            }
        }
        return Fit(crop, fw, fh);
    }

    /// The window in front, when it is on this display (a page saved with 截图, or kept for what was said).
    public static PixelRect? Front(ScreenFrame frame)
    {
        if (CaptureSettings.WholeScreen) return null;
        var front = Native.GetForegroundWindow();
        foreach (var w in TopLevel(frame.Display))
            if (w.hwnd == front) return w.wholeScreen ? null : Fit(w.rect, frame.Image.Width, frame.Image.Height);
        return null;
    }

    const uint GA_ROOTOWNER = 3;

    /// A page cut `cut` that must take in `more` too (null: the whole display).
    public static PixelRect? Join(PixelRect cut, PixelRect? more, int fw, int fh) => more is { } m ? Fit(cut.Union(m), fw, fh) : null;

    /// null when the cut would keep (nearly) all of the display anyway
    static PixelRect? Fit(PixelRect crop, int fw, int fh)
    {
        if (crop.Clip(fw, fh) is not { } c) return null;
        return c.Area >= 0.97 * fw * fh ? null : c;
    }

    /// The visible top-level windows of other apps on `display`, front to back, in the display's pixels.
    static List<(IntPtr hwnd, PixelRect rect, bool wholeScreen, IntPtr owner, bool menu)> TopLevel(MonitorInfo display)
    {
        var list = new List<(IntPtr, PixelRect, bool, IntPtr, bool)>();
        var self = (uint)Environment.ProcessId;
        Native.EnumWindows((h, _) =>
        {
            if (!Native.IsWindowVisible(h) || Native.IsIconic(h)) return true;
            Native.GetWindowThreadProcessId(h, out var pid);
            if (pid == self) return true;
            var ex = Native.GetWindowLong(h, Native.GWL_EXSTYLE);
            if ((ex & Native.WS_EX_TRANSPARENT) != 0) return true;            // click-through overlays draw over others
            if (Native.DwmGetWindowAttribute(h, Native.DWMWA_CLOAKED, out var cloaked, 4) == 0 && cloaked != 0) return true;
            if (Native.DwmGetWindowRect(h, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out Native.RECT r, Marshal.SizeOf<Native.RECT>()) != 0
                && !Native.GetWindowRect(h, out r)) return true;
            if (r.Width < 16 || r.Height < 16) return true;
            var rect = new PixelRect(r.Left - display.X, r.Top - display.Y, r.Width, r.Height);
            if (rect.Right <= 0 || rect.Bottom <= 0 || rect.X >= display.Width || rect.Y >= display.Height) return true;
            var cls = Native.ClassName(h);
            var whole = cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd";
            var root = Native.GetAncestor(h, GA_ROOTOWNER);
            // a popup menu has no owner window: "#32768" (Win32), or a borderless topmost tool window (most toolkits)
            var menu = cls == "#32768" || ((ex & Native.WS_EX_TOOLWINDOW) != 0 && (ex & Native.WS_EX_TOPMOST) != 0);
            list.Add((h, rect, whole, root == h ? IntPtr.Zero : root, menu));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // ── marks between display and page coordinates ──

    /// A mark in 0–1 display coordinates → 0–1 coordinates of the page cut `crop` (null: the whole display).
    public static List<double[]> ToPage(IEnumerable<double[]> mark, PixelRect? crop, int fw, int fh) =>
        crop is not { } c ? mark.Select(p => (double[])p.Clone()).ToList()
            : mark.Select(p => p.Length == 2 ? new[] { (p[0] * fw - c.X) / c.W, (p[1] * fh - c.Y) / c.H } : (double[])p.Clone()).ToList();

    public static List<double[]> ToDisplay(IEnumerable<double[]> mark, PixelRect? crop, int fw, int fh) =>
        crop is not { } c ? mark.Select(p => (double[])p.Clone()).ToList()
            : mark.Select(p => p.Length == 2 ? new[] { (p[0] * c.W + c.X) / fw, (p[1] * c.H + c.Y) / fh } : (double[])p.Clone()).ToList();

    /// whether a mark in page coordinates lies within the page's picture
    public static bool Inside(IEnumerable<double[]> mark) =>
        mark.Where(p => p.Length == 2).All(p => p[0] >= -0.01 && p[0] <= 1.01 && p[1] >= -0.01 && p[1] <= 1.01);
}
