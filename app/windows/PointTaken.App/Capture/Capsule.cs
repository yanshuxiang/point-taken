// The capsule at the top of the screen while recording — BoardCapsule (Board.swift), measure for measure:
//   ⠿ ● 第 2 页 │ the newest words (230 pt, two lines) [kept pages] (✎)(▭)(○)(↶)(⏸) │ [完成]
// a 46-pt-tall near-black pill (radius 23, a 1-pt rim, orange 2-pt while the pen is on), round 30-pt tool buttons
// (an orange ring and icon on the chosen one), and under it a tip pill and an amber warnings card. It never takes
// the keyboard; drag it anywhere by its body. Clicking the words or the pages shows them (read-only).
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using PointTaken.App.Interop;
using PointTaken.Core;

namespace PointTaken.App.Capture;

public sealed class Capsule : Window
{
    /// One control on the row: round icon buttons (`On`: the orange ring), or the white 完成 pill (`Primary`).
    public sealed record Control(string Title, Geometry? Symbol, string Tip, Action Run, bool On = false, bool Primary = false, bool Filled = false);
    public sealed record Warning(string Text, BoardPermission? Permission);
    public enum Mic { Live, Starting, Off }

    const double WordsWidth = 230, EndInset = 8, ButtonSize = 30;

    readonly Grid root = new();
    readonly StackPanel column = new() { Orientation = Orientation.Vertical, HorizontalAlignment = HorizontalAlignment.Center };
    readonly Border pill;
    readonly ScaleTransform pillScale = new(1, 1);
    readonly StackPanel sessionRow = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, MinHeight = 34, Margin = new Thickness(0, 0, EndInset, 0) };
    readonly Grid dot = new() { Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center };
    readonly Ellipse dotCore = new();
    readonly Ellipse dotRing = new() { RenderTransformOrigin = new Point(0.5, 0.5) };
    readonly ScaleTransform ringScale = new(1, 1);
    Mic mic = Mic.Starting;
    readonly TextBlock pageLabel = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Mac.GlassText, VerticalAlignment = VerticalAlignment.Center, FontFamily = Mac.Font };
    readonly TextBlock words = new() { FontSize = 13, Width = WordsWidth, MaxHeight = 36, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Foreground = Mac.GlassText, FontFamily = Mac.Font, LineHeight = 17, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, Background = Brushes.Transparent };
    readonly Grid tray = new() { VerticalAlignment = VerticalAlignment.Center, Height = 36, Background = Brushes.Transparent };
    readonly Canvas trayStack = new() { Height = 36, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock trayCount = new() { FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Mac.GlassSecondary, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right, FontFamily = Mac.Digits, Margin = new Thickness(0, 0, 2, 0) };
    readonly StackPanel controls = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel messageRow = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, MinHeight = 34, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, EndInset, 0) };
    readonly TextBlock messageText = new() { FontSize = 14, FontWeight = FontWeights.Medium, Foreground = Mac.GlassText, TextWrapping = TextWrapping.Wrap, MaxWidth = 420, VerticalAlignment = VerticalAlignment.Center, FontFamily = Mac.Font };
    readonly ContentControl messageIcon = new() { Width = 17, Height = 17, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel messageButtons = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 0, 0, 0) };
    readonly StackPanel previewBox = new() { Orientation = Orientation.Vertical, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 14, 4) };
    readonly Border toastPill;
    readonly TextBlock toastLabel = new() { FontSize = 12, FontWeight = FontWeights.Medium, Foreground = Mac.GlassText, FontFamily = Mac.Font };
    readonly Border warningCard;
    readonly StackPanel warningsBox = new() { Orientation = Orientation.Vertical };
    System.Windows.Threading.DispatcherTimer? tipTimer, hideTimer;
    int tipGeneration;
    IntPtr hwnd;
    Point? dragStart;
    Point windowStart;
    bool moved;
    MonitorInfo? screen;
    static Point? anchor;   // where the user last let go of it (in DIPs of `anchorScreen`)
    static string? anchorScreen;
    List<string>? shownWarnings;
    bool plainWords;
    public bool Expanded => previewBox.Visibility == Visibility.Visible;
    public Func<(IReadOnlyList<BoardPage> pages, string text, IReadOnlyList<BitmapSource?> thumbs)>? PreviewSource;
    public Action<BoardPermission>? OnPermission;
    public Action? OnOpen;

    public Capsule()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Focusable = false;
        Title = "Point Taken";
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        // ⠿ ● 第 N 页
        var handle = new TextBlock { Text = "⠿", FontSize = 13, Foreground = Mac.GlassSecondary, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), Cursor = Cursors.SizeAll };
        dotRing.RenderTransform = ringScale;
        dotRing.Fill = Mac.Live; dotRing.Opacity = 0;
        dot.Children.Add(dotRing);
        dot.Children.Add(dotCore);
        dot.Margin = new Thickness(0, 0, 8, 0);
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(handle); left.Children.Add(dot); left.Children.Add(pageLabel);
        var divider = new Border { Width = 1, Height = 18, Background = Mac.White(0.14), Margin = new Thickness(12, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center };
        tray.Children.Add(trayStack);
        tray.Children.Add(trayCount);
        tray.Margin = new Thickness(12, 0, 0, 0);
        controls.Margin = new Thickness(12, 0, 0, 0);
        words.Cursor = Cursors.Arrow;
        sessionRow.Children.Add(left);
        sessionRow.Children.Add(divider);
        sessionRow.Children.Add(words);
        sessionRow.Children.Add(tray);
        sessionRow.Children.Add(controls);
        words.MouseLeftButtonUp += (_, _) => { if (!moved) OnOpen?.Invoke(); };
        tray.MouseLeftButtonUp += (_, _) => { if (!moved && trayStack.Children.Count > 0) OnOpen?.Invoke(); };

        messageRow.Children.Add(messageIcon);
        messageRow.Children.Add(messageText);
        messageRow.Children.Add(messageButtons);

        var inner = new StackPanel { Orientation = Orientation.Vertical, Margin = new Thickness(16, 6, 0, 6) };
        inner.Children.Add(sessionRow);
        inner.Children.Add(previewBox);
        inner.Children.Add(messageRow);
        pill = new Border
        {
            Background = Mac.Glass, BorderBrush = Mac.Rim, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(23), Child = inner,
            Effect = Mac.Shadow(14, 4, 0.35), RenderTransformOrigin = new Point(0.5, 0), RenderTransform = pillScale, HorizontalAlignment = HorizontalAlignment.Center,
        };
        pill.SizeChanged += (_, _) => pill.CornerRadius = new CornerRadius(Math.Min(23, pill.ActualHeight / 2));

        toastPill = new Border
        {
            Child = toastLabel, Background = Mac.Glass, BorderBrush = Mac.Rim, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 6, 14, 6), Effect = Mac.Shadow(14, 4, 0.35), Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 8, 0, 0),
        };
        warningsBox.Margin = new Thickness(14, 10, 10, 10);
        warningCard = new Border
        {
            Child = warningsBox, Background = Mac.Glass, BorderBrush = Mac.B(0x73, 0xFF, 0xBD, 0x33), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16),
            Effect = Mac.Shadow(14, 4, 0.35), Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0),
        };
        column.Children.Add(pill);
        column.Children.Add(toastPill);
        column.Children.Add(warningCard);
        // room for the shadows round the pill
        column.Margin = new Thickness(24, 4, 24, 24);
        root.Children.Add(column);
        Content = root;

        pill.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject d && (FindParent<ButtonBase>(d) != null || FindParent<ScrollViewer>(d) != null)) return;
            dragStart = PointToScreen(e.GetPosition(this)); windowStart = new Point(Left, Top); moved = false;
            pill.CaptureMouse();
        };
        pill.PreviewMouseMove += (_, e) =>
        {
            if (dragStart is not { } s || e.LeftButton != MouseButtonState.Pressed) return;
            var now = PointToScreen(e.GetPosition(this));
            if (!moved && (now - s).Length < 3) return;
            moved = true;
            var scale = screen?.Scale ?? 1;
            Left = windowStart.X + (now.X - s.X) / scale; Top = windowStart.Y + (now.Y - s.Y) / scale;
        };
        pill.PreviewMouseLeftButtonUp += (_, e) =>
        {
            if (dragStart == null) return;
            dragStart = null; pill.ReleaseMouseCapture();
            if (moved) { anchor = new Point(Left + ActualWidth / 2, Top); anchorScreen = screen?.Key; e.Handled = true; }
            Dispatcher.BeginInvoke(() => moved = false, System.Windows.Threading.DispatcherPriority.Input);
        };
        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            Native.MakePanel(hwnd, clickThrough: false);
            HwndSource.FromHwnd(hwnd)?.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }
                return IntPtr.Zero;
            });
        };
        SizeChanged += (_, _) => { if (IsVisible && dragStart == null) Place(); };
        SetMic(Mic.Starting);
    }

    static T? FindParent<T>(DependencyObject? d) where T : DependencyObject
    {
        while (d != null) { if (d is T t) return t; d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d); }
        return null;
    }

    // ── placement: top centre of the display it started on (10 pt below the top), or where it was let go ──

    void Place()
    {
        if (screen is not { } s) return;
        var scale = s.Scale;
        var w = ActualWidth;
        double centre, top;
        if (anchor is { } a && anchorScreen == s.Key) { centre = a.X; top = a.Y; }
        else
        {
            var work = SystemParameters.WorkArea;
            var screenTop = s.Y / scale;
            // the primary display's work area excludes a taskbar at the top
            if (s.X == 0 && s.Y == 0) screenTop = Math.Max(screenTop, work.Top);
            centre = s.X / scale + s.Width / scale / 2;
            top = screenTop + 6 - column.Margin.Top + 4;
        }
        Left = Math.Round(centre - w / 2);
        Top = Math.Round(top);
    }

    public void BeginSession()
    {
        screen = MonitorInfo.AtCursor() ?? MonitorInfo.All().FirstOrDefault();
        hideTimer?.Stop();
        previewBox.Visibility = Visibility.Collapsed;
        sessionRow.Visibility = Visibility.Visible;
        messageRow.Visibility = Visibility.Collapsed;
        toastPill.Visibility = Visibility.Collapsed;
        warningCard.Visibility = Visibility.Collapsed;
        shownWarnings = null;
        SetTray(Array.Empty<BitmapSource?>());
        SetPen(false);
        plainWords = false;
        Appear();
    }

    /// Grows out of the top edge like the Dynamic Island: a small pill springs down and out to full size.
    void Appear()
    {
        Opacity = 1;
        if (!IsVisible) Show();
        UpdateLayout();
        Place();
        Native.KeepOnTop(hwnd);
        var ease = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut };
        pillScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.34, 1, TimeSpan.FromMilliseconds(420)) { EasingFunction = ease });
        pillScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.42, 1, TimeSpan.FromMilliseconds(420)) { EasingFunction = ease });
        pill.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
        ((FrameworkElement)pill.Child).BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(240)) { BeginTime = TimeSpan.FromMilliseconds(100) });
    }

    /// Back into the top edge: shrinks toward the middle of the top while fading, then goes.
    public new void Hide()
    {
        tipTimer?.Stop(); hideTimer?.Stop();
        if (!IsVisible) return;
        var exit = new CubicEase { EasingMode = EasingMode.EaseIn };
        pillScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.34, TimeSpan.FromMilliseconds(240)) { EasingFunction = exit });
        pillScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.42, TimeSpan.FromMilliseconds(240)) { EasingFunction = exit });
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(200)) { BeginTime = TimeSpan.FromMilliseconds(40), EasingFunction = exit };
        fade.Completed += (_, _) =>
        {
            base.Hide();
            BeginAnimation(OpacityProperty, null); Opacity = 1;
            pillScale.BeginAnimation(ScaleTransform.ScaleXProperty, null); pillScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        };
        BeginAnimation(OpacityProperty, fade);
    }

    // ── the row ──

    public void SetControls(IReadOnlyList<Control> items)
    {
        controls.Children.Clear();
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            if (item.Primary && i > 0 && !items[i - 1].Primary)
                controls.Children.Add(new Border { Width = 1, Height = 20, Background = Mac.White(0.14), Margin = new Thickness(8, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
            var button = item.Primary ? PrimaryButton(item) : RoundButton(item);
            if (!item.Primary && i + 1 < items.Count && !items[i + 1].Primary) button.Margin = new Thickness(0, 0, 6, 0);
            controls.Children.Add(button);
        }
        controls.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    static Button RoundButton(Control c)
    {
        var color = c.On ? Mac.Markup : Mac.GlassText;
        var b = new Button
        {
            Content = c.Symbol == null ? null : Mac.Symbol(c.Symbol, c.Filled ? 13 : 16, color, 1.6, fill: c.Filled),
            Width = ButtonSize, Height = ButtonSize, ToolTip = c.Tip, Focusable = false, Cursor = Cursors.Arrow,
            Template = Mac.Template(c.On ? Mac.White(0.14) : Mac.White(0.10), c.On ? Mac.White(0.18) : Mac.White(0.16), ButtonSize / 2,
                                    c.On ? Mac.Markup : null, c.On ? 1.5 : 0, Mac.White(0.22)),
        };
        System.Windows.Automation.AutomationProperties.SetName(b, c.Title);
        b.Click += (_, _) => c.Run();
        return b;
    }

    static Button PrimaryButton(Control c)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = c.Title, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Mac.B(0xFF, 0x14, 0x14, 0x14), FontFamily = Mac.Font },
            Height = ButtonSize, Padding = new Thickness(14, 0, 14, 0), ToolTip = c.Tip, Focusable = false, Cursor = Cursors.Arrow,
            Template = Mac.Template(Mac.White(0.96), Mac.White(0.86), ButtonSize / 2, pressed: Mac.White(0.78)),
        };
        System.Windows.Automation.AutomationProperties.SetName(b, c.Title);
        b.Click += (_, _) => c.Run();
        return b;
    }

    void SetMic(Mic value)
    {
        mic = value;
        switch (value)
        {
            case Mic.Live:
                dotCore.Fill = Mac.Live; dotCore.Stroke = null; dotCore.StrokeThickness = 0;
                break;
            case Mic.Starting:
                dotCore.Fill = null; dotCore.Stroke = Mac.GlassSecondary; dotCore.StrokeThickness = 1.5; dotRing.Opacity = 0;
                break;
            default:
                dotCore.Fill = Mac.White(0.28); dotCore.Stroke = null; dotRing.Opacity = 0;
                break;
        }
    }

    public void Update(int page, string text, Mic mic, IReadOnlyList<Warning> warns, string holdKey)
    {
        SetMic(mic);
        var t = text.Trim();
        if (!plainWords || t.Length > 0)
        {
            plainWords = false;
            if (t.Length == 0)
            {
                words.Text = mic == Mic.Off ? "听写没开，只记你画的" : $"正在听 · 按住 {holdKey} 就能画";
                words.Foreground = Mac.GlassSecondary;
            }
            else
            {
                words.Foreground = Mac.GlassText;
                words.Text = NewestWords(t);
            }
        }
        var texts = warns.Select(w => w.Text).ToList();
        if (shownWarnings == null || !texts.SequenceEqual(shownWarnings))
        {
            shownWarnings = texts;
            warningsBox.Children.Clear();
            for (var i = 0; i < warns.Count; i++)
            {
                var row = WarningRow(warns[i]);
                if (i > 0) row.Margin = new Thickness(0, 8, 0, 0);
                warningsBox.Children.Add(row);
            }
        }
        warningCard.Visibility = warns.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        pageLabel.Text = warns.Count == 0 ? $"第 {page} 页" : $"第 {page} 页 · ⚠";
        if (Expanded) RefreshPreview();
    }

    /// The longest tail of `text` that fits the words' two lines (Chinese and Latin measured, not counted).
    string NewestWords(string text)
    {
        text = text.Replace("\n", " ");
        var typeface = new Typeface(words.FontFamily, words.FontStyle, words.FontWeight, words.FontStretch);
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        bool Fits(string s)
        {
            var f = new FormattedText(s, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, words.FontSize, Brushes.Black, dpi)
            { MaxTextWidth = WordsWidth, LineHeight = 17 };
            return f.Height <= 17 * 2 + 1;
        }
        var chars = new StringInfo(text);
        var n = chars.LengthInTextElements;
        var tail = n > 240 ? chars.SubstringByTextElements(n - 240) : text;
        if (tail.Length == text.Length && Fits(text)) return text;
        var info = new StringInfo(tail);
        int low = 0, high = info.LengthInTextElements;
        while (high - low > 1)
        {
            var mid = (low + high) / 2;
            if (Fits("…" + info.SubstringByTextElements(info.LengthInTextElements - mid))) low = mid; else high = mid;
        }
        return "…" + (low == 0 ? "" : info.SubstringByTextElements(info.LengthInTextElements - low));
    }

    FrameworkElement WarningRow(Warning w)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new Border { Child = Mac.Symbol(Icons.Triangle, 12, Mac.Warn, 0, fill: true), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = w.Text, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = Mac.GlassText, VerticalAlignment = VerticalAlignment.Center, FontFamily = Mac.Font, MaxWidth = 520, TextWrapping = TextWrapping.Wrap });
        if (w.Permission is { } p)
        {
            var b = SmallPill("打开设置", () => OnPermission?.Invoke(p));
            b.Margin = new Thickness(8, 0, 4, 0);
            row.Children.Add(b);
        }
        return row;
    }

    static Button SmallPill(string title, Action run)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Mac.GlassText, FontFamily = Mac.Font },
            Height = 22, Padding = new Thickness(11, 0, 11, 0), Focusable = false, Cursor = Cursors.Arrow, VerticalAlignment = VerticalAlignment.Center,
            Template = Mac.Template(Mac.White(0.16), Mac.White(0.24), 11, pressed: Mac.White(0.30)),
        };
        b.Click += (_, _) => run();
        return b;
    }

    public void SetPen(bool on)
    {
        pill.BorderThickness = new Thickness(on ? 2 : 1);
        pill.BorderBrush = on ? Mac.Markup : Mac.Rim;
    }

    /// The dot breathes with the voice: a green ring grows and shows with the level.
    public void SetLevel(float level)
    {
        if (mic != Mic.Live) return;
        var s = 1 + Math.Min(0.7, Math.Max(0, level) * 9);
        ringScale.ScaleX = ringScale.ScaleY = s * 1.25;
        dotRing.Opacity = Math.Min(0.55, level * 12);
    }

    /// The kept pages, stacked like cards (46 × 30, 6 apart, at most 3), newest on top, then how many.
    public void SetTray(IReadOnlyList<BitmapSource?> thumbs)
    {
        var grew = thumbs.Count > trayStack.Children.Count && thumbs.Count > 0;
        trayStack.Children.Clear();
        var shown = thumbs.TakeLast(3).ToList();
        for (var i = 0; i < shown.Count; i++)
        {
            var card = new Border
            {
                Width = 46, Height = 30, CornerRadius = new CornerRadius(4), BorderBrush = Mac.White(0.35), BorderThickness = new Thickness(1),
                Background = shown[i] is { } t ? new ImageBrush(t) { Stretch = Stretch.UniformToFill } : Mac.White(0.2),
                RenderTransformOrigin = new Point(0.5, 0.5),
            };
            Canvas.SetLeft(card, i * 6); Canvas.SetTop(card, 3);
            trayStack.Children.Add(card);
            if (grew && i == shown.Count - 1)
            {
                var s = new ScaleTransform(0.6, 0.6);
                card.RenderTransform = s;
                var spring = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut };
                s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(450)) { EasingFunction = spring });
                s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(450)) { EasingFunction = spring });
            }
        }
        var n = thumbs.Count;
        var stackWidth = n == 0 ? 0 : 46 + (Math.Min(n, 3) - 1) * 6;
        trayStack.Width = stackWidth;
        trayCount.Text = n > 0 ? $"{n} 页" : "";
        tray.Visibility = n == 0 ? Visibility.Collapsed : Visibility.Visible;
        trayCount.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        tray.Width = n == 0 ? 0 : stackWidth + 8 + trayCount.DesiredSize.Width + 2;
        tray.Cursor = n > 0 ? Cursors.Hand : null;
        if (Expanded) RefreshPreview();
    }

    /// A short tip in the small pill under the capsule that fades away by itself.
    public void Tip(string text, double seconds = 2.8)
    {
        tipTimer?.Stop();
        var generation = ++tipGeneration;
        toastLabel.Text = text;
        var wasHidden = toastPill.Visibility != Visibility.Visible;
        toastPill.BeginAnimation(OpacityProperty, null);
        toastPill.Opacity = 1;
        toastPill.Visibility = Visibility.Visible;
        if (wasHidden) toastPill.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200)));
        tipTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        tipTimer.Tick += (_, _) =>
        {
            tipTimer!.Stop();
            var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(300));
            fade.Completed += (_, _) => { if (tipGeneration == generation) { toastPill.Visibility = Visibility.Collapsed; toastPill.BeginAnimation(OpacityProperty, null); toastPill.Opacity = 1; } };
            toastPill.BeginAnimation(OpacityProperty, fade);
        };
        tipTimer.Start();
    }

    /// A page kept, a page dropped: said in the words' place (and kept with the notices).
    public void Toast(string text)
    {
        Notices.Post(text);
        plainWords = true;
        words.Text = text;
        words.Foreground = Mac.GlassText;
    }

    /// The capsule turns into one message (an error at the start); it hides after `seconds`.
    public void Message(string text, Brush tint, Geometry? symbol, double seconds, params (string title, Action run)[] actions)
    {
        if (screen == null) screen = MonitorInfo.AtCursor() ?? MonitorInfo.All().FirstOrDefault();
        controls.Visibility = Visibility.Collapsed;
        previewBox.Visibility = Visibility.Collapsed;
        toastPill.Visibility = Visibility.Collapsed;
        warningCard.Visibility = Visibility.Collapsed;
        sessionRow.Visibility = Visibility.Collapsed;
        messageRow.Visibility = Visibility.Visible;
        SetPen(false);
        messageIcon.Content = symbol == null ? null : Mac.Symbol(symbol, 15, tint, 0, fill: true);
        messageIcon.Visibility = symbol == null ? Visibility.Collapsed : Visibility.Visible;
        messageText.Text = text;
        messageButtons.Children.Clear();
        foreach (var (title, run) in actions) { var b = SmallPill(title, run); b.Margin = new Thickness(0, 0, 8, 0); messageButtons.Children.Add(b); }
        var wasShown = IsVisible;
        if (!wasShown) Appear(); else Place();
        hideTimer?.Stop();
        hideTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        hideTimer.Tick += (_, _) => { hideTimer!.Stop(); Hide(); };
        hideTimer.Start();
    }

    /// The pages and everything said so far, read-only, under the row.
    public void TogglePreview()
    {
        if (Expanded) { previewBox.Visibility = Visibility.Collapsed; return; }
        previewBox.Visibility = Visibility.Visible;
        RefreshPreview();
    }

    void RefreshPreview()
    {
        if (PreviewSource?.Invoke() is not { } src) return;
        previewBox.Children.Clear();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        foreach (var t in src.thumbs.Where(t => t != null).TakeLast(4))
            row.Children.Add(new Image { Source = t, Width = 110, Height = 100, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 8, 0) });
        if (row.Children.Count > 0) previewBox.Children.Add(row);
        var text = new TextBlock
        {
            Text = src.text.Length == 0 ? "暂无转写；结束后可编辑图片和文字" : src.text, FontSize = 12, Foreground = Mac.GlassText, TextWrapping = TextWrapping.Wrap,
            FontFamily = Mac.Font,
        };
        var scroll = new ScrollViewer { Content = text, Width = 540, Height = 130, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
        previewBox.Children.Add(scroll);
        scroll.ScrollToEnd();
    }
}
