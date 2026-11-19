// The pen's rules (Ink.swift): what a drag draws, the clean shape a rough stroke snaps to when the pen rests at its
// end, how a box / ellipse is stored as points, and how wide the line is. Drawing itself is in the app.
namespace PointTaken.Core;

public enum InkTool { free, box, ellipse }

public readonly record struct Pt(double X, double Y)
{
    public double DistanceTo(Pt o) => Math.Sqrt((X - o.X) * (X - o.X) + (Y - o.Y) * (Y - o.Y));
}

public readonly record struct InkRect(double X, double Y, double W, double H)
{
    public double MinX => X; public double MinY => Y; public double MaxX => X + W; public double MaxY => Y + H;
    public double MidX => X + W / 2; public double MidY => Y + H / 2;
}

public abstract record InkShape
{
    public sealed record Line(Pt A, Pt B) : InkShape;
    public sealed record Box(InkRect R) : InkShape;
    public sealed record Ellipse(InkRect R) : InkShape;
}

/// Holding still at the end of a freehand stroke: how long, and how far the pointer may wander meanwhile.
public static class InkHold
{
    public const double Seconds = 0.5;
    public const double Radius = 3;
    public static bool Rested(double lastMove, double now) => now - lastMove >= Seconds;
}

/// One stroke from mouse-down to mouse-up.
public sealed class InkStroke
{
    public Pt Start { get; }
    readonly List<Pt> pts;
    public InkTool Tool { get; private set; }
    List<Pt>? shape;
    public string? SnappedAs { get; private set; }
    Pt restAt;
    double restSince;

    public InkStroke(Pt at, InkTool tool, double now)
    {
        Start = at; pts = new() { at }; Tool = tool; restAt = at; restSince = now;
    }

    public IReadOnlyList<Pt> Display => shape ?? pts;
    public bool IsShape => shape != null;
    public double Length { get { double l = 0; for (var i = 1; i < pts.Count; i++) l += pts[i - 1].DistanceTo(pts[i]); return l; } }

    /// The pen moved: true when what is shown changed.
    public bool Move(Pt p, InkTool t, double now)
    {
        if (p.DistanceTo(restAt) > InkHold.Radius * (SnappedAs != null ? 2 : 1))
        {
            restAt = p; restSince = now;
            if (SnappedAs != null) { SnappedAs = null; shape = null; }
        }
        Tool = t;
        var added = false;
        if (pts[^1].DistanceTo(p) >= 1.5) { pts.Add(p); added = true; }
        if (t != InkTool.free)
        {
            SnappedAs = null;
            var s = InkFit.Shape(t, Start, p);
            shape = s == null ? null : InkFit.Points(s);
            return true;
        }
        if (SnappedAs == null)
        {
            var wasShape = shape != null;
            shape = null;
            return added || wasShape;
        }
        return false;
    }

    /// Called on a timer while the button is down: a freehand stroke the pen rested on snaps to its clean shape.
    public bool CheckRest(double now)
    {
        if (Tool != InkTool.free || SnappedAs != null || !InkHold.Rested(restSince, now)) return false;
        var s = InkFit.Fit(pts);
        if (s == null) return false;
        shape = InkFit.Points(s);
        SnappedAs = s switch { InkShape.Line => "line", InkShape.Box => "rect", _ => "ellipse" };
        return true;
    }

    /// The points to keep: a shape as it is, a tap (or a scribble shorter than 3) as its one point (drawn as a ring).
    public List<Pt> Kept()
    {
        var d = Display;
        if (d.Count <= 1 || (!IsShape && Length < 3)) return new() { d[0] };
        return d.ToList();
    }
}

public static class InkFit
{
    public static InkShape? Fit(IReadOnlyList<Pt> pts)
    {
        if (pts.Count < 3) return null;
        Pt first = pts[0], last = pts[^1];
        double length = 0;
        for (var i = 1; i < pts.Count; i++) length += pts[i - 1].DistanceTo(pts[i]);
        if (length < 16) return null;
        double minX = pts.Min(p => p.X), maxX = pts.Max(p => p.X), minY = pts.Min(p => p.Y), maxY = pts.Max(p => p.Y);
        var box = new InkRect(minX, minY, maxX - minX, maxY - minY);
        var chord = first.DistanceTo(last);
        if (chord >= 20 && chord >= 0.8 * length)
        {
            var dev = pts.Max(p => DistanceToLine(p, first, last));
            if (dev <= Math.Max(5, 0.07 * chord)) return new InkShape.Line(first, Straightened(first, last));
        }
        var big = Math.Max(box.W, box.H);
        if (Math.Min(box.W, box.H) < 10 || chord > Math.Max(14, 0.3 * big) || length < 1.4 * (box.W + box.H)) return null;
        double rectErr = 0, ellErr = 0;
        foreach (var p in pts)
        {
            double u = (p.X - box.MinX) / box.W, v = (p.Y - box.MinY) / box.H;
            rectErr += Math.Min(Math.Min(u, 1 - u), Math.Min(v, 1 - v));
            ellErr += Math.Abs(Math.Sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)) / 0.5 - 1) * 0.5;
        }
        rectErr /= pts.Count; ellErr /= pts.Count;
        if (Math.Min(rectErr, ellErr) > 0.08) return null;
        return rectErr <= ellErr ? new InkShape.Box(box) : new InkShape.Ellipse(box);
    }

    public static InkShape? Shape(InkTool tool, Pt a, Pt b)
    {
        var r = new InkRect(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));
        if (Math.Max(r.W, r.H) < 4) return null;
        return tool switch { InkTool.box => new InkShape.Box(r), InkTool.ellipse => new InkShape.Ellipse(r), _ => null };
    }

    /// The point list a shape is stored as: a box's corners doubled (the midpoint smoothing keeps them sharp), an
    /// ellipse as 72 points round, a line as its two ends.
    public static List<Pt> Points(InkShape s)
    {
        switch (s)
        {
            case InkShape.Line l: return new() { l.A, l.B };
            case InkShape.Box b:
                var r = b.R;
                var c = new[] { new Pt(r.MinX, r.MinY), new Pt(r.MaxX, r.MinY), new Pt(r.MaxX, r.MaxY), new Pt(r.MinX, r.MaxY), new Pt(r.MinX, r.MinY) };
                return c.SelectMany(p => new[] { p, p }).ToList();
            case InkShape.Ellipse e:
                const int n = 72;
                return Enumerable.Range(0, n + 1).Select(i =>
                {
                    var a = i / (double)n * 2 * Math.PI - Math.PI / 2;
                    return new Pt(e.R.MidX + e.R.W / 2 * Math.Cos(a), e.R.MidY + e.R.H / 2 * Math.Sin(a));
                }).ToList();
            default: return new();
        }
    }

    /// Nearly level or upright (within 6°): exactly so.
    static Pt Straightened(Pt a, Pt b)
    {
        var ang = Math.Abs(Math.Atan2(b.Y - a.Y, b.X - a.X) * 180 / Math.PI);
        if (ang <= 6 || ang >= 174) return new Pt(b.X, a.Y);
        if (Math.Abs(ang - 90) <= 6) return new Pt(a.X, b.Y);
        return b;
    }

    static double DistanceToLine(Pt p, Pt a, Pt b)
    {
        var d = a.DistanceTo(b);
        if (d <= 0) return p.DistanceTo(a);
        return Math.Abs((b.X - a.X) * (a.Y - p.Y) - (a.X - p.X) * (b.Y - a.Y)) / d;
    }
}

public static class InkStyle
{
    /// The line in device-independent pixels: wider on a bigger display (its short side), 3–6 in halves.
    public static double Width(double screenShortSide) => Math.Round(Math.Min(6, Math.Max(3, screenShortSide / 260)) * 2) / 2;

    /// The markup colour (BrandColor.markup): #FF5C3D.
    public const uint Markup = 0xFF5C3D;

    /// A number badge's diameter in image pixels for a page drawn with `lineWidth` pixel lines.
    public static double BadgeDiameter(double lineWidth) => Math.Max(22, lineWidth * 6);

    /// A stroke as smooth segments through the midpoints (a doubled point is a sharp corner). Returns quadratic pieces:
    /// (from, control, to); a single point is a ring, two points a line.
    public static IEnumerable<(Pt from, Pt control, Pt to)> QuadPieces(IReadOnlyList<Pt> p)
    {
        if (p.Count < 2) yield break;
        var current = p[0];
        for (var i = 1; i < p.Count - 1; i++)
        {
            var mid = new Pt((p[i].X + p[i + 1].X) / 2, (p[i].Y + p[i + 1].Y) / 2);
            yield return (current, p[i], mid);
            current = mid;
        }
        var end = p[^1];
        yield return (current, new Pt((current.X + end.X) / 2, (current.Y + end.Y) / 2), end);
    }
}
