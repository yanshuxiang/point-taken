// A captured screen picture in memory (32-bit BGRA, top row first) and the conversions the app needs: a WPF image
// for showing it, a GDI+ bitmap for drawing marks and writing PNGs. Frames are immutable once made.
using System.Drawing;
using System.Drawing.Imaging;
using PixelFormat = System.Drawing.Imaging.PixelFormat;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class Pixels
{
    public int Width { get; }
    public int Height { get; }
    public int Stride => Width * 4;
    public byte[] Data { get; }
    public Pixels(int width, int height, byte[] data) { Width = width; Height = height; Data = data; }

    BitmapSource? source;
    /// a frozen WPF image (safe to share across threads)
    public BitmapSource Source
    {
        get
        {
            if (source != null) return source;
            var s = BitmapSource.Create(Width, Height, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, Data, Stride);
            s.Freeze();
            return source = s;
        }
    }

    /// A GDI+ bitmap sharing nothing with this buffer (the caller disposes it).
    public Bitmap ToBitmap()
    {
        var bmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(new Rectangle(0, 0, Width, Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (var y = 0; y < Height; y++) Marshal.Copy(Data, y * Stride, data.Scan0 + y * data.Stride, Stride);
        }
        finally { bmp.UnlockBits(data); }
        return bmp;
    }

    public static Pixels FromBitmap(Bitmap bmp)
    {
        var w = bmp.Width; var h = bmp.Height;
        var bytes = new byte[w * h * 4];
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (var y = 0; y < h; y++) Marshal.Copy(data.Scan0 + y * data.Stride, bytes, y * w * 4, w * 4);
        }
        finally { bmp.UnlockBits(data); }
        return new Pixels(w, h, bytes);
    }

    public static Pixels? Load(string path)
    {
        try
        {
            using var stream = new MemoryStream(File.ReadAllBytes(path));
            using var img = new Bitmap(stream);
            using var bmp = new Bitmap(img.Width, img.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp)) g.DrawImage(img, 0, 0, img.Width, img.Height);
            return FromBitmap(bmp);
        }
        catch { return null; }
    }

    public BoardFrameFingerprint Fingerprint() => BoardFrameFingerprint.FromBgra(Data, Width, Height, Stride);
}

public sealed class ScreenFrame
{
    public required Pixels Image { get; init; }
    /// the display, physical pixels
    public required Interop.MonitorInfo Display { get; init; }
    /// which window was in front ("pid:hwnd:display")
    public required string Scene { get; init; }
    public string AppName { get; init; } = "";
    public string Title { get; init; } = "";
    public required BoardFrameFingerprint Fingerprint { get; init; }
    /// Uptime.Now when the picture was taken
    public double CapturedAt { get; init; } = Uptime.Now;
    public string DisplayKey => Display.Key;
}
