// The pen's window, one per display: full-screen, transparent, always on top, never focused, never in a screenshot.
// Pen off: clicks fall through to the app below. Pen on: a whisper of fill takes the mouse, the screen's edge glows
// in the markup colour and a ring follows the pointer. Port of BoardInkPanel / BoardInkView.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class InkOverlay : Window
{
    public MonitorInfo Display { get; }
    public InkTool Tool { get; set; } = InkTool.free;
    public Action? OnStrokeBegan;
    public Action? OnStrokeCompleted;
    public double LineWidth { get; }

    readonly Canvas canvas = new();
    readonly Border edge;
    readonly Ellipse halo;
    readonly Border flash;
    InkStroke? stroke;
    Path? live;
    readonly List<Path> strokes = new();
    readonly System.Windows.Threading.DispatcherTimer restTimer;
    public List<List<double[]>> NormalizedStrokes { get; private set; } = new();
    public double LastStrokeAt { get; private set; }
    public bool HasInk => strokes.Count > 0;
    public bool Drawing => live != null;
    bool penOn;
    IntPtr hwnd;

    public InkOverlay(MonitorInfo display)
    {
        Display = display;
        LineWidth = InkStyle.Width(Math.Min(display.Width, display.Height) / display.Scale);
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        Focusable = false;
        Title = "Point Taken ink";

        edge = new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromArgb(190, 0xFF, 0x5C, 0x3D)), BorderThickness = new Thickness(3),
            Opacity = 0, IsHitTestVisible = false,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = InkGeometry.Markup, BlurRadius = 18, ShadowDepth = 0, Opacity = 0.9 },
        };
        halo = new Ellipse
        {
            Width = 26, Height = 26, Stroke = InkGeometry.MarkupBrush, StrokeThickness = 2,
            Fill = new SolidColorBrush(Color.FromArgb(41, 0xFF, 0x5C, 0x3D)), Visibility = Visibility.Hidden, IsHitTestVisible = false,
        };
        flash = new Border { Background = Brushes.White, Opacity = 0, IsHitTestVisible = false };
        var root = new Grid();
        root.Children.Add(edge);
        root.Children.Add(canvas);
        root.Children.Add(flash);
        canvas.Children.Add(halo);
        Content = root;

        restTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        restTimer.Tick += (_, _) => { if (stroke?.CheckRest(Uptime.Now) == true) ShowLive(); };

        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            Native.MakePanel(hwnd, clickThrough: true);
            Place();
            HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
        };
        // moving onto a display with another scale makes WPF resize the window by that scale: cover the display again
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Place);
        MouseLeftButtonDown += (_, e) => { if (penOn) { Begin(ToPt(e.GetPosition(canvas))); CaptureMouse(); e.Handled = true; } };
        MouseMove += (_, e) =>
        {
            var p = e.GetPosition(canvas);
            if (penOn) MoveHalo(p, true);
            if (stroke != null) Move(ToPt(p));
        };
        MouseLeftButtonUp += (_, e) => { if (stroke != null) { ReleaseMouseCapture(); End(); e.Handled = true; } };
        MouseLeave += (_, _) => halo.Visibility = Visibility.Hidden;
    }

    static IntPtr WndProc(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled)
    {
        // a click never activates this window: the app below keeps the keyboard
        if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }
        return IntPtr.Zero;
    }

    static Pt ToPt(Point p) => new(p.X, p.Y);

    /// Covers its display exactly, in physical pixels (WPF's own placement can't span mixed-DPI displays).
    public void Place()
    {
        if (hwnd == IntPtr.Zero) return;
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, Display.X, Display.Y, Display.Width, Display.Height, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }

    public void ShowPanel()
    {
        if (!IsVisible) Show();
        Place();
    }

    public void SetPen(bool on)
    {
        if (on == penOn) return;
        penOn = on;
        if (on) { Native.KeepOnTop(hwnd); }
        Native.SetClickThrough(hwnd, !on);
        Background = on ? new SolidColorBrush(Color.FromArgb(3, 0, 0, 0)) : Brushes.Transparent;
        edge.BeginAnimation(OpacityProperty, new DoubleAnimation(on ? 1 : 0, TimeSpan.FromMilliseconds(on ? 120 : 250)));
        if (!on) halo.Visibility = Visibility.Hidden;
        else if (Native.GetCursorPos(out var c) && Display.Contains(c.X, c.Y))
            MoveHalo(new Point((c.X - Display.X) / Display.Scale, (c.Y - Display.Y) / Display.Scale), true);
    }

    void MoveHalo(Point p, bool show)
    {
        halo.Visibility = show ? Visibility.Visible : Visibility.Hidden;
        Canvas.SetLeft(halo, p.X - 13);
        Canvas.SetTop(halo, p.Y - 13);
    }

    public void Flash()
    {
        var a = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromMilliseconds(320) };
        a.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromPercent(0)));
        a.KeyFrames.Add(new LinearDoubleKeyFrame(0.45, KeyTime.FromPercent(0.25)));
        a.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromPercent(1)));
        flash.BeginAnimation(OpacityProperty, a);
    }

    void Begin(Pt p)
    {
        OnStrokeBegan?.Invoke();
        stroke = new InkStroke(p, Tool, Uptime.Now);
        live = InkGeometry.Shape(InkGeometry.Build(new[] { p }, 18), LineWidth);
        canvas.Children.Insert(Math.Max(0, canvas.Children.IndexOf(halo)), live);
        restTimer.Start();
        ShowLive();
    }

    void Move(Pt p)
    {
        if (stroke == null) return;
        if (stroke.Move(p, Tool, Uptime.Now)) ShowLive();
    }

    void ShowLive()
    {
        if (live != null && stroke != null) live.Data = InkGeometry.Build(stroke.Display, 18);
    }

    /// Ends the stroke being drawn (mouse up, or a page boundary while drawing).
    public void End()
    {
        restTimer.Stop();
        if (live == null || stroke == null) return;
        var l = live; var s = stroke;
        live = null; stroke = null;
        var kept = s.Kept();
        l.Data = InkGeometry.Build(kept, 18);
        strokes.Add(l);
        double w = Math.Max(1, canvas.ActualWidth), h = Math.Max(1, canvas.ActualHeight);
        NormalizedStrokes.Add(kept.Select(q => new[] { q.X / w, q.Y / h }).ToList());
        LastStrokeAt = Uptime.Now;
        OnStrokeCompleted?.Invoke();
    }

    public bool Undo()
    {
        if (strokes.Count == 0) return false;
        canvas.Children.Remove(strokes[^1]);
        strokes.RemoveAt(strokes.Count - 1);
        if (NormalizedStrokes.Count > 0) NormalizedStrokes.RemoveAt(NormalizedStrokes.Count - 1);
        if (strokes.Count == 0) LastStrokeAt = 0;
        return true;
    }

    /// Shows saved marks (0–1 points) again: a page's marks while it is still on screen.
    public void Load(IEnumerable<List<double[]>> marks)
    {
        Clear();
        double w = Math.Max(1, canvas.ActualWidth), h = Math.Max(1, canvas.ActualHeight);
        foreach (var mark in marks)
        {
            var pts = mark.Where(p => p.Length == 2).Select(p => new Pt(p[0] * w, p[1] * h)).ToList();
            if (pts.Count == 0) continue;
            var shape = InkGeometry.Shape(InkGeometry.Build(pts, 18), LineWidth);
            canvas.Children.Insert(Math.Max(0, canvas.Children.IndexOf(halo)), shape);
            strokes.Add(shape);
            NormalizedStrokes.Add(mark.Select(p => (double[])p.Clone()).ToList());
        }
    }

    public void Clear()
    {
        foreach (var s in strokes) canvas.Children.Remove(s);
        strokes.Clear();
        NormalizedStrokes = new();
        LastStrokeAt = 0;
    }
}
