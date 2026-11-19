// An alert the way macOS 26 draws one (NSAlert): the app icon, the message in bold, the detail under it, and the
// buttons in a row, the first one the default (the accent; red words when it destroys something). Esc picks the last.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PointTaken.App;

public static class MacAlert
{
    /// Returns the index of the button chosen (Esc / closing: the last one).
    public static int Show(Window? owner, string message, string detail, string[] buttons, bool destructive = false)
    {
        var w = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, ResizeMode = ResizeMode.NoResize,
            SizeToContent = SizeToContent.WidthAndHeight, ShowInTaskbar = owner == null, Topmost = owner == null, FontFamily = Mac.Font,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen, Owner = owner,
            Title = message,
        };
        var chosen = buttons.Length - 1;
        var stack = new StackPanel { Width = 300, Margin = new Thickness(20) };
        try
        {
            stack.Children.Add(new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/icon.png")), Width = 56, Height = 56, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 12) });
        }
        catch { }
        var title = Mac.Text(message, Mac.Headline, FontWeights.Bold, wrap: true);
        title.Margin = new Thickness(0, 0, 0, 6);
        stack.Children.Add(title);
        if (detail.Length > 0) stack.Children.Add(Mac.Text(detail, Mac.Callout, color: Mac.Label, wrap: true));
        var row = new UniformGrid { Rows = 1, Margin = new Thickness(0, 18, 0, 0) };
        for (var i = 0; i < buttons.Length; i++)
        {
            var index = i;
            var primary = i == 0;
            Button b;
            if (primary && !destructive) b = Mac.Primary(buttons[i], () => { chosen = index; w.Close(); }, height: 30, size: Mac.Callout);
            else
            {
                b = Mac.Push(buttons[i], () => { chosen = index; w.Close(); }, height: 30, size: Mac.Callout);
                if (primary && destructive) ((TextBlock)b.Content).Foreground = Mac.B(0xFF, 0xD7, 0x30, 0x2A);
            }
            b.Margin = new Thickness(i == 0 ? 0 : 4, 0, i == buttons.Length - 1 ? 0 : 4, 0);
            b.HorizontalAlignment = HorizontalAlignment.Stretch;
            row.Children.Add(b);
        }
        stack.Children.Add(row);
        w.Content = new Border
        {
            Child = stack, Background = Mac.B(0xFA, 0xF6, 0xF6, 0xF7), CornerRadius = new CornerRadius(18), BorderBrush = Mac.B(0x26, 0, 0, 0), BorderThickness = new Thickness(0.5),
            Margin = new Thickness(24), Effect = Mac.Shadow(30, 8, 0.25),
        };
        w.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { chosen = buttons.Length - 1; w.Close(); }
            else if (e.Key == Key.Return) { chosen = 0; w.Close(); }
        };
        w.MouseLeftButtonDown += (_, e) => { try { w.DragMove(); } catch { } };
        w.ShowDialog();
        return chosen;
    }
}

public sealed class UniformGrid : System.Windows.Controls.Primitives.UniformGrid { }
