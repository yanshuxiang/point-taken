// The marks over the shown picture in the review window (BoardMarkCanvas): sized exactly to the picture as laid out,
// points 0–1 from its top-left. 选择 picks a mark by its line or number (Delete removes it; dragging empty space pans);
// a pen draws a new mark (numbered next, flagged as drawn after recording). Esc leaves a pen; ← → step pages;
// double-clicking empty space toggles full-size markup.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using PointTaken.App.Capture;
using PointTaken.Core;

namespace PointTaken.App.Review;

public sealed class MarkCanvas : Canvas
{
    BoardMarkSheet sheet = new(Array.Empty<List<double[]>>(), Array.Empty<BoardMarkEvidence>(), 1);
    InkStroke? stroke;
    Path? live;
    readonly System.Windows.Threading.DispatcherTimer rest;
    /// null: 选择
    public InkTool? Tool { get; set; }
    public bool Editable { get; set; } = true;
    public double LineWidth { get; set; } = 3;
    public double BadgeDiameter { get; set; } = 22;
    int? selected;
    public int? Selected { get => selected; set { if (selected == value) return; selected = value; Redraw(); OnSelect?.Invoke(value); } }
    public bool Drawing => stroke != null;
    public Action<List<double[]>>? OnDraw;
    public Action<int>? OnDelete;
    public Action<int?>? OnSelect;
    public Action? OnEscape;
    public Action<int>? OnArrow;
    public Action? OnEmptyDoubleClick;
    public Action<Vector>? OnPan;
    Point? panFrom;

    public MarkCanvas()
    {
        Background = Brushes.Transparent;
        ClipToBounds = false;
        Focusable = true;
        FocusVisualStyle = null;
        SizeChanged += (_, _) => Redraw();
        rest = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        rest.Tick += (_, _) => { if (stroke?.CheckRest(Uptime.Now) == true) ShowLive(); };
    }

    public BoardMarkSheet Sheet { get => sheet; set { sheet = value; Redraw(); } }

    Pt ToNormal(Point p) => new(p.X / Math.Max(1, ActualWidth), p.Y / Math.Max(1, ActualHeight));

    public void Redraw()
    {
        Children.Clear();
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        foreach (var mark in sheet.Marks)
        {
            var pts = mark.Points.Where(p => p.Length == 2).Select(p => new Pt(p[0] * w, p[1] * h)).ToList();
            if (pts.Count == 0) continue;
            var shape = InkGeometry.Shape(InkGeometry.Build(pts, LineWidth * 4.5), LineWidth);
            Children.Add(shape);
            if (selected == mark.Evidence.Number)
            {
                // the chosen mark: a soft accent halo under the line
                var halo = InkGeometry.Shape(InkGeometry.Build(pts, LineWidth * 4.5), LineWidth + 6);
                halo.Stroke = Mac.B(0x59, 0x10, 0x94, 0x78);
                halo.Effect = null;
                Children.Insert(Children.Count - 1, halo);
            }
        }
        foreach (var mark in sheet.Marks)
        {
            if (BoardMarkSheet.BadgeCenter(mark.Points, w, h, BadgeDiameter) is not { } c) continue;
            var on = selected == mark.Evidence.Number;
            var d = BadgeDiameter;
            var badge = new Grid { Width = d, Height = d, IsHitTestVisible = false };
            badge.Children.Add(new Ellipse { Fill = on ? Mac.Accent : Mac.Black(0.88), Stroke = Brushes.White, StrokeThickness = Math.Max(1.5, d / 14) });
            badge.Children.Add(new TextBlock
            {
                Text = mark.Evidence.Number.ToString(), Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = d * 0.5, FontFamily = Mac.Digits,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            });
            SetLeft(badge, c.X - d / 2); SetTop(badge, c.Y - d / 2);
            Children.Add(badge);
        }
        if (live != null) Children.Add(live);
    }

    /// Where a mark sits (its points' bounds with its badge), in this canvas.
    public Rect? RectOf(int number)
    {
        var i = sheet.IndexOf(number);
        if (i < 0) return null;
        var pts = sheet.Marks[i].Points.Where(p => p.Length == 2).ToList();
        if (pts.Count == 0) return null;
        double w = ActualWidth, h = ActualHeight;
        var r = new Rect(new Point(pts.Min(p => p[0]) * w, pts.Min(p => p[1]) * h), new Point(pts.Max(p => p[0]) * w, pts.Max(p => p[1]) * h));
        r.Inflate(Math.Max(LineWidth * 4.5, 8), Math.Max(LineWidth * 4.5, 8));
        return r;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        Focus();
        var p = e.GetPosition(this);
        if (e.ClickCount == 2 && Tool == null && Hit(p) == null) { OnEmptyDoubleClick?.Invoke(); e.Handled = true; return; }
        if (Tool is { } tool && Editable)
        {
            stroke = new InkStroke(new Pt(p.X, p.Y), tool, Uptime.Now);
            live = InkGeometry.Shape(InkGeometry.Build(new[] { new Pt(p.X, p.Y) }, LineWidth * 4.5), LineWidth);
            Children.Add(live);
            CaptureMouse();
            rest.Start();
            e.Handled = true;
            return;
        }
        var hit = Hit(p);
        Selected = hit;
        if (hit == null) { panFrom = PointToScreen(p); CaptureMouse(); Cursor = Cursors.SizeAll; }
        e.Handled = true;
    }

    int? Hit(Point p) => sheet.Hit(new Pt(p.X, p.Y), ActualWidth, ActualHeight, Math.Max(6, LineWidth * 2), LineWidth * 4.5, BadgeDiameter);

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (stroke != null && live != null)
        {
            var p = e.GetPosition(this);
            if (stroke.Move(new Pt(p.X, p.Y), stroke.Tool, Uptime.Now)) ShowLive();
        }
        else if (panFrom is { } from && e.LeftButton == MouseButtonState.Pressed)
        {
            var now = PointToScreen(e.GetPosition(this));
            OnPan?.Invoke(from - now);
            panFrom = now;
        }
        else Cursor = Tool != null ? Cursors.Cross : Hit(e.GetPosition(this)) != null ? Cursors.Hand : null;
    }

    void ShowLive()
    {
        if (stroke != null && live != null) live.Data = InkGeometry.Build(stroke.Display, LineWidth * 4.5);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (panFrom != null) { panFrom = null; ReleaseMouseCapture(); Cursor = null; return; }
        if (stroke == null) return;
        rest.Stop();
        ReleaseMouseCapture();
        var kept = stroke.Kept();
        stroke = null;
        if (live != null) Children.Remove(live);
        live = null;
        OnDraw?.Invoke(kept.Select(q => new[] { q.X / Math.Max(1, ActualWidth), q.Y / Math.Max(1, ActualHeight) }).ToList());
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Delete or Key.Back when selected is { } n && Editable: OnDelete?.Invoke(n); e.Handled = true; break;
            case Key.Escape: OnEscape?.Invoke(); e.Handled = true; break;
            case Key.Left: OnArrow?.Invoke(-1); e.Handled = true; break;
            case Key.Right: OnArrow?.Invoke(1); e.Handled = true; break;
        }
    }
}
