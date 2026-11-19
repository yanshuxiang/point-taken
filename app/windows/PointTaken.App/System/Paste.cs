// Hand-off into another app: the user picks the receiving window; it is brought to the front, its focused control
// must take text (UI Automation), then the hand-off text is pasted with Ctrl+V — never sent. The user's clipboard is
// put back afterwards. A missing input field or an interruption stops at once, without retrying.
using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using PointTaken.App.Interop;

namespace PointTaken.App;

public sealed record PasteTarget(IntPtr Hwnd, uint Pid, string App, string Title)
{
    public string Label => Title.Length == 0 ? App : $"{App} — {(Title.Length > 60 ? Title[..60] + "…" : Title)}";
}

public static class Paste
{
    /// Visible top-level windows of other apps, front-most first.
    public static List<PasteTarget> Targets()
    {
        var me = (uint)Environment.ProcessId;
        var list = new List<PasteTarget>();
        Native.EnumWindows((h, _) =>
        {
            if (!Native.IsWindowVisible(h) || Native.GetWindow(h, 4 /* GW_OWNER */) != IntPtr.Zero) return true;
            if ((Native.GetWindowLong(h, Native.GWL_EXSTYLE) & Native.WS_EX_TOOLWINDOW) != 0) return true;
            if (Native.DwmGetWindowAttribute(h, 14 /* DWMWA_CLOAKED */, out var cloaked, 4) == 0 && cloaked != 0) return true;
            var title = Native.WindowText(h);
            if (title.Length == 0) return true;
            var cls = Native.ClassName(h);
            if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd") return true;
            Native.GetWindowThreadProcessId(h, out var pid);
            if (pid == me) return true;
            list.Add(new PasteTarget(h, pid, Capture.WindowContext.AppName(pid), title));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// Whether the focused control of the window in front takes text.
    public static bool HasTextTarget(uint pid)
    {
        try
        {
            var e = AutomationElement.FocusedElement;
            if (e == null || e.Current.ProcessId != pid) return false;
            var type = e.Current.ControlType;
            if (type == ControlType.Edit || type == ControlType.Document || type == ControlType.ComboBox) return true;
            if (e.TryGetCurrentPattern(ValuePattern.Pattern, out var v) && !((ValuePattern)v).Current.IsReadOnly) return true;
            // Chromium / Electron chat boxes expose an editable Group or Custom with a TextPattern
            if (e.TryGetCurrentPattern(TextPattern.Pattern, out _)) return true;
            return e.Current.IsKeyboardFocusable && (e.Current.ClassName?.Contains("Edit", StringComparison.OrdinalIgnoreCase) ?? false);
        }
        catch { return false; }
    }

    sealed class SavedClipboard
    {
        readonly List<(string format, object data)> items = new();
        public static SavedClipboard Take()
        {
            var s = new SavedClipboard();
            try
            {
                var d = Clipboard.GetDataObject();
                if (d == null) return s;
                foreach (var f in d.GetFormats(false))
                {
                    try { if (d.GetData(f, false) is { } data && data is not System.IO.MemoryStream { Length: > 64_000_000 }) s.items.Add((f, data)); }
                    catch { /* a format that can't be read back is left out */ }
                }
            }
            catch { }
            return s;
        }
        public void Restore()
        {
            try
            {
                if (items.Count == 0) { Clipboard.Clear(); return; }
                var d = new DataObject();
                foreach (var (f, data) in items) d.SetData(f, data);
                Clipboard.SetDataObject(d, true);
            }
            catch { }
        }
    }

    /// Activates the target, checks for an input field, pastes `text`. Returns null on success, else the sentence
    /// for the review window.
    public static async Task<string?> Run(PasteTarget target, string text)
    {
        if (!Native.IsWindow(target.Hwnd)) return "接收窗口已经关闭，请重新选择。";
        Native.Activate(target.Hwnd);
        await Task.Delay(400);
        if (Native.GetForegroundWindow() != target.Hwnd && Native.GetAncestor(Native.GetForegroundWindow(), 3) != target.Hwnd)
            return "没能切换到目标窗口；未粘贴、未重试。请手动复制。";
        var ready = await Task.Run(() => HasTextTarget(target.Pid));
        if (!ready) return "未找到目标应用的可编辑输入框；未粘贴、未重试。请先点进输入框，或手动复制。";
        var saved = SavedClipboard.Take();
        try
        {
            if (!TrySetText(text)) return "剪贴板被其他程序占用；未粘贴。请稍后再试或手动复制。";
            await Task.Delay(60);
            // modifiers the user may still hold would turn Ctrl+V into something else
            Native.SendKeys((Native.VK_SHIFT, true), (Native.VK_MENU, true), (Native.VK_CONTROL, false), (0x56, false), (0x56, true), (Native.VK_CONTROL, true));
            await Task.Delay(700);
            if (Native.GetForegroundWindow() != target.Hwnd && Native.GetAncestor(Native.GetForegroundWindow(), 3) != target.Hwnd)
                return "粘贴时目标窗口失去了焦点，可能没有粘贴完整；未重试。";
            return null;
        }
        finally
        {
            await Task.Delay(300);
            saved.Restore();
        }
    }

    public static bool TrySetText(string text)
    {
        for (var i = 0; i < 10; i++)
        {
            try { Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), true); return true; }
            catch (System.Runtime.InteropServices.COMException) { Thread.Sleep(50); }
        }
        return false;
    }

    public static bool TrySetImage(string path)
    {
        try
        {
            var d = new DataObject();
            d.SetImage(LoadFull(path));
            d.SetFileDropList(new System.Collections.Specialized.StringCollection { path });
            Clipboard.SetDataObject(d, true);
            return true;
        }
        catch { return false; }
    }

    static System.Windows.Media.Imaging.BitmapSource LoadFull(string path)
    {
        var image = new System.Windows.Media.Imaging.BitmapImage();
        image.BeginInit();
        image.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
        image.StreamSource = new MemoryStream(File.ReadAllBytes(path));
        image.EndInit();
        image.Freeze();
        return image;
    }

    public static void OpenFolder(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true }); } catch { }
    }

    public static void Open(string pathOrUri)
    {
        try { Process.Start(new ProcessStartInfo(pathOrUri) { UseShellExecute = true }); } catch { }
    }
}
