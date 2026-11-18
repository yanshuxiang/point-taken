// Win32 interop in one place: window styles (no activation, click-through, excluded from screenshots), monitors,
// screen capture, the foreground window, hotkeys, low-level input hooks (observe only, never consume), SendInput,
// and a job object that ends every child process with the app.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace PointTaken.App.Interop;

internal static class Native
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOPMOST = 0x8;
    public const uint WDA_NONE = 0, WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const int WM_HOTKEY = 0x0312, WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    public static readonly IntPtr HWND_TOPMOST = new(-1);

    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; public int Width => Right - Left; public int Height => Bottom - Top; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

    // monitors
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hMonitor, int type, out uint dpiX, out uint dpiY);

    // GDI capture
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    public const uint SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000;
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER { public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant; }
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

    // hotkeys
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8, MOD_NOREPEAT = 0x4000;
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_LBUTTON = 0x01;
    public static bool Down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    // low-level hooks
    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string? name);
    public const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    public const int WM_KEYDOWN = 0x100, WM_SYSKEYDOWN = 0x104, WM_LBUTTONUP = 0x202, WM_RBUTTONUP = 0x205, WM_MOUSEWHEEL = 0x20A;
    [StructLayout(LayoutKind.Sequential)] public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MSLLHOOKSTRUCT { public POINT pt; public int mouseData; public uint flags, time; public IntPtr extra; }

    // SendInput
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
    public const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 2;
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

    public static void SendKeys(params (ushort vk, bool up)[] keys)
    {
        var inputs = keys.Select(k => new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = k.vk, dwFlags = k.up ? KEYEVENTF_KEYUP : 0 } } }).ToArray();
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);

    /// Brings a window to the front even when another app is in front (the attach trick Windows requires).
    public static bool Activate(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9 /* SW_RESTORE */);
        var fore = GetForegroundWindow();
        var foreThread = GetWindowThreadProcessId(fore, out _);
        var me = GetCurrentThreadId();
        var attached = foreThread != me && AttachThreadInput(me, foreThread, true);
        // an Alt tap unlocks SetForegroundWindow for this process
        SendKeys((VK_MENU, false), (VK_MENU, true));
        BringWindowToTop(hwnd);
        var ok = SetForegroundWindow(hwnd);
        if (attached) AttachThreadInput(me, foreThread, false);
        return ok;
    }

    public static string WindowText(IntPtr hwnd)
    {
        var n = GetWindowTextLength(hwnd);
        if (n <= 0) return "";
        var sb = new StringBuilder(n + 1);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    /// Makes a WPF window a floating panel: never takes focus, never in Alt-Tab, never in a screenshot; optionally
    /// click-through.
    public static void MakePanel(IntPtr hwnd, bool clickThrough)
    {
        var ex = GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        ex = clickThrough ? ex | WS_EX_TRANSPARENT | WS_EX_LAYERED : ex & ~WS_EX_TRANSPARENT;
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    }

    public static void SetClickThrough(IntPtr hwnd, bool on)
    {
        var ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        var next = on ? ex | WS_EX_TRANSPARENT | WS_EX_LAYERED : ex & ~WS_EX_TRANSPARENT;
        if (next != ex) SetWindowLong(hwnd, GWL_EXSTYLE, next);
    }

    public static void KeepOnTop(IntPtr hwnd) => SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

    /// The process image path of a window's owner (empty when it can't be read: an elevated process).
    public static string ProcessPath(uint pid)
    {
        var h = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, pid);
        if (h == IntPtr.Zero) return "";
        try
        {
            var sb = new StringBuilder(1024);
            var size = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : "";
        }
        finally { CloseHandle(h); }
    }
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    // job object: children end with the app (uv → python → model)
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string? name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long t1, t2; public uint flags; public UIntPtr min, max; public uint active; public UIntPtr affinity; public uint prio, sched; }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION basic; public IO_COUNTERS io; public UIntPtr p1, p2, p3, p4; }
    static IntPtr job;

    public static void AdoptChild(Process p)
    {
        try
        {
            if (job == IntPtr.Zero)
            {
                job = CreateJobObject(IntPtr.Zero, null);
                var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { basic = { flags = 0x2000 /* KILL_ON_JOB_CLOSE */ } };
                SetInformationJobObject(job, 9, ref info, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>());
            }
            AssignProcessToJobObject(job, p.Handle);
        }
        catch { /* the child just isn't tied to us */ }
    }
}

/// One display, in physical pixels (virtual-screen coordinates).
public sealed record MonitorInfo(IntPtr Handle, int X, int Y, int Width, int Height, double Scale, string Device)
{
    public bool Contains(int x, int y) => x >= X && x < X + Width && y >= Y && y < Y + Height;
    public string Key => $"{Device}:{X},{Y},{Width}x{Height}";

    public static List<MonitorInfo> All()
    {
        var list = new List<MonitorInfo>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref Native.RECT _, IntPtr _) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfo(h, ref info))
            {
                var scale = Native.GetDpiForMonitor(h, 0, out var dx, out _) == 0 ? dx / 96.0 : 1.0;
                var r = info.rcMonitor;
                list.Add(new MonitorInfo(h, r.Left, r.Top, r.Width, r.Height, scale, info.szDevice));
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static MonitorInfo? AtCursor()
    {
        Native.GetCursorPos(out var p);
        return All().FirstOrDefault(m => m.Contains(p.X, p.Y));
    }
}
