// The macOS app's look, in WPF: its semantic colours (label / secondary / tertiary / separator, the green accent
// #109478, the capsule's near-black glass), its type scale one point up (BoardStyle: body 14, callout 13, subheadline
// 12, title3 16), its 4-pt spacing (4 / 8 / 12 / 20) and corner radii (8 thumbnails, 12 cards), and the SF Symbols it
// uses, redrawn as vector paths so they look the same at every size.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;

namespace PointTaken.App;

public static class Mac
{
    // ── colours (light appearance) ──
    public static readonly SolidColorBrush Label = B(0xD9, 0, 0, 0);          // labelColor ≈ black 85 %
    public static readonly SolidColorBrush Secondary = B(0x80, 0, 0, 0);      // secondaryLabelColor ≈ 50 %
    public static readonly SolidColorBrush Tertiary = B(0x42, 0, 0, 0);       // tertiaryLabelColor ≈ 26 %
    public static readonly SolidColorBrush Quaternary = B(0x1A, 0, 0, 0);     // quaternaryLabelColor ≈ 10 %
    public static readonly SolidColorBrush Separator = B(0x1A, 0, 0, 0);
    public static readonly SolidColorBrush Window = B(0xFF, 0xFF, 0xFF, 0xFF);
    public static readonly SolidColorBrush Sidebar = B(0xFF, 0xEC, 0xEC, 0xEE);
    public static readonly SolidColorBrush UnderPage = B(0xFF, 0xF7, 0xF7, 0xF8);
    public static readonly SolidColorBrush Group = B(0xFF, 0xF4, 0xF4, 0xF5);   // a settings group's fill
    public static readonly SolidColorBrush GroupEdge = B(0x0F, 0, 0, 0);
    public static readonly SolidColorBrush Control = B(0x14, 0, 0, 0);          // a glass button's fill
    public static readonly SolidColorBrush Hover = B(0x0F, 0, 0, 0);
    public static readonly SolidColorBrush Selection = B(0x1A, 0, 0, 0);        // labelColor 10 %
    public static readonly SolidColorBrush Accent = B(0xFF, 0x10, 0x94, 0x78);
    public static readonly SolidColorBrush AccentWash = B(0x1A, 0x10, 0x94, 0x78);
    public static readonly SolidColorBrush Orange = B(0xFF, 0xFF, 0x95, 0x00);  // systemOrange
    public static readonly SolidColorBrush Attention = B(0xFF, 0xB8, 0x6E, 0x00);
    public static readonly SolidColorBrush Markup = B(0xFF, 0xFF, 0x5C, 0x3D);

    // the capsule (BoardColor)
    public static readonly SolidColorBrush Glass = B(0xF5, 0x16, 0x16, 0x1A);
    public static readonly SolidColorBrush Rim = B(0x1A, 0xFF, 0xFF, 0xFF);
    public static readonly SolidColorBrush GlassText = B(0xF0, 0xFF, 0xFF, 0xFF);
    public static readonly SolidColorBrush GlassSecondary = B(0x8C, 0xFF, 0xFF, 0xFF);
    public static readonly SolidColorBrush GlassFaint = B(0x52, 0xFF, 0xFF, 0xFF);
    public static readonly SolidColorBrush Live = B(0xFF, 0x33, 0xD6, 0x6B);
    public static readonly SolidColorBrush Warn = B(0xFF, 0xFF, 0xBD, 0x33);

    public static SolidColorBrush B(byte a, byte r, byte g, byte b) { var s = new SolidColorBrush(Color.FromArgb(a, r, g, b)); s.Freeze(); return s; }
    public static SolidColorBrush White(double alpha) => B((byte)Math.Round(alpha * 255), 255, 255, 255);
    public static SolidColorBrush Black(double alpha) => B((byte)Math.Round(alpha * 255), 0, 0, 0);

    // ── type: the system text styles one point up ──
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI");
    public static readonly FontFamily Digits = new("Segoe UI Variable Text, Segoe UI");
    public const double Body = 14, Callout = 13, Subheadline = 12, Title3 = 16, Headline = 14, Title2 = 18, Title1 = 22;

    // ── space ──
    public const double Margin = 20, GroupGap = 12, Inner = 8, Tight = 4, Hit = 30;
    public const double ThumbRadius = 8, PictureRadius = 12, CardRadius = 12;

    public static TextBlock Text(string text, double size = Body, FontWeight? weight = null, Brush? color = null, bool wrap = false, bool digits = false) => new()
    {
        Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, Foreground = color ?? Label, FontFamily = digits ? Digits : Font,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
        Typography = { NumeralAlignment = digits ? FontNumeralAlignment.Tabular : FontNumeralAlignment.Normal },
    };

    public static DropShadowEffect Shadow(double blur, double depth, double opacity) =>
        new() { BlurRadius = blur, ShadowDepth = depth, Direction = 270, Opacity = opacity, Color = Colors.Black };

    // ── buttons ──

    /// A template drawing `fill` (and `hover`) under the content, rounded by `radius`.
    public static ControlTemplate Template(Brush fill, Brush? hover, double radius, Brush? border = null, double borderWidth = 0, Brush? pressed = null)
    {
        var t = new ControlTemplate(typeof(ButtonBase));
        var f = new FrameworkElementFactory(typeof(Border), "b");
        f.SetValue(Border.BackgroundProperty, fill);
        f.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        if (border != null) { f.SetValue(Border.BorderBrushProperty, border); f.SetValue(Border.BorderThicknessProperty, new Thickness(borderWidth)); }
        f.SetValue(Border.PaddingProperty, new TemplateBindingExtension(System.Windows.Controls.Control.PaddingProperty));
        f.SetValue(UIElement.SnapsToDevicePixelsProperty, true);
        var c = new FrameworkElementFactory(typeof(ContentPresenter));
        c.SetValue(FrameworkElement.HorizontalAlignmentProperty, new TemplateBindingExtension(System.Windows.Controls.Control.HorizontalContentAlignmentProperty));
        c.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        f.AppendChild(c);
        t.VisualTree = f;
        if (hover != null)
        {
            var h = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
            h.Setters.Add(new Setter(Border.BackgroundProperty, hover, "b"));
            t.Triggers.Add(h);
        }
        if (pressed != null)
        {
            var p = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
            p.Setters.Add(new Setter(Border.BackgroundProperty, pressed, "b"));
            t.Triggers.Add(p);
        }
        var d = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        d.Setters.Add(new Setter(UIElement.OpacityProperty, 0.35, "b"));
        t.Triggers.Add(d);
        return t;
    }

    static Button Base(object content, string? tip, Action run)
    {
        var b = new Button { Content = content, ToolTip = tip, Cursor = Cursors.Arrow, Focusable = false, HorizontalContentAlignment = HorizontalAlignment.Center };
        if (tip != null) System.Windows.Automation.AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => run();
        return b;
    }

    /// A macOS push button on glass (保存并关闭, 打开文件夹…): a soft grey capsule, label text.
    public static Button Push(string title, Action run, string? tip = null, double height = 32, double size = Body)
    {
        var b = Base(Text(title, size, FontWeights.Medium), tip, run);
        b.Height = height; b.Padding = new Thickness(16, 0, 16, 0);
        b.Template = Template(B(0x12, 0, 0, 0), B(0x1C, 0, 0, 0), height / 2, pressed: B(0x26, 0, 0, 0));
        System.Windows.Automation.AutomationProperties.SetName(b, title);
        return b;
    }

    /// The window's one primary command (复制并关闭, 下载): the accent fill, white text.
    public static Button Primary(string title, Action run, string? tip = null, double height = 32, double size = Body)
    {
        var text = Text(title, size, FontWeights.SemiBold, Brushes.White);
        var b = Base(text, tip, run);
        b.Height = height; b.Padding = new Thickness(18, 0, 18, 0);
        b.Template = Template(Accent, B(0xFF, 0x0E, 0x86, 0x6C), height / 2, pressed: B(0xFF, 0x0B, 0x73, 0x5E));
        System.Windows.Automation.AutomationProperties.SetName(b, title);
        return b;
    }

    /// A borderless symbol button (toolbar items, a list's foot bar, row actions).
    public static Button Icon(Geometry symbol, string tip, Action run, double size = 30, double glyph = 17, Brush? color = null, double radius = 8)
    {
        var b = Base(Symbol(symbol, glyph, color ?? Secondary), tip, run);
        b.Width = size; b.Height = size;
        b.Template = Template(Brushes.Transparent, Hover, radius, pressed: Selection);
        return b;
    }

    /// A group of toolbar icons on one glass capsule (macOS 26 toolbar style).
    public static Border ToolbarGroup(params UIElement[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0, 4, 0) };
        foreach (var i in items) row.Children.Add(i);
        return new Border
        {
            Child = row, Height = 40, CornerRadius = new CornerRadius(20), Background = B(0xF2, 0xFA, 0xFA, 0xFA),
            BorderBrush = B(0x14, 0, 0, 0), BorderThickness = new Thickness(1), Effect = Shadow(10, 1, 0.08),
        };
    }

    /// A symbol drawn as a stroked path in a `size` box.
    public static FrameworkElement Symbol(Geometry g, double size, Brush color, double stroke = 1.5, bool fill = false)
    {
        var p = new Path
        {
            Data = g, Width = size, Height = size, Stretch = Stretch.Uniform, StrokeThickness = stroke,
            Stroke = fill ? null : color, Fill = fill ? color : null,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
            SnapsToDevicePixels = false,
        };
        return p;
    }

    public static Border Rule(bool vertical = false) => vertical
        ? new Border { Width = 1, Background = Separator }
        : new Border { Height = 1, Background = Separator };

    // ── controls ──

    /// A macOS switch: a 38×22 track, the accent when on.
    public static ToggleButton Switch(bool on, Action<bool> changed)
    {
        var t = new ToggleButton { IsChecked = on, Width = 38, Height = 22, Cursor = Cursors.Arrow, Focusable = false };
        var template = new ControlTemplate(typeof(ToggleButton));
        var track = new FrameworkElementFactory(typeof(Border), "track");
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(11));
        track.SetValue(Border.BackgroundProperty, B(0x26, 0, 0, 0));
        var knob = new FrameworkElementFactory(typeof(Ellipse), "knob");
        knob.SetValue(FrameworkElement.WidthProperty, 18.0);
        knob.SetValue(FrameworkElement.HeightProperty, 18.0);
        knob.SetValue(Shape.FillProperty, Brushes.White);
        knob.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left);
        knob.SetValue(FrameworkElement.MarginProperty, new Thickness(2, 0, 0, 0));
        knob.SetValue(UIElement.EffectProperty, Shadow(3, 1, 0.25));
        track.AppendChild(knob);
        template.VisualTree = track;
        var onTrigger = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        onTrigger.Setters.Add(new Setter(Border.BackgroundProperty, Accent, "track"));
        onTrigger.Setters.Add(new Setter(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Right, "knob"));
        onTrigger.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(0, 0, 2, 0), "knob"));
        template.Triggers.Add(onTrigger);
        t.Template = template;
        t.Click += (_, _) => changed(t.IsChecked == true);
        return t;
    }

    /// A macOS checkbox (16 pt rounded square, the accent with a white check when on).
    public static CheckBox Check(bool on, string? tip = null)
    {
        var c = new CheckBox { IsChecked = on, ToolTip = tip, Cursor = Cursors.Arrow, Focusable = false, Width = Hit, Height = Hit, VerticalAlignment = VerticalAlignment.Center };
        var template = new ControlTemplate(typeof(CheckBox));
        var grid = new FrameworkElementFactory(typeof(Grid));
        grid.SetValue(Panel.BackgroundProperty, Brushes.Transparent);
        var box = new FrameworkElementFactory(typeof(Border), "box");
        box.SetValue(FrameworkElement.WidthProperty, 18.0);
        box.SetValue(FrameworkElement.HeightProperty, 18.0);
        box.SetValue(Border.CornerRadiusProperty, new CornerRadius(5));
        box.SetValue(Border.BackgroundProperty, Brushes.White);
        box.SetValue(Border.BorderBrushProperty, B(0x40, 0, 0, 0));
        box.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        var mark = new FrameworkElementFactory(typeof(Path), "mark");
        mark.SetValue(Path.DataProperty, Icons.Checkmark);
        mark.SetValue(Shape.StrokeProperty, Brushes.White);
        mark.SetValue(Shape.StrokeThicknessProperty, 2.0);
        mark.SetValue(Shape.StrokeStartLineCapProperty, PenLineCap.Round);
        mark.SetValue(Shape.StrokeEndLineCapProperty, PenLineCap.Round);
        mark.SetValue(Shape.StrokeLineJoinProperty, PenLineJoin.Round);
        mark.SetValue(Shape.StretchProperty, Stretch.Uniform);
        mark.SetValue(FrameworkElement.MarginProperty, new Thickness(3.5));
        mark.SetValue(UIElement.VisibilityProperty, Visibility.Hidden);
        box.AppendChild(mark);
        grid.AppendChild(box);
        template.VisualTree = grid;
        var checkedOn = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        checkedOn.Setters.Add(new Setter(Border.BackgroundProperty, Accent, "box"));
        checkedOn.Setters.Add(new Setter(Border.BorderBrushProperty, Accent, "box"));
        checkedOn.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Visible, "mark"));
        template.Triggers.Add(checkedOn);
        c.Template = template;
        return c;
    }

    /// A keycap (the shortcut rows in Settings): rounded grey with the key in semibold.
    public static Border KeyCap(string key, double size = 15) => new()
    {
        Child = new TextBlock { Text = key, FontSize = size, FontWeight = FontWeights.SemiBold, Foreground = Label, FontFamily = Font, HorizontalAlignment = HorizontalAlignment.Center },
        Background = B(0x0F, 0, 0, 0), CornerRadius = new CornerRadius(7), Padding = new Thickness(9, 4, 9, 4), MinWidth = 30, Margin = new Thickness(4, 0, 0, 0),
    };
}

/// SF Symbols the app uses, redrawn as paths in a 24×24 box (stroked unless noted).
public static class Icons
{
    static Geometry G(string data) { var g = Geometry.Parse(data); g.Freeze(); return g; }

    public static readonly Geometry Scribble = G("M3,16 C5,12 7,8 9,8 C11,8 8,15 10,16 C12,17 14,9 16,9 C18,9 15,16 17,16 C18.5,16 20,14 21,13 M14,21 L21,21");
    public static readonly Geometry Rectangle = G("M4,6 L20,6 Q21,6 21,7 L21,17 Q21,18 20,18 L4,18 Q3,18 3,17 L3,7 Q3,6 4,6 Z");
    public static readonly Geometry Circle = G("M12,3.5 A8.5,8.5 0 1 1 11.99,3.5 Z");
    public static readonly Geometry Undo = G("M9,5 L4,10 L9,15 M4,10 L15,10 C18,10 20,12 20,15 C20,18 18,20 15,20 L11,20");
    public static readonly Geometry Redo = G("M15,5 L20,10 L15,15 M20,10 L9,10 C6,10 4,12 4,15 C4,18 6,20 9,20 L13,20");
    public static readonly Geometry PauseFill = G("M7,5 L10,5 L10,19 L7,19 Z M14,5 L17,5 L17,19 L14,19 Z");
    public static readonly Geometry PlayFill = G("M7,4.5 L19,12 L7,19.5 Z");
    public static readonly Geometry Pointer = G("M6,3 L6,19 L10,15 L13,21 L15.5,20 L12.5,14 L18,14 Z");
    public static readonly Geometry Trash = G("M4,6 L20,6 M9,6 L9,4 L15,4 L15,6 M6,6 L7,20 Q7,21 8,21 L16,21 Q17,21 17,20 L18,6 M10,10 L10,17 M14,10 L14,17");
    public static readonly Geometry History = G("M3.5,12 A8.5,8.5 0 1 0 6,6 M3,4 L3,9 L8,9 M12,7.5 L12,12 L15,14");
    public static readonly Geometry Gear = G("M12,8.5 A3.5,3.5 0 1 1 11.99,8.5 Z M12,2.5 L13.5,2.5 L14,5 L16,6 L18.3,4.8 L19.4,5.9 L18.2,8.2 L19,10.2 L21.5,10.6 L21.5,13.4 L19,13.8 L18.2,15.8 L19.4,18.1 L18.3,19.2 L16,18 L14,19 L13.5,21.5 L10.5,21.5 L10,19 L8,18 L5.7,19.2 L4.6,18.1 L5.8,15.8 L5,13.8 L2.5,13.4 L2.5,10.6 L5,10.2 L5.8,8.2 L4.6,5.9 L5.7,4.8 L8,6 L10,5 L10.5,2.5 Z");
    public static readonly Geometry EllipsisCircle = G("M12,3 A9,9 0 1 1 11.99,3 Z M7.5,12 L7.6,12 M12,12 L12.1,12 M16.5,12 L16.6,12");
    public static readonly Geometry Sidebar = G("M4,5 L20,5 Q21,5 21,6 L21,18 Q21,19 20,19 L4,19 Q3,19 3,18 L3,6 Q3,5 4,5 Z M9,5 L9,19 M5,8 L7,8 M5,10.5 L7,10.5");
    public static readonly Geometry Expand = G("M14,4 L20,4 L20,10 M20,4 L13,11 M10,20 L4,20 L4,14 M4,20 L11,13");
    public static readonly Geometry Collapse = G("M13,11 L13,5 M13,11 L19,11 M13,11 L20,4 M11,13 L11,19 M11,13 L5,13 M11,13 L4,20");
    public static readonly Geometry ChevronLeft = G("M15,5 L8,12 L15,19");
    public static readonly Geometry ChevronRight = G("M9,5 L16,12 L9,19");
    public static readonly Geometry ChevronDown = G("M6,9 L12,15 L18,9");
    public static readonly Geometry ChevronUpDown = G("M8,9 L12,5 L16,9 M8,15 L12,19 L16,15");
    public static readonly Geometry NumberCircle = G("M12,3 A9,9 0 1 1 11.99,3 Z M10,8 L9,16 M15,8 L14,16 M7.5,10.5 L16.5,10.5 M7,13.5 L16,13.5");
    public static readonly Geometry Clock = G("M12,3 A9,9 0 1 1 11.99,3 Z M12,7 L12,12 L15.5,14");
    public static readonly Geometry TextAlignLeft = G("M4,6 L20,6 M4,10 L14,10 M4,14 L20,14 M4,18 L14,18");
    public static readonly Geometry Edit = G("M4,20 L4,16 L15,5 L19,9 L8,20 Z M13,7 L17,11 M14,20 L20,20");
    public static readonly Geometry SquarePencil = G("M11,4 L6,4 Q4,4 4,6 L4,18 Q4,20 6,20 L18,20 Q20,20 20,18 L20,13 M9,15 L10,11 L18,3 L21,6 L13,14 Z");
    public static readonly Geometry PlayCircle = G("M12,3 A9,9 0 1 1 11.99,3 Z M10,8.5 L15.5,12 L10,15.5 Z");
    public static readonly Geometry StopCircle = G("M12,3 A9,9 0 1 1 11.99,3 Z M9.5,9.5 L14.5,9.5 L14.5,14.5 L9.5,14.5 Z");
    public static readonly Geometry Refresh = G("M19.5,12 A7.5,7.5 0 1 1 17,6.4 M18,3 L18,7 L14,7");
    public static readonly Geometry Folder = G("M3,7 Q3,5 5,5 L9.5,5 L11.5,7 L19,7 Q21,7 21,9 L21,17 Q21,19 19,19 L5,19 Q3,19 3,17 Z");
    public static readonly Geometry Search = G("M10.5,4 A6.5,6.5 0 1 1 10.49,4 Z M15.2,15.2 L20,20");
    public static readonly Geometry Waveform = G("M4,10 L4,14 M7,7 L7,17 M10,4 L10,20 M13,8 L13,16 M16,5 L16,19 M19,9 L19,15");
    public static readonly Geometry Chip = G("M7,6 L17,6 Q18,6 18,7 L18,17 Q18,18 17,18 L7,18 Q6,18 6,17 L6,7 Q6,6 7,6 Z M9.5,9.5 L14.5,9.5 L14.5,14.5 L9.5,14.5 Z M9,3 L9,6 M12,3 L12,6 M15,3 L15,6 M9,18 L9,21 M12,18 L12,21 M15,18 L15,21 M3,9 L6,9 M3,12 L6,12 M3,15 L6,15 M18,9 L21,9 M18,12 L21,12 M18,15 L21,15");
    public static readonly Geometry Keyboard = G("M3,7 Q3,6 4,6 L20,6 Q21,6 21,7 L21,17 Q21,18 20,18 L4,18 Q3,18 3,17 Z M6,9.5 L6.1,9.5 M9,9.5 L9.1,9.5 M12,9.5 L12.1,9.5 M15,9.5 L15.1,9.5 M18,9.5 L18.1,9.5 M6,12.5 L6.1,12.5 M9,12.5 L9.1,12.5 M12,12.5 L12.1,12.5 M15,12.5 L15.1,12.5 M18,12.5 L18.1,12.5 M8,15.5 L16,15.5");
    public static readonly Geometry Hand = G("M8,13 L8,5.5 Q8,4 9.5,4 Q11,4 11,5.5 L11,11 M11,5 Q11,3 12.5,3 Q14,3 14,5 L14,11 M14,6 Q14,4.5 15.5,4.5 Q17,4.5 17,6 L17,12 M17,8.5 Q17,7 18.5,7 Q20,7 20,8.5 L20,15 Q20,21 14,21 L13,21 Q9,21 7,17 L4.5,12.5 Q4,11 5.3,10.5 Q6.5,10 7.5,11.5 L8,13");
    public static readonly Geometry Cloud = G("M7,18 L17.5,18 A4,4 0 0 0 17.5,10 A5.5,5.5 0 0 0 6.8,10.5 A3.8,3.8 0 0 0 7,18 Z");
    public static readonly Geometry Layers = G("M12,4 L21,8.5 L12,13 L3,8.5 Z M3,12.5 L12,17 L21,12.5 M3,16 L12,20.5 L21,16");
    public static readonly Geometry PlusCircle = G("M12,3 A9,9 0 1 1 11.99,3 Z M12,8 L12,16 M8,12 L16,12");
    public static readonly Geometry Checkmark = G("M4,12.5 L9.5,18 L20,6");
    public static readonly Geometry Photo = G("M4,5 L20,5 Q21,5 21,6 L21,18 Q21,19 20,19 L4,19 Q3,19 3,18 L3,6 Q3,5 4,5 Z M3,16 L8,11 L13,16 L16,13 L21,18 M15.5,8.5 L15.6,8.5");
    public static readonly Geometry Triangle = G("M12,3.5 L22,20.5 L2,20.5 Z");
    public static readonly Geometry Close = G("M6,6 L18,18 M18,6 L6,18");
    public static readonly Geometry Minimize = G("M5,12 L19,12");
    public static readonly Geometry Maximize = G("M5,5 L19,5 L19,19 L5,19 Z");
    public static readonly Geometry Copy = G("M8,8 L8,4 Q8,3 9,3 L19,3 Q20,3 20,4 L20,14 Q20,15 19,15 L16,15 M5,8 L15,8 Q16,8 16,9 L16,20 Q16,21 15,21 L5,21 Q4,21 4,20 L4,9 Q4,8 5,8 Z");
    public static readonly Geometry ArrowCounterclockwise = G("M4.5,12 A7.5,7.5 0 1 0 7,6.4 M6,3 L6,7 L10,7");
    public static readonly Geometry SplitVertical = G("M4,4 L20,4 L20,10.5 L4,10.5 Z M4,13.5 L20,13.5 L20,20 L4,20 Z");
    public static readonly Geometry PhotoStack = G("M7,7 L19,7 Q20,7 20,8 L20,18 Q20,19 19,19 L7,19 Q6,19 6,18 L6,8 Q6,7 7,7 Z M4,16 L4,5 Q4,4 5,4 L16,4");
}

/// A window drawn the macOS way: no system title bar (the content — a sidebar, a toolbar — runs to the top edge),
/// the system's minimise / maximise / close at the top right, rounded corners on Windows 11.
public class MacWindow : Window
{
    readonly Grid root = new();
    readonly Border holder = new();
    readonly StackPanel caption = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
    public double CaptionHeight { get; }
    public UIElement Body { set => holder.Child = value; }

    public MacWindow(double captionHeight = 52)
    {
        CaptionHeight = captionHeight;
        Background = Mac.Window;
        FontFamily = Mac.Font;
        FontSize = Mac.Body;
        Foreground = Mac.Label;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        try { Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/icon.png")); } catch { }
        System.Windows.Shell.WindowChrome.SetWindowChrome(this, new System.Windows.Shell.WindowChrome
        {
            CaptionHeight = captionHeight, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0, 0, 0, 1),
            CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        caption.Children.Add(CaptionButton(Icons.Minimize, "最小化", () => WindowState = WindowState.Minimized, false));
        caption.Children.Add(CaptionButton(Icons.Maximize, "最大化", () => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized, false));
        caption.Children.Add(CaptionButton(Icons.Close, "关闭", Close, true));
        root.Children.Add(holder);
        root.Children.Add(caption);
        Content = root;
        StateChanged += (_, _) => root.Margin = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);
        SourceInitialized += (_, _) =>
        {
            var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            var round = 2; Interop.Native.DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, 4);
        };
    }

    Button CaptionButton(Geometry g, string tip, Action run, bool close)
    {
        var b = new Button
        {
            Content = Mac.Symbol(g, 10, Mac.Label, 1),
            Width = 46, Height = 32, Focusable = false, ToolTip = tip,
            Template = Mac.Template(Brushes.Transparent, close ? Mac.B(0xFF, 0xE8, 0x11, 0x23) : Mac.Hover, 0),
        };
        System.Windows.Shell.WindowChrome.SetIsHitTestVisibleInChrome(b, true);
        System.Windows.Automation.AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => run();
        return b;
    }

    /// Marks an element in the caption strip as clickable (toolbar buttons, the search field).
    public static T Interactive<T>(T e) where T : IInputElement
    {
        System.Windows.Shell.WindowChrome.SetIsHitTestVisibleInChrome(e, true);
        return e;
    }

    /// The width the caption buttons take at the top right (toolbars keep clear of it).
    public const double CaptionButtonsWidth = 46 * 3;
}
