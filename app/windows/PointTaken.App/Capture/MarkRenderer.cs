// Burns marks and their number badges into a copy of a screenshot (标注-*.png, the exported 图N.png) with the same
// look as the macOS app: one markup colour, round ends, a soft dark shadow, black numbered badges up-left of where
// each stroke began. GDI+ so it can run off the UI thread.
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public static class MarkRenderer
{
    public static readonly Color Markup = Color.FromArgb(255, 0xFF, 0x5C, 0x3D);

    /// The marked picture at full size, or scaled to `thumbnailHeight` (never up).
    public static Bitmap Render(Pixels image, IReadOnlyList<List<double[]>> strokes, IReadOnlyList<BoardMarkEvidence> evidence, double lineWidth, int? thumbnailHeight = null)
    {
        var scale = thumbnailHeight is { } h ? Math.Min(1.0, h / (double)image.Height) : 1.0;
        var w = Math.Max(1, (int)Math.Round(image.Width * scale));
        var hh = Math.Max(1, (int)Math.Round(image.Height * scale));
        var output = new Bitmap(w, hh, PixelFormat.Format32bppArgb);
        using var src = image.ToBitmap();
        using var g = Graphics.FromImage(output);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.DrawImage(src, 0, 0, w, hh);
        g.ScaleTransform((float)scale, (float)scale);
        DrawInk(g, image.Width, image.Height, strokes, lineWidth);
        DrawBadges(g, image.Width, image.Height, strokes, evidence, lineWidth);
        return output;
    }

    public static void DrawInk(Graphics g, double width, double height, IReadOnlyList<List<double[]>> strokes, double lineWidth)
    {
        foreach (var s in strokes)
        {
            var pts = s.Where(p => p.Length == 2).Select(p => new Pt(p[0] * width, p[1] * height)).ToList();
            if (pts.Count == 0) continue;
            using var path = new GraphicsPath();
            if (pts.Count == 1)
            {
                var r = lineWidth * 4.5;
                path.AddEllipse((float)(pts[0].X - r), (float)(pts[0].Y - r), (float)(r * 2), (float)(r * 2));
            }
            else
            {
                foreach (var (from, control, to) in InkStyle.QuadPieces(pts))
                {
                    // a quadratic as a cubic: control points 2/3 of the way to the quadratic's control
                    var c1 = new PointF((float)(from.X + 2.0 / 3 * (control.X - from.X)), (float)(from.Y + 2.0 / 3 * (control.Y - from.Y)));
                    var c2 = new PointF((float)(to.X + 2.0 / 3 * (control.X - to.X)), (float)(to.Y + 2.0 / 3 * (control.Y - to.Y)));
                    path.AddBezier(new PointF((float)from.X, (float)from.Y), c1, c2, new PointF((float)to.X, (float)to.Y));
                }
            }
            // the soft shadow: two wider translucent strokes under the line
            foreach (var (extra, alpha) in new[] { (lineWidth * 0.9, 40), (lineWidth * 0.45, 70) })
            {
                using var shadow = new Pen(Color.FromArgb(alpha, 0, 0, 0), (float)(lineWidth + extra)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
                g.DrawPath(shadow, path);
            }
            using var pen = new Pen(Markup, (float)lineWidth) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            g.DrawPath(pen, path);
        }
    }

    public static void DrawBadges(Graphics g, double width, double height, IReadOnlyList<List<double[]>> strokes, IReadOnlyList<BoardMarkEvidence> evidence, double lineWidth)
    {
        var diameter = InkStyle.BadgeDiameter(lineWidth);
        using var fill = new SolidBrush(Color.FromArgb((int)(0.88 * 255), 0, 0, 0));
        using var ring = new Pen(Color.White, (float)Math.Max(1, lineWidth / 3));
        using var font = new Font("Segoe UI", (float)(diameter * 0.5), FontStyle.Bold, GraphicsUnit.Pixel);
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        for (var i = 0; i < Math.Min(strokes.Count, evidence.Count); i++)
        {
            if (BoardMarkSheet.BadgeCenter(strokes[i], width, height, diameter) is not { } c) continue;
            var rect = new RectangleF((float)(c.X - diameter / 2), (float)(c.Y - diameter / 2), (float)diameter, (float)diameter);
            g.FillEllipse(fill, rect);
            g.DrawEllipse(ring, rect);
            g.DrawString(evidence[i].Number.ToString(), font, Brushes.White, rect, format);
        }
    }

    /// Writes a PNG next to the target and renames it into place. False when it could not.
    public static bool WritePng(Bitmap bmp, string path)
    {
        var tmp = Path.Combine(Path.GetDirectoryName(path)!, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            bmp.Save(tmp, ImageFormat.Png);
            File.Move(tmp, path, overwrite: true);
            return true;
        }
        catch { return false; }
        finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
    }

    public static bool WritePng(Pixels pixels, string path)
    {
        using var bmp = pixels.ToBitmap();
        return WritePng(bmp, path);
    }

    /// A WPF image of a GDI+ bitmap (frozen).
    public static System.Windows.Media.Imaging.BitmapSource ToSource(Bitmap bmp)
    {
        using var p = new MemoryStream();
        bmp.Save(p, ImageFormat.Bmp);
        p.Position = 0;
        var decoder = new System.Windows.Media.Imaging.BmpBitmapDecoder(p, System.Windows.Media.Imaging.BitmapCreateOptions.PreservePixelFormat, System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        frame.Freeze();
        return frame;
    }

    /// A list-sized thumbnail of a PNG on disk (96 px tall by default).
    public static System.Windows.Media.Imaging.BitmapSource? Thumbnail(string path, int height = 96)
    {
        try
        {
            var image = new System.Windows.Media.Imaging.BitmapImage();
            image.BeginInit();
            image.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
            image.DecodePixelHeight = height;
            image.StreamSource = new MemoryStream(File.ReadAllBytes(path));
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch { return null; }
    }
}

/// Screenshots written off the UI thread, one serial queue; the latest write of a file wins. Whatever reads files
/// back (the review, the finish) waits with WhenFinished first. A failed write is kept (with its pixels) and said.
public static class BoardFileWriter
{
    sealed class Work { public Guid Id = Guid.NewGuid(); public required Func<bool> Run; public Pixels? Original; }
    static readonly object gate = new();
    static readonly Dictionary<string, Work> pending = new(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, Work> failed = new(StringComparer.OrdinalIgnoreCase);
    static readonly HashSet<string> cancelled = new(StringComparer.OrdinalIgnoreCase);
    static readonly List<string> order = new();
    static readonly HashSet<string> imageWork = new(StringComparer.OrdinalIgnoreCase);
    static bool draining;
    public static Action<string>? OnFailure;

    public static void Enqueue(string path, Func<bool> write, bool image = false, Pixels? original = null)
    {
        bool start;
        lock (gate)
        {
            if (!pending.ContainsKey(path)) order.Add(path);
            pending[path] = new Work { Run = write, Original = original };
            failed.Remove(path); cancelled.Remove(path);
            if (image) imageWork.Add(path);
            start = !draining; draining = true;
        }
        if (start) Task.Run(Drain);
    }

    static void Drain()
    {
        while (true)
        {
            string path; Work work;
            lock (gate)
            {
                if (order.Count == 0) { draining = false; Monitor.PulseAll(gate); return; }
                var i = order.FindIndex(imageWork.Contains);
                if (i < 0) i = 0;
                path = order[i]; order.RemoveAt(i);
                work = pending[path]; pending.Remove(path); imageWork.Remove(path);
            }
            bool ok;
            try { ok = work.Run(); } catch { ok = false; }
            lock (gate) if (!ok && !pending.ContainsKey(path) && !cancelled.Contains(path)) failed[path] = work;
            if (!ok) OnFailure?.Invoke("文件保存失败，请检查存储空间并重试：" + Path.GetFileName(path));
        }
    }

    public static void Png(Pixels image, string path) => Enqueue(path, () => MarkRenderer.WritePng(image, path), image: true, original: image);

    public static void Marked(Pixels image, BoardPage page, string path)
    {
        var marks = page.Marks.Select(m => m.ToList()).ToList();
        var evidence = page.MarkEvidence.ToList();
        var width = page.LineWidth;
        Enqueue(path, () =>
        {
            using var bmp = MarkRenderer.Render(image, marks, evidence, width);
            return MarkRenderer.WritePng(bmp, path);
        }, image: true);
    }

    public static void Text(string path, Func<string> text) => Enqueue(path, () =>
    {
        try { AtomicFile.WriteText(path, text()); return true; } catch { return false; }
    });

    public static void Remove(IEnumerable<string> files)
    {
        var list = files.ToList();
        lock (gate)
        {
            foreach (var f in list) { pending.Remove(f); failed.Remove(f); imageWork.Remove(f); cancelled.Add(f); }
            order.RemoveAll(o => list.Contains(o, StringComparer.OrdinalIgnoreCase));
        }
        // an encode in progress finishes first, else undo could bring the PNG back
        Task.Run(() =>
        {
            Flush();
            foreach (var f in list) { try { File.Delete(f); } catch { } }
            lock (gate) foreach (var f in list) cancelled.Remove(f);
        });
    }

    /// Blocks until the queue is empty.
    public static void Flush()
    {
        lock (gate) while (draining || order.Count > 0) Monitor.Wait(gate, 200);
    }

    public static Pixels? RecoveryImage(string path) { lock (gate) return pending.GetValueOrDefault(path)?.Original ?? failed.GetValueOrDefault(path)?.Original; }
    public static bool NeedsRepair(string path) { lock (gate) return failed.ContainsKey(path); }

    public static string? Warning(string? directory)
    {
        lock (gate)
        {
            var count = failed.Keys.Count(k => directory == null || string.Equals(Path.GetDirectoryName(k), directory, StringComparison.OrdinalIgnoreCase));
            return count == 0 ? null : $"还有 {count} 个文件未能保存，内容暂留在内存中。请腾出空间后重新打开检查窗口重试；退出应用会失去未保存的内容。";
        }
    }

    /// Calls `done` (on the caller's dispatcher) once every queued write has landed; failed writes get one retry.
    public static void WhenFinished(Action done, System.Windows.Threading.Dispatcher ui)
    {
        Task.Run(() =>
        {
            Dictionary<string, Work> retry;
            lock (gate) retry = new(failed);
            foreach (var (path, work) in retry)
            {
                bool ok;
                try { ok = work.Run(); } catch { ok = false; }
                if (ok) lock (gate) if (failed.TryGetValue(path, out var w) && w.Id == work.Id) failed.Remove(path);
            }
            Flush();
            ui.BeginInvoke(done);
        });
    }
}
