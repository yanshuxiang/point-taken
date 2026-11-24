// How a stroke is drawn in WPF (the live pen, the review canvas): through the midpoints, a single point as a ring.
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public static class InkGeometry
{
    public static readonly Color Markup = Color.FromRgb(0xFF, 0x5C, 0x3D);
    public static readonly SolidColorBrush MarkupBrush = Freeze(new SolidColorBrush(Markup));

    static T Freeze<T>(T f) where T : Freezable { f.Freeze(); return f; }

    public static Geometry Build(IReadOnlyList<Pt> p, double ring)
    {
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            if (p.Count == 1)
            {
                // a ring: two arcs
                c.BeginFigure(new Point(p[0].X + ring, p[0].Y), false, true);
                c.ArcTo(new Point(p[0].X - ring, p[0].Y), new Size(ring, ring), 0, false, SweepDirection.Clockwise, true, false);
                c.ArcTo(new Point(p[0].X + ring, p[0].Y), new Size(ring, ring), 0, false, SweepDirection.Clockwise, true, false);
            }
            else if (p.Count > 1)
            {
                c.BeginFigure(new Point(p[0].X, p[0].Y), false, false);
                foreach (var (_, control, to) in InkStyle.QuadPieces(p))
                    c.QuadraticBezierTo(new Point(control.X, control.Y), new Point(to.X, to.Y), true, true);
            }
        }
        g.Freeze();
        return g;
    }

    public static Path Shape(Geometry geometry, double width) => new()
    {
        Data = geometry,
        Stroke = MarkupBrush,
        StrokeThickness = width,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
        IsHitTestVisible = false,
        Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.45, BlurRadius = Math.Max(2.4, width * 0.8), ShadowDepth = 0 },
    };
}
