// Page detection without OCR or URLs: a 64×40 grey signature per captured frame, a gate that debounces navigation
// and scroll bursts, and a mask of what moves on its own (a carousel, a video). Ported from BoardPaging.swift and
// BoardMotionMask.swift with the same thresholds.
namespace PointTaken.Core;

public sealed class BoardFrameFingerprint
{
    public const int Width = 64, Height = 40;
    public byte[] Values { get; }
    public BoardFrameFingerprint(byte[] values) { Values = values; }

    /// From 32-bit BGRA pixels (top row first): the mean grey of each cell.
    public static BoardFrameFingerprint FromBgra(ReadOnlySpan<byte> pixels, int width, int height, int stride)
    {
        var sums = new long[Width * Height];
        var counts = new int[Width * Height];
        // sample every few pixels: a 4K frame is still cheap
        var stepX = Math.Max(1, width / (Width * 4));
        var stepY = Math.Max(1, height / (Height * 4));
        for (var y = 0; y < height; y += stepY)
        {
            var cy = Math.Min(Height - 1, y * Height / height);
            var row = y * stride;
            for (var x = 0; x < width; x += stepX)
            {
                var cx = Math.Min(Width - 1, x * Width / width);
                var i = row + x * 4;
                var grey = (pixels[i] * 29 + pixels[i + 1] * 150 + pixels[i + 2] * 77) >> 8;
                sums[cy * Width + cx] += grey;
                counts[cy * Width + cx]++;
            }
        }
        var values = new byte[Width * Height];
        for (var i = 0; i < values.Length; i++) values[i] = counts[i] == 0 ? (byte)0 : (byte)(sums[i] / counts[i]);
        return new BoardFrameFingerprint(values);
    }

    public double Distance(BoardFrameFingerprint other)
    {
        if (Values.Length != other.Values.Length || Values.Length == 0) return 1;
        long sum = 0;
        for (var i = 0; i < Values.Length; i++) sum += Math.Abs(Values[i] - other.Values[i]);
        return sum / (double)(Values.Length * 255);
    }
}

/// Debounces navigation and scroll bursts. It never sees key contents and never consumes input.
public sealed class BoardPageGate
{
    public enum Decision { Reference, Leave, Settling }
    string? context;
    BoardFrameFingerprint? previous;
    bool settling;
    double? stableSince;
    double lastScroll = double.NegativeInfinity;
    double lastInput = double.NegativeInfinity;

    public void Interaction(double time, bool scroll)
    {
        lastInput = time;
        if (scroll) lastScroll = time;
    }

    public Decision Observe(BoardFrameFingerprint next, string nextContext, double time, BoardMotionMask? mask = null)
    {
        try
        {
            if (previous == null || context == null) return Decision.Reference;
            var difference = (mask ?? new BoardMotionMask()).Distance(next, previous);
            if (context != nextContext) { settling = true; stableSince = null; return Decision.Leave; }
            if (settling)
            {
                if (difference < 0.018 && time - lastScroll > 0.4)
                {
                    stableSince ??= time;
                    if (time - stableSince.Value >= 0.35) { settling = false; return Decision.Reference; }
                }
                else stableSince = null;
                return Decision.Settling;
            }
            if ((time - lastScroll < 0.6 && difference > 0.008) || (time - lastInput < 1.5 && difference > 0.045))
            {
                settling = true; stableSince = null;
                return Decision.Leave;
            }
            return Decision.Reference;
        }
        finally { previous = next; context = nextContext; }
    }
}

/// The parts of the screen that move on their own, learned from frames that changed while the user did nothing.
public sealed class BoardMotionMask
{
    public const int Columns = 64, Rows = 40;
    const int Count = Columns * Rows;
    const int CellTolerance = 8;
    public const double WidgetLimit = 0.5;

    bool[] dynamic = new bool[Count];
    public bool IsEmpty => !dynamic.Contains(true);
    public double Share => dynamic.Count(d => d) / (double)Count;
    public bool Usable => !IsEmpty && Share <= WidgetLimit;
    public void Reset() => dynamic = new bool[Count];

    public void Learn(BoardFrameFingerprint a, BoardFrameFingerprint b)
    {
        if (a.Values.Length != Count || b.Values.Length != Count) return;
        var changed = Enumerable.Range(0, Count).Where(i => Math.Abs(a.Values[i] - b.Values[i]) > CellTolerance).ToList();
        if (changed.Count == 0 || changed.Count > WidgetLimit * Count) return;
        var next = (bool[])dynamic.Clone();
        foreach (var index in changed)
        {
            int x = index % Columns, y = index / Columns;
            for (var dy = -1; dy <= 1; dy++)
                for (var dx = -1; dx <= 1; dx++)
                {
                    int nx = x + dx, ny = y + dy;
                    if (nx >= 0 && nx < Columns && ny >= 0 && ny < Rows) next[ny * Columns + nx] = true;
                }
        }
        if (next.Count(d => d) > WidgetLimit * Count) return;
        dynamic = next;
    }

    public double Distance(BoardFrameFingerprint a, BoardFrameFingerprint b)
    {
        if (!Usable || a.Values.Length != Count || b.Values.Length != Count) return a.Distance(b);
        long sum = 0; var cells = 0;
        for (var i = 0; i < Count; i++)
            if (!dynamic[i]) { sum += Math.Abs(a.Values[i] - b.Values[i]); cells++; }
        return cells > 0 ? sum / (double)(cells * 255) : 0;
    }

    public double MovingDistance(BoardFrameFingerprint a, BoardFrameFingerprint b)
    {
        if (!Usable || a.Values.Length != Count || b.Values.Length != Count) return 0;
        long sum = 0; var cells = 0;
        for (var i = 0; i < Count; i++)
            if (dynamic[i]) { sum += Math.Abs(a.Values[i] - b.Values[i]); cells++; }
        return cells > 0 ? sum / (double)(cells * 255) : 0;
    }

    /// Whether a mark (points 0–1 from the top-left) lies on a moving cell, its bounding box included.
    public bool Touches(IReadOnlyList<double[]> stroke)
    {
        if (!Usable) return false;
        var points = stroke.Where(p => p.Length == 2).ToList();
        if (points.Count == 0) return false;
        double minX = points.Min(p => p[0]), maxX = points.Max(p => p[0]), minY = points.Min(p => p[1]), maxY = points.Max(p => p[1]);
        if (maxX < 0 || minX > 1 || maxY < 0 || minY > 1) return false;
        static int Col(double v) => Math.Min(Columns - 1, Math.Max(0, (int)(v * Columns)));
        static int Row(double v) => Math.Min(Rows - 1, Math.Max(0, (int)(v * Rows)));
        for (var y = Row(minY); y <= Row(maxY); y++)
            for (var x = Col(minX); x <= Col(maxX); x++)
                if (dynamic[y * Columns + x]) return true;
        return false;
    }
}
