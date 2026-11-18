// The check window (检查内容) — BoardReviewWindow (BoardReview.swift), laid out the same way:
//   sidebar (292): 页面 · N 页, one row per page (72×45 thumbnail, 第 N 页, times · marks, N 个未说明, the AI check),
//                  a trash button at its foot
//   toolbar:       第 N 页 / 0:00 – 2:42 · 标记 1、2 · 11月16日 21:16   [🗑 ⟲ ⚙ ⋯] [保存并关闭] [复制并关闭]
//   picture:       on the under-page grey, a rounded card; undo/redo and the tools as two glass columns at its left,
//                  the full-size button at its bottom right
//   lower pane:    标记 / 按时间 / 全文 in a column at the left, the status under them; mark cards, the transcript by
//                  time (play or edit a sentence), or the whole transcript
// One undo history (Ctrl+Z / Ctrl+Shift+Z) covers marks, notes, checks, order and deletions. Closing saves.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using PointTaken.App.Capture;
using PointTaken.Core;

namespace PointTaken.App.Review;

public sealed class ReviewWindow : MacWindow
{
    const double SidebarWidth = 292, ModeColumn = 104, SideToolsWidth = 44;
    readonly BoardRecord record;
    List<BoardPage> pages;
    BoardEvidence? evidence;
    List<BoardSpeechBlock> blocks = new();
    int? selected;
    bool finalizing, closing, editedTranscript, settingWords, focusMode;
    string originalTranscript;
    string? lastExportFolder;
    readonly Dictionary<string, string> rendered = new(StringComparer.OrdinalIgnoreCase);
    sealed record Snapshot(List<BoardPage> Pages, int? Selected, string Name);
    readonly Stack<Snapshot> undo = new(), redo = new();
    enum Mode { Marks, Timeline, Words }
    Mode mode = Mode.Words;
    bool modeChosen;

    // layout
    readonly ColumnDefinition sidebarColumn = new() { Width = new GridLength(SidebarWidth) };
    readonly Border sidebar = new() { Background = Mac.Sidebar };
    readonly StackPanel pageList = new();
    readonly ScrollViewer pageScroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = true, FocusVisualStyle = null };
    readonly TextBlock countLabel = Mac.Text("", Mac.Subheadline, color: Mac.Tertiary, digits: true);
    readonly TextBlock emptyPages = Mac.Text("没有截图", Mac.Callout, color: Mac.Tertiary);
    Button listTrash = null!;
    readonly TextBlock titleText = Mac.Text("检查内容", Mac.Title3, FontWeights.SemiBold);
    readonly TextBlock subtitleText = Mac.Text("", Mac.Subheadline, color: Mac.Secondary, digits: true);
    Button deleteItem = null!;
    Button primary = null!;
    readonly List<UIElement> deliveryControls = new();
    readonly Grid pictureHost = new() { Background = Mac.UnderPage, ClipToBounds = true };
    readonly ScrollViewer imageScroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    readonly Canvas canvas = new();
    readonly ScaleTransform zoom = new(1, 1);
    readonly Border pictureCard = new() { CornerRadius = new CornerRadius(Mac.PictureRadius), Background = Brushes.White, Effect = Mac.Shadow(12, 3, 0.16) };
    readonly Border pictureClip = new() { CornerRadius = new CornerRadius(Mac.PictureRadius), BorderBrush = Mac.Separator, BorderThickness = new Thickness(1) };
    readonly Image picture = new() { Stretch = Stretch.Fill };
    readonly MarkCanvas markCanvas = new();
    readonly StackPanel emptyState = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly TextBlock emptyTitle = Mac.Text("这次没有截图", Mac.Title3, FontWeights.SemiBold, Mac.Secondary);
    readonly TextBlock emptyDetail = Mac.Text("录音和文字已经保存", Mac.Callout, color: Mac.Tertiary, wrap: true);
    SideTools sideTools = null!, sideUndo = null!;
    Button focusButton = null!;
    readonly Border pageSwitcher = new() { Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 16) };
    readonly TextBlock switcherLabel = Mac.Text("", Mac.Body, FontWeights.SemiBold, digits: true);
    Button switcherPrev = null!, switcherNext = null!;
    readonly Border pageStrip = new() { Width = 132, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(-160, 12, 0, 12), Visibility = Visibility.Collapsed };
    readonly StackPanel stripList = new();
    readonly Border edgeSensor = new() { Width = 10, HorizontalAlignment = HorizontalAlignment.Left, Background = Brushes.Transparent, Visibility = Visibility.Collapsed };
    readonly Popup notePopup = new() { AllowsTransparency = true, StaysOpen = false, Placement = PlacementMode.Right, PopupAnimation = PopupAnimation.Fade };
    readonly TextBox noteBox = new();
    readonly TextBlock noteQuote = Mac.Text("", Mac.Subheadline, color: Mac.Secondary, wrap: true);
    readonly Grid noteBadge = new() { Width = 20, Height = 20 };
    TextBlock noteBadgeText = null!;
    int noteNumber;
    readonly RowDefinition lowerRow = new() { Height = new GridLength(300), MinHeight = 120 };
    readonly RowDefinition splitterRow = new() { Height = new GridLength(9) };
    readonly Grid lowerPane = new() { Background = Mac.Window };
    readonly GridSplitter splitter = new() { Height = 9, HorizontalAlignment = HorizontalAlignment.Stretch, ResizeDirection = GridResizeDirection.Rows, ResizeBehavior = GridResizeBehavior.PreviousAndNext, ShowsPreview = false, Cursor = Cursors.SizeNS };
    readonly List<(Mode mode, Button button, Path icon, TextBlock text, Border fill)> modeButtons = new();
    readonly TextBlock note = Mac.Text("", Mac.Callout, color: Mac.Secondary, wrap: true);
    Button fixButton = null!;
    readonly StackPanel markList = new() { Margin = new Thickness(0, 4, 0, 8) };
    readonly ScrollViewer markScroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    readonly StackPanel marksEmpty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 0, 8) };
    readonly TextBlock marksEmptyTitle = Mac.Text("", Mac.Title3, FontWeights.SemiBold, Mac.Secondary);
    readonly TextBlock marksEmptyDetail = Mac.Text("", Mac.Callout, color: Mac.Tertiary, wrap: true);
    readonly Grid marksPane = new();
    readonly Grid speechPane = new();
    readonly Canvas strip = new() { Height = 40, Background = Brushes.Transparent, ClipToBounds = false };
    readonly StackPanel speechList = new();
    readonly ScrollViewer speechScroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    readonly TextBox words = new();
    MediaPlayer? player;
    BoardSpeechSegment? playing;
    System.Windows.Threading.DispatcherTimer? playStop;
    BitmapSource? shownImage;
    (string title, string detail)? shownTitle;
    GridLength savedLower = new(300);
    System.Windows.Threading.DispatcherTimer? stripHide;
    bool stripShown;

    public ReviewWindow(BoardRecord record, bool finalizing, string? warning) : base(52)
    {
        this.record = record;
        pages = record.Pages.Select(p => p.Clone()).ToList();
        evidence = record.Evidence;
        originalTranscript = record.OriginalTranscript;
        editedTranscript = record.ReviewedTranscript != null;
        foreach (var p in pages)
            if (p.Images.Count > 0 && !p.ImageNeedsRepair && File.Exists(p.Images[0])) rendered[p.Images[0]] = Signature(p);
        Title = "检查内容";
        Width = 1180; Height = 800; MinWidth = 980; MinHeight = 640;
        Body = Build(record.DeliveryTranscript);
        RebuildTimeline();
        mode = blocks.Count == 0 ? Mode.Words : Mode.Timeline;
        if (pages.Any(p => p.Marks.Count > 0)) mode = Mode.Marks;
        ModeChanged();
        ShowPage(pages.Count > 0 ? 0 : null);
        ReloadList();
        SetFinalizing(finalizing);
        if (warning != null) { note.Text = warning; note.Foreground = Mac.Orange; }
        UpdateUndoButtons();
        PreviewKeyDown += OnKey;
        Closing += (_, e) =>
        {
            if (closing) return;
            if (!Publish() && MacAlert.Show(this, "有标注图片没能更新", note.Text + "。标记和说明已经保存在记录里，图片会在下次修改这一页时重画。", new[] { "仍然关闭", "取消" }) != 0) e.Cancel = true;
        };
        Closed += (_, _) => { player?.Close(); playStop?.Stop(); RemoveUnused(); };
        Loaded += (_, _) => LayoutPicture();
    }

    public void ShowAndActivate()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    // ── building ──

    UIElement Build(string transcript)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(sidebarColumn);
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        sidebar.Child = BuildSidebar();
        grid.Children.Add(sidebar);
        var detail = BuildDetail(transcript);
        Grid.SetColumn(detail, 1);
        grid.Children.Add(detail);
        return grid;
    }

    UIElement BuildSidebar()
    {
        var dock = new DockPanel();
        // the sidebar's own button, where macOS puts it after the window buttons
        var toggle = Interactive(Mac.Icon(Icons.Sidebar, "隐藏侧边栏", ToggleSidebar, 36, 18, Mac.Secondary, 18));
        toggle.HorizontalAlignment = HorizontalAlignment.Left;
        toggle.Margin = new Thickness(16, 8, 0, 8);
        DockPanel.SetDock(toggle, Dock.Top);
        dock.Children.Add(toggle);
        var header = new DockPanel { Margin = new Thickness(Mac.Margin, Mac.GroupGap, Mac.Margin, Mac.Tight) };
        DockPanel.SetDock(countLabel, Dock.Right);
        header.Children.Add(countLabel);
        header.Children.Add(Mac.Text("页面", Mac.Subheadline, FontWeights.SemiBold, Mac.Secondary));
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        var foot = new Grid { Height = 40 };
        foot.Children.Add(new Border { Height = 1, Background = Mac.Separator, VerticalAlignment = VerticalAlignment.Top });
        listTrash = Mac.Icon(Icons.Trash, "删除这一页（Ctrl+Delete）", AskRemove, 32, 17);
        listTrash.HorizontalAlignment = HorizontalAlignment.Left; listTrash.Margin = new Thickness(Mac.Inner, 0, 0, 0);
        foot.Children.Add(listTrash);
        DockPanel.SetDock(foot, Dock.Bottom);
        dock.Children.Add(foot);
        pageScroll.Content = pageList;
        var listHost = new Grid();
        listHost.Children.Add(pageScroll);
        emptyPages.HorizontalAlignment = HorizontalAlignment.Center; emptyPages.VerticalAlignment = VerticalAlignment.Center;
        listHost.Children.Add(emptyPages);
        dock.Children.Add(listHost);
        var menu = TrayMenu.Create();
        menu.Items.Add(TrayMenu.Item("删除这一页…", AskRemove));
        menu.Items.Add(TrayMenu.Item("上移", () => Move(-1), "Alt+↑"));
        menu.Items.Add(TrayMenu.Item("下移", () => Move(1), "Alt+↓"));
        pageScroll.ContextMenu = menu;
        return dock;
    }

    UIElement BuildDetail(string transcript)
    {
        var detail = new Grid();
        detail.RowDefinitions.Add(new RowDefinition { Height = new GridLength(CaptionHeight) });
        detail.RowDefinitions.Add(new RowDefinition { MinHeight = 260 });
        detail.RowDefinitions.Add(splitterRow);
        detail.RowDefinitions.Add(lowerRow);

        // ── the toolbar
        var bar = new DockPanel { Margin = new Thickness(Mac.Margin, 0, MacWindow.CaptionButtonsWidth + 8, 0), LastChildFill = false };
        deleteItem = Mac.Icon(Icons.Trash, "删除选中的标记（Delete，可以 Ctrl+Z 撤销）", DeleteSelectedMark, 36, 18, Mac.Label, 18);
        deleteItem.IsEnabled = false;
        var history = Mac.Icon(Icons.History, "历史记录", History.HistoryWindow.ShowWindow, 36, 18, Mac.Label, 18);
        var settings = Mac.Icon(Icons.Gear, "设置", () => Settings.SettingsWindow.ShowWindow(), 36, 18, Mac.Label, 18);
        var more = Mac.Icon(Icons.EllipsisCircle, "更多操作", () => { }, 36, 18, Mac.Label, 18);
        more.Click += (_, _) => ShowMore(more);
        var group = Mac.ToolbarGroup(Interactive(deleteItem), Interactive(history), Interactive(settings), Interactive(more));
        var save = Interactive(Mac.Push("保存并关闭", Close, "保存修改，不复制，关闭窗口", 40));
        primary = Interactive(Mac.Primary("复制并关闭", CopyAndClose, "复制完整说明和图片路径（直接粘贴给 AI），然后关闭窗口", 40));
        deliveryControls.Add(primary);
        save.Margin = new Thickness(10, 0, 8, 0);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(group); right.Children.Add(save); right.Children.Add(primary);
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Add(right);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(titleText);
        titles.Children.Add(subtitleText);
        bar.Children.Add(titles);
        detail.Children.Add(bar);

        // ── the picture
        canvas.LayoutTransform = zoom;
        canvas.Children.Add(pictureCard);
        pictureClip.Child = picture;
        canvas.Children.Add(pictureClip);
        canvas.Children.Add(markCanvas);
        imageScroll.Content = canvas;
        imageScroll.PreviewMouseWheel += (_, e) =>
        {
            if (Keyboard.Modifiers != ModifierKeys.Control) return;
            Zoom(e.Delta > 0 ? 1.25 : 0.8);
            e.Handled = true;
        };
        pictureHost.Children.Add(imageScroll);
        emptyState.Children.Add(new Border { Child = Mac.Symbol(Icons.PhotoStack, 40, Mac.Tertiary, 1.4), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, Mac.GroupGap) });
        emptyTitle.HorizontalAlignment = HorizontalAlignment.Center;
        emptyDetail.HorizontalAlignment = HorizontalAlignment.Center; emptyDetail.TextAlignment = TextAlignment.Center; emptyDetail.MaxWidth = 360; emptyDetail.Margin = new Thickness(0, Mac.Tight, 0, 0);
        emptyState.Children.Add(emptyTitle);
        emptyState.Children.Add(emptyDetail);
        pictureHost.Children.Add(emptyState);

        sideUndo = new SideTools(new[] { (Icons.Undo, "撤销（Ctrl+Z）"), (Icons.Redo, "重做（Ctrl+Shift+Z）") }, selects: false);
        sideUndo.HorizontalAlignment = HorizontalAlignment.Left; sideUndo.VerticalAlignment = VerticalAlignment.Top; sideUndo.Margin = new Thickness(16, 16, 0, 0);
        sideUndo.OnPick = i => { if (i == 1) Redo(); else Undo(); };
        sideTools = new SideTools(new[] { (Icons.Pointer, "选择：点标记选中，Delete 删除；拖动空白处移动图片（Esc）"), (Icons.Scribble, "自由画"), (Icons.Rectangle, "矩形"), (Icons.Circle, "圆圈") }, selects: true);
        sideTools.HorizontalAlignment = HorizontalAlignment.Left; sideTools.VerticalAlignment = VerticalAlignment.Bottom; sideTools.Margin = new Thickness(16, 0, 0, 16);
        sideTools.OnPick = SetTool;
        pictureHost.Children.Add(sideUndo);
        pictureHost.Children.Add(sideTools);
        focusButton = GlassRound(Icons.Expand, "放大图片来标注：画完旁边直接写说明，‹ › 切换页面（双击图片空白处也可以）", ToggleFocus);
        focusButton.HorizontalAlignment = HorizontalAlignment.Right; focusButton.VerticalAlignment = VerticalAlignment.Bottom; focusButton.Margin = new Thickness(0, 0, 16, 16);
        pictureHost.Children.Add(focusButton);
        switcherPrev = Mac.Icon(Icons.ChevronLeft, "上一页（←）", () => Step(-1), 40, 15, Mac.Label, 18);
        switcherNext = Mac.Icon(Icons.ChevronRight, "下一页（→）", () => Step(1), 40, 15, Mac.Label, 18);
        switcherPrev.Height = switcherNext.Height = 36;
        switcherLabel.MinWidth = 64; switcherLabel.TextAlignment = TextAlignment.Center; switcherLabel.VerticalAlignment = VerticalAlignment.Center;
        var switchRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6, 2, 6, 2) };
        switchRow.Children.Add(switcherPrev); switchRow.Children.Add(switcherLabel); switchRow.Children.Add(switcherNext);
        pageSwitcher.Child = switchRow;
        Glass(pageSwitcher, 20);
        pictureHost.Children.Add(pageSwitcher);
        stripList.Margin = new Thickness(8);
        pageStrip.Child = new ScrollViewer { Content = stripList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Glass(pageStrip, 16);
        pageStrip.MouseEnter += (_, _) => stripHide?.Stop();
        pageStrip.MouseLeave += (_, _) => ConcealStrip(0.3);
        edgeSensor.MouseEnter += (_, _) => RevealStrip();
        pictureHost.Children.Add(edgeSensor);
        pictureHost.Children.Add(pageStrip);
        Grid.SetRow(pictureHost, 1);
        detail.Children.Add(pictureHost);
        imageScroll.SizeChanged += (_, _) => LayoutPicture();

        markCanvas.OnDraw = AddMark;
        markCanvas.OnDelete = DeleteMark;
        markCanvas.OnSelect = MarkSelected;
        markCanvas.OnEscape = () => { if (markCanvas.Tool != null) SetTool(0); else if (focusMode) SetFocus(false); };
        markCanvas.OnArrow = Step;
        markCanvas.OnEmptyDoubleClick = () => SetFocus(!focusMode);
        markCanvas.OnPan = d => { imageScroll.ScrollToHorizontalOffset(imageScroll.HorizontalOffset + d.X); imageScroll.ScrollToVerticalOffset(imageScroll.VerticalOffset + d.Y); };
        BuildNotePopup();

        // ── the divider: a thin line with a grab handle
        var splitHost = new Grid { Background = Mac.Window };
        splitHost.Children.Add(new Border { Height = 1, Background = Mac.Separator, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false });
        splitHost.Children.Add(new Border { Width = 36, Height = 4, CornerRadius = new CornerRadius(2), Background = Mac.B(0x33, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false });
        splitter.Background = Brushes.Transparent;
        splitHost.Children.Insert(0, splitter);
        splitter.MouseDoubleClick += (_, _) => lowerRow.Height = new GridLength(300);
        Grid.SetRow(splitHost, 2);
        detail.Children.Add(splitHost);

        // ── what was said
        lowerPane.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Mac.GroupGap) });
        lowerPane.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ModeColumn) });
        lowerPane.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Mac.GroupGap) });
        lowerPane.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        lowerPane.ColumnDefinitions.Add(new ColumnDefinition());
        var column = new DockPanel();
        var choices = new StackPanel { Margin = new Thickness(4) };
        foreach (var (m, title, symbol, tip) in new[] { (Mode.Marks, "标记", Icons.NumberCircle, "这一页的每个标记和它的说明"), (Mode.Timeline, "按时间", Icons.Clock, "按时间看每一页说了什么"), (Mode.Words, "全文", Icons.TextAlignLeft, "完整转写，可以修改") })
        {
            var icon = (Path)Mac.Symbol(symbol, 15, Mac.Secondary, 1.5);
            icon.Margin = new Thickness(0, 0, 6, 0);
            var text = Mac.Text(title, Mac.Body, color: Mac.Secondary);
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(Mac.Inner, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(icon); row.Children.Add(text);
            var fill = new Border { CornerRadius = new CornerRadius(10), Child = row, Height = 34 };
            var b = new Button { Content = fill, Focusable = false, ToolTip = tip, HorizontalContentAlignment = HorizontalAlignment.Stretch, Template = Mac.Template(Brushes.Transparent, null, 10), Margin = new Thickness(0, 0, 0, 2) };
            var mm = m;
            b.Click += (_, _) => { modeChosen = true; mode = mm; ModeChanged(); };
            modeButtons.Add((m, b, icon, text, fill));
            choices.Children.Add(b);
        }
        var choicesBox = new Border { Child = choices, Margin = new Thickness(0, Mac.Inner + Mac.Tight, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        Glass(choicesBox, 14);
        choicesBox.Effect = null;
        DockPanel.SetDock(choicesBox, Dock.Top);
        column.Children.Add(choicesBox);
        var status = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(Mac.Inner, Mac.Inner, 0, Mac.GroupGap) };
        note.MaxWidth = ModeColumn - Mac.Inner;
        note.MaxHeight = 4 * 18;
        note.TextTrimming = TextTrimming.CharacterEllipsis;
        status.Children.Add(note);
        fixButton = Mac.Push("去补", GoToUnexplained, "跳到还没有说明的标记", 24, Mac.Subheadline);
        fixButton.HorizontalAlignment = HorizontalAlignment.Left; fixButton.Margin = new Thickness(0, Mac.Tight, 0, 0); fixButton.Visibility = Visibility.Collapsed;
        status.Children.Add(fixButton);
        column.Children.Add(status);
        Grid.SetColumn(column, 1);
        lowerPane.Children.Add(column);
        var rule = new Border { Width = 1, Background = Mac.Separator, Margin = new Thickness(0, Mac.Inner, 0, Mac.Inner) };
        Grid.SetColumn(rule, 3);
        lowerPane.Children.Add(rule);

        markScroll.Content = markList;
        markScroll.Margin = new Thickness(Mac.GroupGap, 0, Mac.Margin, 0);
        marksEmpty.Children.Add(new Border { Child = Mac.Symbol(Icons.Scribble, 34, Mac.Tertiary, 1.3), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, Mac.GroupGap) });
        marksEmptyTitle.HorizontalAlignment = HorizontalAlignment.Center;
        marksEmptyDetail.HorizontalAlignment = HorizontalAlignment.Center; marksEmptyDetail.TextAlignment = TextAlignment.Center; marksEmptyDetail.Margin = new Thickness(0, Mac.Tight, 0, 0);
        marksEmpty.Children.Add(marksEmptyTitle); marksEmpty.Children.Add(marksEmptyDetail);
        marksPane.Children.Add(markScroll);
        marksPane.Children.Add(marksEmpty);
        Grid.SetColumn(marksPane, 4);
        lowerPane.Children.Add(marksPane);

        var speechDock = new DockPanel();
        strip.Margin = new Thickness(Mac.Margin, Mac.GroupGap, Mac.Margin, Mac.Tight);
        strip.SizeChanged += (_, _) => DrawStrip();
        strip.MouseLeftButtonDown += StripClicked;
        DockPanel.SetDock(strip, Dock.Top);
        speechDock.Children.Add(strip);
        speechScroll.Content = speechList;
        speechDock.Children.Add(speechScroll);
        speechPane.Children.Add(speechDock);
        Grid.SetColumn(speechPane, 4);
        lowerPane.Children.Add(speechPane);

        words.Text = transcript;
        words.FontSize = 15;
        words.FontFamily = Mac.Font;
        words.Foreground = Mac.Label;
        words.Background = Brushes.Transparent;
        words.BorderThickness = new Thickness(0);
        words.TextWrapping = TextWrapping.Wrap;
        words.AcceptsReturn = true;
        words.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        words.Padding = new Thickness(Mac.Margin - 5, Mac.GroupGap, Mac.Margin - 5, Mac.GroupGap);
        TextBlock.SetLineHeight(words, 24);
        words.SelectionBrush = Mac.Accent;
        words.TextChanged += (_, _) => { if (!settingWords && !finalizing) editedTranscript = true; };
        Grid.SetColumn(words, 4);
        lowerPane.Children.Add(words);
        Grid.SetRow(lowerPane, 3);
        detail.Children.Add(lowerPane);
        return detail;
    }

    /// The glass look macOS 26 gives floating controls: near-white, a hairline edge, a soft shadow.
    static void Glass(Border b, double radius)
    {
        b.Background = Mac.B(0xEB, 0xFC, 0xFC, 0xFC);
        b.BorderBrush = Mac.B(0x14, 0, 0, 0);
        b.BorderThickness = new Thickness(1);
        b.CornerRadius = new CornerRadius(radius);
        b.Effect = Mac.Shadow(12, 2, 0.12);
    }

    static Button GlassRound(Geometry symbol, string tip, Action run)
    {
        var b = new Button
        {
            Content = Mac.Symbol(symbol, 18, Mac.Label, 1.6), Width = 44, Height = 44, ToolTip = tip, Focusable = false,
            Template = Mac.Template(Mac.B(0xEB, 0xFC, 0xFC, 0xFC), Mac.B(0xFF, 0xF0, 0xF0, 0xF0), 22, Mac.B(0x14, 0, 0, 0), 1),
            Effect = Mac.Shadow(12, 2, 0.12),
        };
        System.Windows.Automation.AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => run();
        return b;
    }

    void BuildNotePopup()
    {
        noteBadge.Children.Add(new Ellipse { Fill = Mac.Black(0.88), Stroke = Brushes.White, StrokeThickness = 1.5 });
        noteBadgeText = new TextBlock { Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontFamily = Mac.Digits };
        noteBadge.Children.Add(noteBadgeText);
        var trash = Mac.Icon(Icons.Trash, "删除这个标记（可以 Ctrl+Z 撤销）", () => { notePopup.IsOpen = false; DeleteMark(noteNumber); }, 28, 15);
        var head = new DockPanel();
        DockPanel.SetDock(trash, Dock.Right);
        head.Children.Add(trash);
        noteBadge.Margin = new Thickness(0, 0, Mac.Inner, 0);
        head.Children.Add(Ui2.Row(noteBadge, Mac.Text("说明", Mac.Headline, FontWeights.SemiBold)));
        noteBox.FontSize = Mac.Body; noteBox.FontFamily = Mac.Font; noteBox.BorderThickness = new Thickness(0); noteBox.Background = Brushes.Transparent;
        noteBox.TextWrapping = TextWrapping.Wrap; noteBox.AcceptsReturn = true; noteBox.MinHeight = 50; noteBox.Padding = new Thickness(8, 7, 8, 7);
        var placeholder = Mac.Text("这里要怎么改…", Mac.Body, color: Mac.Tertiary);
        placeholder.Margin = new Thickness(11, 8, 0, 0); placeholder.IsHitTestVisible = false; placeholder.VerticalAlignment = VerticalAlignment.Top;
        noteBox.TextChanged += (_, _) => placeholder.Visibility = noteBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var wellGrid = new Grid(); wellGrid.Children.Add(noteBox); wellGrid.Children.Add(placeholder);
        var well = new Border { Child = wellGrid, Width = 280, MinHeight = 64, CornerRadius = new CornerRadius(8), Background = Mac.B(0x0D, 0, 0, 0), Margin = new Thickness(0, 10, 0, 10) };
        noteQuote.MaxHeight = 3 * 17; noteQuote.Width = 280;
        var stack = new StackPanel { Margin = new Thickness(16) };
        stack.Children.Add(head); stack.Children.Add(well); stack.Children.Add(noteQuote);
        notePopup.Child = new Border { Child = stack, Background = Mac.B(0xFA, 0xF8, 0xF8, 0xF9), CornerRadius = new CornerRadius(14), BorderBrush = Mac.B(0x26, 0, 0, 0), BorderThickness = new Thickness(0.5), Margin = new Thickness(16), Effect = Mac.Shadow(20, 5, 0.2) };
        notePopup.PlacementTarget = markCanvas;
        notePopup.Closed += (_, _) => SetNote(noteBox.Text, noteNumber);
        noteBox.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape || (e.Key == Key.Return && Keyboard.Modifiers == ModifierKeys.Control)) { notePopup.IsOpen = false; e.Handled = true; }
        };
    }

    void ShowNote(int number)
    {
        if (!focusMode || selected is not { } s || markCanvas.RectOf(number) is not { } rect) return;
        var marks = Sheet(s).Evidence;
        var mark = marks.FirstOrDefault(m => m.Number == number);
        if (mark == null) return;
        if (notePopup.IsOpen) notePopup.IsOpen = false;
        noteNumber = number;
        noteBadgeText.Text = number.ToString();
        noteBox.Text = mark.Note ?? "";
        var said = evidence?.Said(marks, pages[s].ContextIDs).GetValueOrDefault(number);
        noteQuote.Text = Quoted(said ?? new()) ?? "";
        noteQuote.Visibility = noteQuote.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        notePopup.PlacementRectangle = rect;
        notePopup.IsOpen = true;
        noteBox.Focus();
        noteBox.CaretIndex = noteBox.Text.Length;
    }

    // ── the more menu ──

    void ShowMore(FrameworkElement anchor)
    {
        var menu = TrayMenu.Create();
        var enabled = !finalizing;
        menu.Items.Add(TrayMenu.Item("仅复制，不关闭", enabled ? () => CopyWords() : null));
        menu.Items.Add(TrayMenu.Item("复制当前图片", CopyImage));
        menu.Items.Add(TrayMenu.Item("拆开长图", null, enabled: false));
        menu.Items.Add(TrayMenu.Item("打开导出文件夹", enabled ? OpenExportFolder : null));
        menu.Items.Add(new Separator());
        menu.Items.Add(TrayMenu.Item("恢复原始转写", enabled ? RestoreWords : null));
        menu.PlacementTarget = anchor;
        menu.Placement = PlacementMode.Bottom;
        menu.HorizontalOffset = -12; menu.VerticalOffset = -6;
        menu.IsOpen = true;
    }

    // ── pages ──

    int NextNumber => pages.SelectMany(p => p.MarkEvidence).Select(e => e.Number).DefaultIfEmpty(0).Max() + 1;
    BoardMarkSheet Sheet(int i) => new(pages[i].Marks, pages[i].MarkEvidence, NextNumber);
    static string Signature(BoardPage p) =>
        string.Join(";", p.Marks.Select(m => string.Join(",", m.Select(q => $"{q[0]:0.#####}:{q[1]:0.#####}")))) + "|" + string.Join(",", p.MarkEvidence.Select(e => e.Number));

    void ReloadList()
    {
        pageList.Children.Clear();
        for (var i = 0; i < pages.Count; i++) pageList.Children.Add(PageRow(i));
        countLabel.Text = pages.Count == 0 ? "" : $"{pages.Count} 页";
        emptyPages.Visibility = pages.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        listTrash.IsEnabled = pages.Count > 0;
        if (focusMode) ReloadStrip();
        UpdateSubtitle();
    }

    UIElement PageRow(int i)
    {
        var page = pages[i];
        var missing = BoardReadableExport.Unexplained(page.MarkEvidence, page.ContextIDs, evidence).Count;
        var thumb = record.Thumb(page);
        var image = new Border
        {
            Width = 72, Height = 45, CornerRadius = new CornerRadius(Mac.ThumbRadius), BorderBrush = Mac.Separator, BorderThickness = new Thickness(1),
            Background = thumb != null ? new ImageBrush(thumb) { Stretch = Stretch.UniformToFill } : Mac.Quaternary, Margin = new Thickness(Mac.Tight, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var title = Mac.Text($"第 {i + 1} 页", Mac.Body, FontWeights.Medium);
        var warn = Mac.Text(missing > 0 ? $"{missing} 个未说明" : "", Mac.Subheadline, FontWeights.Medium, Mac.Orange);
        warn.Margin = new Thickness(6, 0, 0, 0);
        if (missing > 0) warn.ToolTip = $"有 {missing} 个标记既没写说明、附近也没说话";
        var span = BoardSpeechBlock.Times(blocks, i);
        var paren = span.IndexOf('（');
        if (paren > 0) span = span[..paren];
        span = span.Replace(" – ", "–");
        var detail = Mac.Text(string.Join(" · ", new[] { span.Length == 0 ? "没有时间记录" : span, page.Marks.Count > 0 ? $"{page.Marks.Count} 个标记" : "没有标记" }), Mac.Subheadline, color: Mac.Secondary, digits: true);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui2.Row(title, warn));
        detail.Margin = new Thickness(0, 3, 0, 0);
        texts.Children.Add(detail);
        var check = Mac.Check(page.Included, page.Included ? "这一页会交给 AI（点一下取消）" : "这一页不交给 AI（点一下勾上）");
        System.Windows.Automation.AutomationProperties.SetName(check, $"第 {i + 1} 页交给 AI");
        var index = i;
        check.Click += (_, _) => SetIncluded(check.IsChecked == true, index);
        var row = new DockPanel { Height = 64 };
        DockPanel.SetDock(check, Dock.Right);
        check.Margin = new Thickness(0, 0, Mac.Tight, 0);
        row.Children.Add(check);
        DockPanel.SetDock(image, Dock.Left);
        row.Children.Add(image);
        row.Children.Add(texts);
        var holder = new Border { Child = row, CornerRadius = new CornerRadius(10), Background = i == selected ? Mac.Selection : Brushes.Transparent, Margin = new Thickness(Mac.Inner + 2, 0, Mac.Inner + 2, Mac.Tight) };
        holder.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource is DependencyObject d && FindCheck(d)) return; Select(index); pageScroll.Focus(); };
        return holder;
    }

    static bool FindCheck(DependencyObject? d)
    {
        while (d != null) { if (d is CheckBox) return true; d = d is Visual ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d); }
        return false;
    }

    BoardPage? Current => selected is { } s && s >= 0 && s < pages.Count ? pages[s] : null;

    void Select(int? index)
    {
        if (index == selected) return;
        if (selected is { } old) Render(old);
        ShowPage(index);
        ReloadList();
    }

    void ShowPage(int? index)
    {
        notePopup.IsOpen = false;
        selected = index;
        markCanvas.Selected = null;
        FocusSpeech(index);
        UpdateSwitcher();
        if (index is not { } i || i < 0 || i >= pages.Count || LoadPicture(pages[i]) is not { } image)
        {
            shownImage = null;
            UpdateFocusItem();
            picture.Source = null;
            pictureCard.Visibility = pictureClip.Visibility = markCanvas.Visibility = Visibility.Collapsed;
            markCanvas.Sheet = new BoardMarkSheet(Array.Empty<List<double[]>>(), Array.Empty<BoardMarkEvidence>(), 1);
            shownTitle = pages.Count == 0 ? null : ($"第 {(index ?? 0) + 1} 页", "图片找不到了");
            UpdateSubtitle();
            emptyState.Visibility = Visibility.Visible;
            emptyTitle.Text = pages.Count == 0 ? "这次没有截图" : "图片找不到了";
            emptyDetail.Text = pages.Count == 0 ? "录音和文字已经保存，可以在下方查看" : "截图文件可能被移动或删除了";
            MarksChanged();
            return;
        }
        emptyState.Visibility = Visibility.Collapsed;
        pictureCard.Visibility = pictureClip.Visibility = markCanvas.Visibility = Visibility.Visible;
        UpdateReference();
        shownImage = image;
        UpdateFocusItem();
        zoom.ScaleX = zoom.ScaleY = 1;
        picture.Source = image;
        markCanvas.Sheet = Sheet(i);
        LayoutPicture();
        imageScroll.ScrollToHome();
        MarksChanged();
    }

    static BitmapSource? LoadPicture(BoardPage page)
    {
        foreach (var path in new[] { page.Original, page.Images.FirstOrDefault() })
        {
            if (path == null) continue;
            if (BoardFileWriter.RecoveryImage(path) is { } px) return px.Source;
            if (!File.Exists(path)) continue;
            try
            {
                var b = new BitmapImage();
                b.BeginInit(); b.CacheOption = BitmapCacheOption.OnLoad; b.StreamSource = new MemoryStream(File.ReadAllBytes(path)); b.EndInit(); b.Freeze();
                return b;
            }
            catch { }
        }
        return null;
    }

    /// Fits the picture: whole when it is wide, the full width (scrolling) when it is tall; clear of the tool
    /// columns at the left and the full-size button at the right.
    void LayoutPicture()
    {
        if (shownImage is not { } image || Current is not { } page) return;
        double vw = imageScroll.ActualWidth, vh = imageScroll.ActualHeight;
        if (vw <= 0 || vh <= 0) return;
        const double pad = 12;
        var below = focusMode && pageSwitcher.Visibility == Visibility.Visible ? 64 : 0;
        var side = Math.Max(pad, 16 + SideToolsWidth + 12);
        double availW = Math.Max(80, vw - side * 2), availH = Math.Max(80, vh - pad * 2 - below);
        double w = image.PixelWidth, h = image.PixelHeight;
        var scale = h > w ? availW / w : Math.Min(availW / w, availH / h);
        double sw = Math.Round(w * scale), sh = Math.Round(h * scale);
        var scrolls = sh + pad * 2 > vh;
        canvas.Width = scrolls ? vw - SystemParameters.VerticalScrollBarWidth : vw;
        canvas.Height = Math.Max(vh, sh + pad * 2);
        var x = Math.Round((canvas.Width - sw) / 2);
        var y = scrolls ? pad : Math.Round((canvas.Height - below - sh) / 2);
        foreach (var e in new FrameworkElement[] { pictureCard, pictureClip, markCanvas })
        {
            e.Width = sw; e.Height = sh;
            Canvas.SetLeft(e, x); Canvas.SetTop(e, y);
        }
        pictureClip.Clip = new RectangleGeometry(new Rect(0, 0, sw, sh), Mac.PictureRadius, Mac.PictureRadius);
        markCanvas.LineWidth = Math.Max(1.5, scale * page.LineWidth);
        markCanvas.BadgeDiameter = Math.Max(18, InkStyle.BadgeDiameter(page.LineWidth) * scale);
        markCanvas.Redraw();
    }

    void Zoom(double factor)
    {
        if (shownImage == null) return;
        var m = Math.Clamp(zoom.ScaleX * factor, 1, 6);
        zoom.ScaleX = zoom.ScaleY = m;
    }

    void UpdateReference()
    {
        if (selected is not { } s || s >= pages.Count) { shownTitle = null; UpdateSubtitle(); return; }
        var marks = string.Join("、", pages[s].MarkEvidence.Select(e => e.Number));
        var time = BoardSpeechBlock.Times(blocks, s);
        shownTitle = ($"第 {s + 1} 页", string.Join(" · ", new[] { time, marks.Length == 0 ? "" : "标记 " + marks }.Where(x => x.Length > 0)));
        UpdateSubtitle();
    }

    void UpdateSubtitle()
    {
        var date = record.Date?.ToString("M月d日 HH:mm");
        if (shownTitle is { } t)
        {
            titleText.Text = t.title;
            Title = t.title;
            subtitleText.Text = string.Join(" · ", new[] { t.detail, date }.Where(x => !string.IsNullOrEmpty(x)));
            return;
        }
        titleText.Text = Title = "检查内容";
        var parts = new List<string>();
        if (date != null) parts.Add(date);
        if (pages.Count > 0) parts.Add($"{pages.Count} 页");
        subtitleText.Text = string.Join(" · ", parts);
    }

    // ── tools, focus mode ──

    void SetTool(int index)
    {
        if (sideTools.Selected != index) sideTools.Selected = index;
        markCanvas.Tool = index switch { 1 => InkTool.free, 2 => InkTool.box, 3 => InkTool.ellipse, _ => null };
        markCanvas.Focus();
    }

    void UpdateFocusItem()
    {
        focusButton.Visibility = shownImage == null ? Visibility.Collapsed : Visibility.Visible;
        sideTools.Visibility = sideUndo.Visibility = shownImage == null ? Visibility.Collapsed : Visibility.Visible;
        focusButton.Content = Mac.Symbol(focusMode ? Icons.Collapse : Icons.Expand, 18, Mac.Label, 1.6);
        focusButton.ToolTip = focusMode ? "退出放大标注（Esc）" : "放大图片来标注：画完旁边直接写说明，‹ › 切换页面（双击图片空白处也可以）";
    }

    void ToggleFocus() => SetFocus(!focusMode);

    void ToggleSidebar()
    {
        var hide = sidebar.Visibility == Visibility.Visible;
        sidebarColumn.Width = new GridLength(hide ? 0 : SidebarWidth);
        sidebar.Visibility = hide ? Visibility.Collapsed : Visibility.Visible;
    }

    /// Full-size markup: the sidebar and the lower pane put away, the picture filling the window, a note box beside
    /// each mark drawn or picked, ‹ n / N › under the picture, the pages sliding out from the left edge.
    void SetFocus(bool on)
    {
        if (on == focusMode || (on && shownImage == null)) return;
        notePopup.IsOpen = false;
        focusMode = on;
        sidebarColumn.Width = new GridLength(on ? 0 : SidebarWidth);
        sidebar.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        lowerPane.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        splitterRow.Height = new GridLength(on ? 0 : 9);
        if (on) { savedLower = lowerRow.Height; lowerRow.MinHeight = 0; lowerRow.Height = new GridLength(0); }
        else { lowerRow.MinHeight = 120; lowerRow.Height = savedLower; }
        edgeSensor.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (on) ReloadStrip(); else ConcealStrip(0);
        UpdateSwitcher();
        zoom.ScaleX = zoom.ScaleY = 1;
        Dispatcher.BeginInvoke(LayoutPicture, System.Windows.Threading.DispatcherPriority.Loaded);
        if (on && pageSwitcher.Visibility == Visibility.Visible)
        {
            var t = new TranslateTransform(0, -18);
            pageSwitcher.RenderTransform = t;
            t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(300)) { EasingFunction = new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut } });
            pageSwitcher.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200)));
        }
        UpdateFocusItem();
        markCanvas.Focus();
    }

    void UpdateSwitcher()
    {
        pageSwitcher.Visibility = focusMode && pages.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
        if (selected is { } s)
        {
            switcherLabel.Text = $"{s + 1} / {pages.Count}";
            switcherPrev.IsEnabled = s > 0;
            switcherNext.IsEnabled = s + 1 < pages.Count;
        }
        if (focusMode) ReloadStrip();
    }

    void Step(int delta)
    {
        if (selected is not { } s || s + delta < 0 || s + delta >= pages.Count) { System.Media.SystemSounds.Beep.Play(); return; }
        notePopup.IsOpen = false;
        Select(s + delta);
        if (focusMode) markCanvas.Focus();
    }

    void ReloadStrip()
    {
        stripList.Children.Clear();
        for (var i = 0; i < pages.Count; i++)
        {
            var t = record.Thumb(pages[i]);
            var index = i;
            var cell = new Border
            {
                Height = 64, Margin = new Thickness(0, 0, 0, 8), CornerRadius = new CornerRadius(Mac.ThumbRadius), BorderThickness = new Thickness(i == selected ? 2 : 1),
                BorderBrush = i == selected ? Mac.Accent : Mac.Separator, Background = t != null ? new ImageBrush(t) { Stretch = Stretch.UniformToFill } : Mac.Quaternary, Cursor = Cursors.Hand,
                Child = new TextBlock { Text = (i + 1).ToString(), Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.Bold, Margin = new Thickness(6, 4, 0, 0), Effect = Mac.Shadow(3, 0, 0.8) },
            };
            cell.MouseLeftButtonUp += (_, _) => { if (index != selected) Step(index - (selected ?? 0)); };
            stripList.Children.Add(cell);
        }
    }

    void RevealStrip()
    {
        if (!focusMode || pages.Count == 0) return;
        ConcealStrip(1.2);
        if (stripShown) return;
        stripShown = true;
        ReloadStrip();
        pageStrip.Visibility = Visibility.Visible;
        pageStrip.BeginAnimation(MarginProperty, new ThicknessAnimation(new Thickness(12, 12, 0, 12), TimeSpan.FromMilliseconds(340)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
    }

    void ConcealStrip(double delay)
    {
        stripHide?.Stop();
        void HideStrip()
        {
            if (!stripShown) return;
            stripShown = false;
            var a = new ThicknessAnimation(new Thickness(-160, 12, 0, 12), TimeSpan.FromMilliseconds(220)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn } };
            a.Completed += (_, _) => { if (!stripShown) pageStrip.Visibility = Visibility.Collapsed; };
            pageStrip.BeginAnimation(MarginProperty, a);
        }
        if (delay <= 0) { HideStrip(); return; }
        stripHide = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(delay) };
        stripHide.Tick += (_, _) => { stripHide!.Stop(); HideStrip(); };
        stripHide.Start();
    }

    // ── marks and the undo history ──

    void AddMark(List<double[]> points)
    {
        if (selected is not { } s) return;
        var number = NextNumber;
        Edit(s, "画标记", sheet => sheet.Add(points, number));
        markCanvas.Selected = number;
        if (focusMode) ShowNote(number); else FocusNote(number);
    }

    void DeleteMark(int number)
    {
        if (selected is not { } s) return;
        Edit(s, $"删除标记 {number}", sheet => sheet.Remove(number));
    }

    void SetNote(string text, int number)
    {
        if (selected is not { } s || Sheet(s).IndexOf(number) < 0) return;
        var probe = Sheet(s);
        if (!probe.SetNote(text, number)) return;
        keepCards = true;
        try { Edit(s, "修改说明", sheet => sheet.SetNote(text, number)); }
        finally { keepCards = false; }
    }

    void MarkSelected(int? number)
    {
        deleteItem.IsEnabled = number != null;
        SelectCard(number);
        if (number != null && mode != Mode.Marks) { mode = Mode.Marks; ModeChanged(); }
        if (focusMode && number is { } n) ShowNote(n);
    }

    void Edit(int i, string name, Action<BoardMarkSheet> body)
    {
        if (i < 0 || i >= pages.Count) return;
        var sheet = Sheet(i);
        var before = pages[i].Marks.Count;
        body(sheet);
        Change(name, () =>
        {
            pages[i].Marks = sheet.Strokes;
            pages[i].MarkEvidence = sheet.Evidence;
            pages[i].Included = BoardPageInclusion.After(before, sheet.Marks.Count, pages[i].Included);
        });
    }

    void Change(string name, Action body, bool structural = false)
    {
        undo.Push(new Snapshot(pages.Select(p => p.Clone()).ToList(), selected, name));
        redo.Clear();
        body();
        Refresh(structural);
        UpdateUndoButtons();
    }

    void Undo()
    {
        if (undo.Count == 0) return;
        var state = undo.Pop();
        redo.Push(new Snapshot(pages.Select(p => p.Clone()).ToList(), selected, state.Name));
        Restore(state);
    }

    void Redo()
    {
        if (redo.Count == 0) return;
        var state = redo.Pop();
        undo.Push(new Snapshot(pages.Select(p => p.Clone()).ToList(), selected, state.Name));
        Restore(state);
    }

    void Restore(Snapshot state)
    {
        var structural = !pages.Select(p => p.Images.FirstOrDefault()).SequenceEqual(state.Pages.Select(p => p.Images.FirstOrDefault())) || selected != state.Selected;
        pages = state.Pages.Select(p => p.Clone()).ToList();
        selected = state.Selected;
        Refresh(structural);
        UpdateUndoButtons();
    }

    void UpdateUndoButtons()
    {
        sideUndo.Buttons[0].IsEnabled = undo.Count > 0;
        sideUndo.Buttons[1].IsEnabled = redo.Count > 0;
        sideUndo.Buttons[0].ToolTip = undo.Count > 0 ? "撤销" + undo.Peek().Name + "（Ctrl+Z）" : "撤销（Ctrl+Z）";
        sideUndo.Buttons[1].ToolTip = redo.Count > 0 ? "重做" + redo.Peek().Name + "（Ctrl+Shift+Z）" : "重做（Ctrl+Shift+Z）";
    }

    void Refresh(bool structural)
    {
        RebuildTimeline();
        int? target = selected is { } s && s >= 0 && s < pages.Count ? s : pages.Count == 0 ? null : 0;
        if (structural || target != selected) { ShowPage(target); ReloadList(); return; }
        ReloadList();
        if (selected is not { } i) return;
        var keep = markCanvas.Selected;
        markCanvas.Sheet = Sheet(i);
        markCanvas.Selected = keep;
        UpdateReference();
        MarksChanged();
    }

    /// Redraws a page's marked picture when its marks changed since it was last drawn. False when that failed.
    bool Render(int i)
    {
        if (i < 0 || i >= pages.Count || pages[i].Images.FirstOrDefault() is not { } url) return false;
        var signature = Signature(pages[i]);
        if (rendered.TryGetValue(url, out var done) && done == signature) return true;
        var original = EnsureOriginal(i);
        var pixels = original == null ? null : BoardFileWriter.RecoveryImage(original) ?? Pixels.Load(original);
        if (pixels == null) return false;
        using var bmp = MarkRenderer.Render(pixels, pages[i].Marks, pages[i].MarkEvidence, pages[i].LineWidth);
        if (!MarkRenderer.WritePng(bmp, url)) return false;
        rendered[url] = signature;
        pages[i].ImageNeedsRepair = false;
        using var thumb = MarkRenderer.Render(pixels, pages[i].Marks, pages[i].MarkEvidence, pages[i].LineWidth, 96);
        record.SetThumb(pages[i], MarkRenderer.ToSource(thumb));
        return true;
    }

    readonly Dictionary<string, string> madeOriginals = new(StringComparer.OrdinalIgnoreCase);
    /// A record from before originals were kept has only its marked picture: the first edit copies it as the original.
    string? EnsureOriginal(int i)
    {
        if (pages[i].Original is { } o) return o;
        if (pages[i].Images.FirstOrDefault() is not { } image) return null;
        if (madeOriginals.TryGetValue(image, out var made)) { pages[i].Original = made; return made; }
        var copy = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(image)!, $"原图-{Guid.NewGuid().ToString().ToUpperInvariant()}.png");
        try { File.Copy(image, copy); } catch { return null; }
        madeOriginals[image] = copy;
        pages[i].Original = copy;
        return copy;
    }

    /// Hands the pages to the record, every marked picture brought up to date first. Pages are never dropped by the
    /// review on its own.
    bool Publish()
    {
        if (notePopup.IsOpen) notePopup.IsOpen = false;
        if (Keyboard.FocusedElement is TextBox) Keyboard.ClearFocus();
        var failed = Enumerable.Range(0, pages.Count).Where(i => !Render(i)).Select(i => (i + 1).ToString()).ToList();
        record.Pages = pages.Select(p => p.Clone()).ToList();
        record.Evidence = evidence;
        if (editedTranscript && !finalizing) record.ReviewedTranscript = words.Text;
        record.WriteNotes();
        if (failed.Count > 0)
        {
            note.Text = $"第 {string.Join("、", failed)} 页的标注图片没能更新；标记已保存，请重试";
            note.Foreground = Mac.Orange;
            return false;
        }
        return true;
    }

    public bool CloseSaving()
    {
        if (!Publish()) return false;
        closing = true;
        Close();
        return true;
    }

    /// Pictures of pages deleted here go when the window closes (an undo could still bring them back until then).
    void RemoveUnused()
    {
        var used = BoardRecord.Files(record.Pages).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var gone = undo.SelectMany(s => s.Pages).Concat(redo.SelectMany(s => s.Pages)).SelectMany(p => p.AllFiles)
            .Concat(madeOriginals.Values).Where(f => !used.Contains(f)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (gone.Count > 0) BoardFileWriter.Remove(gone);
    }

    void SetIncluded(bool on, int row)
    {
        if (row < 0 || row >= pages.Count) return;
        Change(on ? "勾选交给 AI" : "取消交给 AI", () => pages[row].Included = on);
    }

    void Move(int delta)
    {
        if (selected is not { } s || s + delta < 0 || s + delta >= pages.Count) return;
        Change("移动页面", () => { (pages[s], pages[s + delta]) = (pages[s + delta], pages[s]); selected = s + delta; }, structural: true);
    }

    /// Deleting a page asks first; even then Ctrl+Z brings it back until the window closes.
    void AskRemove()
    {
        if (selected is not { } s || s >= pages.Count) return;
        var marks = pages[s].Marks.Count;
        var detail = (marks > 0 ? $"这一页的截图和 {marks} 个标记会从记录里删除" : "这一页的截图会从记录里删除") + "；录音和文字不受影响。关闭窗口前可以用 Ctrl+Z 撤销。";
        if (MacAlert.Show(this, $"删除第 {s + 1} 页？", detail, new[] { "删除", "取消" }, destructive: true) != 0) return;
        Change($"删除第 {s + 1} 页", () => { pages.RemoveAt(s); selected = pages.Count == 0 ? null : Math.Min(s, pages.Count - 1); }, structural: true);
    }

    void DeleteSelectedMark()
    {
        if (markCanvas.Selected is { } n) { notePopup.IsOpen = false; DeleteMark(n); }
        else System.Media.SystemSounds.Beep.Play();
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var inText = e.OriginalSource is TextBox;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (ctrl && key == Key.Z && !inText) { if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) Redo(); else Undo(); e.Handled = true; }
        else if (ctrl && key == Key.Y && !inText) { Redo(); e.Handled = true; }
        else if (ctrl && key == Key.Delete) { AskRemove(); e.Handled = true; }
        else if (ctrl && key is Key.OemPlus or Key.Add) { Zoom(1.25); e.Handled = true; }
        else if (ctrl && key is Key.OemMinus or Key.Subtract) { Zoom(0.8); e.Handled = true; }
        else if (ctrl && key is Key.D0 or Key.NumPad0) { zoom.ScaleX = zoom.ScaleY = 1; e.Handled = true; }
        else if (key == Key.Return && !inText && !finalizing) { CopyAndClose(); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Alt && key == Key.Up) { Move(-1); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Alt && key == Key.Down) { Move(1); e.Handled = true; }
        else if (!inText && Keyboard.Modifiers == ModifierKeys.None && (key == Key.Up || key == Key.Down)) { Step(key == Key.Up ? -1 : 1); e.Handled = true; }
        else if (key == Key.Escape && focusMode && !inText) { SetFocus(false); e.Handled = true; }
    }

    // ── the marks list (标记) ──

    readonly Dictionary<int, (Border card, TextBox field, Button trash, TextBlock meta)> cards = new();
    bool keepCards;

    void MarksChanged()
    {
        // a note was written: the cards stay (rebuilding them would take the keyboard from the field just clicked)
        if (keepCards && selected is { } k && k < pages.Count && shownImage != null)
        {
            var current = Sheet(k).Evidence;
            if (current.Select(m => m.Number).SequenceEqual(cards.Keys))
            {
                var near = evidence?.Said(current, pages[k].ContextIDs) ?? new();
                foreach (var mark in current)
                    if (cards.TryGetValue(mark.Number, out var c)) FillMeta(c.meta, TimeOf(mark), Quoted(near.GetValueOrDefault(mark.Number) ?? new()), mark.Note ?? "");
                return;
            }
        }
        markList.Children.Clear();
        cards.Clear();
        var page = selected is { } s && s < pages.Count && shownImage != null;
        if (page)
        {
            var i = selected!.Value;
            var marks = Sheet(i).Evidence;
            var around = evidence?.Said(marks, pages[i].ContextIDs) ?? new();
            foreach (var mark in marks)
                markList.Children.Add(Card(mark.Number, TimeOf(mark), Quoted(around.GetValueOrDefault(mark.Number) ?? new()), mark.Note ?? ""));
        }
        marksEmptyTitle.Text = page ? "这一页还没有标记" : "没有选中的页面";
        marksEmptyDetail.Text = page ? "用左边的画笔在图上画一笔，再在这里写说明" : "在左边选一页";
        marksEmpty.Visibility = markList.Children.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectCard(markCanvas.Selected);
        if (fixButton.Visibility == Visibility.Visible && UnexplainedMarks().Count == 0)
        {
            fixButton.Visibility = Visibility.Collapsed;
            note.Text = "所有标记都有说明了"; note.Foreground = Mac.Secondary;
        }
    }

    static string TimeOf(BoardMarkEvidence mark)
    {
        if (mark.Start?.Audio is { } a) return BoardSpeechBlock.Clock(a);
        if (mark.IsAdded) return "补画";
        if (mark.Start?.Elapsed is { } el) return "会话 " + BoardSpeechBlock.Clock(el);
        return "未记录";
    }

    /// The card's quiet line: when it was drawn, then what was said near it; with neither a note nor speech, says so.
    static void FillMeta(TextBlock meta, string time, string? quote, string noteText)
    {
        meta.Inlines.Clear();
        meta.Inlines.Add(new System.Windows.Documents.Run(time) { FontFamily = Mac.Digits });
        if (quote != null) meta.Inlines.Add(new System.Windows.Documents.Run("   " + quote));
        else if (noteText.Trim().Length == 0)
        {
            meta.Inlines.Add(new System.Windows.Documents.Run(" · "));
            meta.Inlines.Add(new System.Windows.Documents.Run("还没有说明") { Foreground = Mac.Orange });
        }
        meta.ToolTip = quote == null && noteText.Trim().Length == 0 ? "这个标记没有说明，画它的时候和前后几秒也没有说话：AI 只会看到编号" : quote;
    }

    static string? Quoted(List<BoardSpeechSegment> said)
    {
        var parts = said.Select(s => "“" + s.Text.Trim() + "”").ToList();
        return parts.Count == 0 ? null : string.Join(" ", parts);
    }

    /// One mark as a card: the number disc, the note written right in it, one quiet line (when it was drawn, what was
    /// said nearest), a trash button while the pointer is on it or it is chosen.
    UIElement Card(int number, string time, string? quote, string noteText)
    {
        var editable = !finalizing;
        var badge = new Grid { Width = 22, Height = 22, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(Mac.GroupGap, 0, Mac.GroupGap - 2, 0) };
        badge.Children.Add(new Ellipse { Fill = Mac.Black(0.88), Stroke = Brushes.White, StrokeThickness = 1.5 });
        badge.Children.Add(new TextBlock { Text = number.ToString(), Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = 11, FontFamily = Mac.Digits, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        var field = new TextBox
        {
            Text = noteText, FontSize = Mac.Body, FontFamily = Mac.Font, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(-2, 0, 0, 0),
            IsReadOnly = !editable, Foreground = Mac.Label, SelectionBrush = Mac.Accent,
        };
        System.Windows.Automation.AutomationProperties.SetName(field, $"标记 {number} 的说明");
        var placeholder = Mac.Text(editable ? "添加说明…" : "录音结束后可以写说明", Mac.Body, color: Mac.Tertiary);
        placeholder.IsHitTestVisible = false;
        placeholder.Visibility = noteText.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        field.TextChanged += (_, _) => placeholder.Visibility = field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        field.LostKeyboardFocus += (_, _) => SetNote(field.Text, number);
        field.KeyDown += (_, e) => { if (e.Key == Key.Return) { markCanvas.Focus(); e.Handled = true; } };
        field.GotKeyboardFocus += (_, _) => { if (markCanvas.Selected != number) markCanvas.Selected = number; };
        var fieldGrid = new Grid(); fieldGrid.Children.Add(field); fieldGrid.Children.Add(placeholder);
        var meta = new TextBlock { FontSize = Mac.Subheadline, FontFamily = Mac.Font, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0), Foreground = Mac.Secondary };
        FillMeta(meta, time, quote, noteText);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(fieldGrid); texts.Children.Add(meta);
        var trash = Mac.Icon(Icons.Trash, "删除这个标记（可以 Ctrl+Z 撤销）", () => DeleteMark(number), Mac.Hit, 15);
        trash.Visibility = Visibility.Hidden;
        trash.Margin = new Thickness(Mac.Inner, 0, Mac.Inner, 0);
        var row = new DockPanel();
        DockPanel.SetDock(badge, Dock.Left); DockPanel.SetDock(trash, Dock.Right);
        row.Children.Add(badge); row.Children.Add(trash); row.Children.Add(texts);
        var card = new Border
        {
            Child = row, Height = 62, Margin = new Thickness(0, 4, 0, 4), CornerRadius = new CornerRadius(Mac.CardRadius), Background = Mac.Window,
            BorderBrush = Mac.Separator, BorderThickness = new Thickness(1),
        };
        card.MouseEnter += (_, _) => { if (editable) trash.Visibility = Visibility.Visible; };
        card.MouseLeave += (_, _) => { if (markCanvas.Selected != number) trash.Visibility = Visibility.Hidden; };
        card.MouseLeftButtonDown += (_, _) => markCanvas.Selected = number;
        cards[number] = (card, field, trash, meta);
        return card;
    }

    void SelectCard(int? number)
    {
        foreach (var (n, c) in cards)
        {
            var on = n == number;
            c.card.Background = on ? Mac.B(0xFF, 0xE9, 0xF5, 0xF2) : Mac.Window;
            c.card.BorderBrush = on ? Mac.B(0xB3, 0x10, 0x94, 0x78) : Mac.Separator;
            c.card.BorderThickness = new Thickness(on ? 1.5 : 1);
            c.trash.Visibility = on && !finalizing ? Visibility.Visible : Visibility.Hidden;
            if (on) c.card.BringIntoView();
        }
    }

    void FocusNote(int number)
    {
        Dispatcher.BeginInvoke(() => { if (cards.TryGetValue(number, out var c)) { c.field.Focus(); c.field.CaretIndex = c.field.Text.Length; } }, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    List<(int page, int number)> UnexplainedMarks() =>
        Enumerable.Range(0, pages.Count).Where(i => pages[i].Included)
            .SelectMany(i => BoardReadableExport.Unexplained(pages[i].MarkEvidence, pages[i].ContextIDs, evidence).Select(m => (i, m.Number))).ToList();

    void GoToUnexplained()
    {
        var missing = UnexplainedMarks();
        if (missing.Count == 0) { fixButton.Visibility = Visibility.Collapsed; return; }
        var first = missing[0];
        if (selected != first.page) Select(first.page);
        if (mode != Mode.Marks) { mode = Mode.Marks; ModeChanged(); }
        markCanvas.Selected = first.number;
        FocusNote(first.number);
    }

    // ── 按时间 / 全文 ──

    void ModeChanged()
    {
        marksPane.Visibility = mode == Mode.Marks ? Visibility.Visible : Visibility.Collapsed;
        speechPane.Visibility = mode == Mode.Timeline ? Visibility.Visible : Visibility.Collapsed;
        words.Visibility = mode == Mode.Words ? Visibility.Visible : Visibility.Collapsed;
        var shown = mode switch { Mode.Marks => (UIElement)marksPane, Mode.Timeline => speechPane, _ => words };
        shown.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200)));
        foreach (var (m, button, icon, text, fill) in modeButtons)
        {
            var on = m == mode;
            fill.Background = on ? Mac.Quaternary : Brushes.Transparent;
            text.Foreground = on ? Mac.Label : Mac.Secondary;
            text.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
            icon.Stroke = on ? Mac.Accent : Mac.Secondary;
            icon.StrokeThickness = on ? 1.9 : 1.5;
        }
        if (modeButtons.Count == 0) return;
        var timeline = modeButtons.First(b => b.mode == Mode.Timeline).button;
        timeline.IsEnabled = blocks.Count > 0;
        timeline.ToolTip = blocks.Count == 0 ? (finalizing ? "文字整理好后，可以按时间看每一页说了什么" : "这次录音没有分句时间，只能看全文") : "按时间看每一页说了什么";
    }

    void RebuildTimeline()
    {
        blocks = BoardSpeechBlock.Build(pages, evidence);
        ReloadSpeech();
        DrawStrip();
        if (modeButtons.Count == 0) return;
        if (blocks.Count == 0 && mode == Mode.Timeline) { mode = Mode.Words; ModeChanged(); }
        else if (blocks.Count > 0 && !modeChosen && mode == Mode.Words) { mode = Mode.Timeline; ModeChanged(); }
        else ModeChanged();
    }

    double Duration => Math.Max(blocks.Select(b => b.End).DefaultIfEmpty(0).Max(), evidence?.Speech.Select(s => s.End).DefaultIfEmpty(0).Max() ?? 0);

    /// The whole recording as one bar: the kept pages' stretches (the shown page in the accent), screens not kept
    /// (fainter), a tick under the bar for every sentence, 0:00 and the length under its ends.
    void DrawStrip()
    {
        strip.Children.Clear();
        var duration = Duration;
        var width = strip.ActualWidth;
        if (duration <= 0 || width <= 0) return;
        double X(double t) => t / duration * width;
        var track = new Border { Width = width, Height = 10, CornerRadius = new CornerRadius(3), Background = Mac.Black(0.06) };
        Canvas.SetTop(track, 4);
        strip.Children.Add(track);
        foreach (var b in blocks)
        {
            Brush fill;
            if (b.Kind == BoardSpeechBlock.KindTag.Page) fill = b.PageIndex == selected ? Mac.Accent : Mac.Black(0.2);
            else if (b.Kind == BoardSpeechBlock.KindTag.Screen) fill = Mac.Black(0.08);
            else continue;
            var r = new Border { Width = Math.Max(1, Math.Max(3, X(b.End) - X(b.Start)) - 2), Height = 10, CornerRadius = new CornerRadius(3), Background = fill };
            Canvas.SetLeft(r, X(b.Start) + 1); Canvas.SetTop(r, 4);
            strip.Children.Add(r);
        }
        foreach (var s in blocks.SelectMany(b => b.Segments))
        {
            var tick = new Border { Width = 1, Height = 4, Background = Mac.Tertiary };
            Canvas.SetLeft(tick, X(s.Start)); Canvas.SetTop(tick, 17);
            strip.Children.Add(tick);
        }
        var start = Mac.Text("0:00", 10, color: Mac.Tertiary, digits: true);
        Canvas.SetTop(start, 23);
        strip.Children.Add(start);
        var end = Mac.Text(BoardSpeechBlock.Clock(duration), 10, color: Mac.Tertiary, digits: true);
        end.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetTop(end, 23); Canvas.SetLeft(end, width - end.DesiredSize.Width);
        strip.Children.Add(end);
    }

    void StripClicked(object sender, MouseButtonEventArgs e)
    {
        var duration = Duration;
        if (duration <= 0) return;
        var x = e.GetPosition(strip).X;
        var b = blocks.FirstOrDefault(b => b.Kind == BoardSpeechBlock.KindTag.Page && b.Start / duration * strip.ActualWidth - 2 <= x && x <= b.End / duration * strip.ActualWidth + 2);
        if (b != null) Select(b.PageIndex);
    }

    readonly List<(BoardSpeechBlock block, Border holder)> speechBlocks = new();
    readonly Dictionary<BoardSpeechSegment, Button> playButtons = new();

    /// The sentences, stretch by stretch: a header (第 2 页 · 0:12 – 0:31, or the screen that wasn't kept), then each
    /// sentence with a button that plays just it, its start time, and its words (editable once the text is final).
    void ReloadSpeech()
    {
        speechList.Children.Clear();
        speechBlocks.Clear();
        playButtons.Clear();
        var canPlay = File.Exists(record.AudioPath);
        foreach (var b in blocks)
        {
            var stack = new StackPanel { Margin = new Thickness(Mac.Inner, 6, Mac.Inner, 6) };
            var title = b.Kind switch
            {
                BoardSpeechBlock.KindTag.Page => Mac.Text($"第 {b.PageIndex + 1} 页", Mac.Body, FontWeights.SemiBold),
                BoardSpeechBlock.KindTag.Screen => Mac.Text(b.ScreenName.Length == 0 ? "没有保存的画面" : b.ScreenName, Mac.Body, FontWeights.Medium, Mac.Secondary),
                _ => Mac.Text("没有对应画面", Mac.Body, FontWeights.Medium, Mac.Secondary),
            };
            var detail = Mac.Text(BoardSpeechBlock.Clock(b.Start) + " – " + BoardSpeechBlock.Clock(b.End), Mac.Subheadline, color: Mac.Secondary, digits: true);
            detail.Margin = new Thickness(8, 1, 0, 0);
            stack.Children.Add(Ui2.Row(title, detail));
            foreach (var s in b.Segments)
            {
                var row = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
                if (canPlay)
                {
                    var seg = s;
                    var play = Mac.Icon(Icons.PlayCircle, "播放这一句", () => Play(seg), 22, 16, Mac.Secondary, 11);
                    play.VerticalAlignment = VerticalAlignment.Top;
                    play.Margin = new Thickness(0, 0, 4, 0);
                    DockPanel.SetDock(play, Dock.Left);
                    row.Children.Add(play);
                    playButtons[s] = play;
                }
                var time = Mac.Text(BoardSpeechBlock.Clock(s.Start), Mac.Subheadline, color: Mac.Secondary, digits: true);
                time.Width = 42; time.Margin = new Thickness(0, 3, 4, 0); time.VerticalAlignment = VerticalAlignment.Top;
                DockPanel.SetDock(time, Dock.Left);
                row.Children.Add(time);
                var text = new TextBox
                {
                    Text = s.Text, FontSize = Mac.Body, FontFamily = Mac.Font, BorderThickness = new Thickness(0), Background = Brushes.Transparent, TextWrapping = TextWrapping.Wrap,
                    IsReadOnly = finalizing, Foreground = Mac.Label, ToolTip = finalizing ? null : "点一下可以直接改这一句", Padding = new Thickness(-2, 0, 0, 0), SelectionBrush = Mac.Accent,
                };
                var old = s;
                text.LostKeyboardFocus += (_, _) => EditSentence(old, text.Text);
                text.KeyDown += (_, e) => { if (e.Key == Key.Return) { speechScroll.Focus(); e.Handled = true; } };
                row.Children.Add(text);
                stack.Children.Add(row);
            }
            var holder = new Border { Child = stack, CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 12, 0) };
            if (b.Kind == BoardSpeechBlock.KindTag.Page)
            {
                var index = b.PageIndex;
                holder.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource is not TextBox) Select(index); };
            }
            speechBlocks.Add((b, holder));
            speechList.Children.Add(holder);
        }
        FocusSpeech(selected);
    }

    void FocusSpeech(int? page)
    {
        foreach (var (b, holder) in speechBlocks)
            holder.Background = b.Kind == BoardSpeechBlock.KindTag.Page && b.PageIndex == page ? Mac.B(0x17, 0x10, 0x94, 0x78) : Brushes.Transparent;
        DrawStrip();
        speechBlocks.FirstOrDefault(x => x.block.Kind == BoardSpeechBlock.KindTag.Page && x.block.PageIndex == page).holder?.BringIntoView();
    }

    /// A sentence edited in the timeline: the timeline keeps the new words, and the same sentence in the whole text
    /// (what is copied) changes too.
    void EditSentence(BoardSpeechSegment old, string text)
    {
        if (finalizing || evidence == null) return;
        var next = text.Trim();
        if (next == old.Text.Trim()) return;
        var i = evidence.Speech.IndexOf(old);
        if (i < 0) return;
        evidence.Speech[i] = old with { Text = next };
        var whole = words.Text;
        var at = whole.IndexOf(old.Text.Trim(), StringComparison.Ordinal);
        if (at >= 0)
        {
            LoadWords(whole[..at] + next + whole[(at + old.Text.Trim().Length)..]);
            editedTranscript = true;
            note.Text = "已改这一句，全文也一起改了";
        }
        else note.Text = "已改这一句；全文里没找到原句（可能已经在全文里改过），全文没有变";
        note.Foreground = Mac.Secondary;
        Dispatcher.BeginInvoke(RebuildTimeline, System.Windows.Threading.DispatcherPriority.Background);
    }

    void Play(BoardSpeechSegment s)
    {
        playStop?.Stop();
        if (playing == s) { player?.Pause(); SetPlaying(null); return; }
        if (!File.Exists(record.AudioPath)) { note.Text = "这次记录的录音无法播放"; return; }
        player ??= new MediaPlayer();
        if (player.Source?.LocalPath != record.AudioPath) player.Open(new Uri(record.AudioPath));
        player.Position = TimeSpan.FromSeconds(Math.Max(0, s.Start - 0.15));
        player.Play();
        SetPlaying(s);
        playStop = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(Math.Max(0.3, s.End - s.Start + 0.3)) };
        playStop.Tick += (_, _) => { playStop!.Stop(); player?.Pause(); SetPlaying(null); };
        playStop.Start();
    }

    void SetPlaying(BoardSpeechSegment? s)
    {
        playing = s;
        foreach (var (seg, b) in playButtons)
            b.Content = Mac.Symbol(seg == s ? Icons.StopCircle : Icons.PlayCircle, 16, seg == s ? Mac.Accent : Mac.Secondary, 1.5);
    }

    void LoadWords(string text)
    {
        settingWords = true;
        words.Text = text;
        settingWords = false;
    }

    public void UpdateTranscript(string text)
    {
        if (!finalizing || editedTranscript) return;
        LoadWords(text);
        originalTranscript = text;
    }

    public void SetFinalizing(bool value)
    {
        finalizing = value;
        words.IsReadOnly = value;
        foreach (var c in deliveryControls) c.IsEnabled = !value;
        if (value)
        {
            note.Text = "正在整理文字…";
            note.ToolTip = "正在从原始录音整理文字，可以先检查图片";
            note.Foreground = Mac.Secondary;
        }
        else if (note.Text.Length == 0) note.Text = "文字已整理好";
        ReloadSpeech();
        MarksChanged();
    }

    public void FinishTranscript(string text, BoardEvidence? evidence, string? warning)
    {
        if (evidence != null) this.evidence = evidence;
        originalTranscript = text;
        if (!editedTranscript) LoadWords(text);
        finalizing = false;
        note.Text = warning ?? "文字已整理好";
        note.ToolTip = warning == null ? "文字已整理好；在「全文」里修改不会覆盖原始转写" : warning;
        note.Foreground = warning == null ? Mac.Secondary : Mac.Orange;
        SetFinalizing(false);
        RebuildTimeline();
        ReloadList();
    }

    void RestoreWords()
    {
        if (finalizing) return;
        LoadWords(originalTranscript);
        editedTranscript = true;
        mode = Mode.Words; ModeChanged();
    }

    // ── delivery ──

    BoardFolderExport.Bundle? PrepareExport()
    {
        if (finalizing || !Publish()) return null;
        BoardFileWriter.Flush();
        try
        {
            var bundle = record.Export(pages);
            lastExportFolder = bundle.Directory;
            return bundle;
        }
        catch (Exception e)
        {
            note.Text = "图片导出失败，未复制或粘贴：" + e.Message;
            note.Foreground = Mac.Orange;
            return null;
        }
    }

    /// 仅复制: the whole description with the pictures' paths, ready to paste to an AI; the window stays.
    bool CopyWords()
    {
        if (PrepareExport() is not { } export) return false;
        if (!Paste.TrySetText(export.Text)) { note.Text = "图片已导出，但复制失败，请打开导出文件夹查看"; return false; }
        var missing = UnexplainedMarks().Count;
        note.Text = missing == 0 ? "已复制说明和图片路径" : $"已复制；有 {missing} 个标记没有说明";
        note.Foreground = missing == 0 ? Mac.Secondary : Mac.Orange;
        fixButton.Visibility = missing == 0 ? Visibility.Collapsed : Visibility.Visible;
        return true;
    }

    /// 复制并关闭: copy, then close. Marks that would reach the AI as bare numbers are pointed out first.
    void CopyAndClose()
    {
        if (finalizing) return;
        if (Keyboard.FocusedElement is TextBox) Keyboard.ClearFocus();
        var missing = UnexplainedMarks();
        if (missing.Count == 0) { if (CopyWords()) CloseSaving(); return; }
        var choice = MacAlert.Show(this, $"有 {missing.Count} 个标记还没有说明",
            "标记 " + string.Join("、", missing.Select(m => m.number)) + " 既没有写说明，附近也没有说话。AI 只会看到编号，不知道这里要改什么。",
            new[] { "仍然复制并关闭", "去补说明" });
        if (choice == 0) { if (CopyWords()) CloseSaving(); }
        else GoToUnexplained();
    }

    void OpenExportFolder()
    {
        if (finalizing) return;
        if (lastExportFolder != null && Directory.Exists(lastExportFolder)) Paste.OpenFolder(lastExportFolder);
        else if (PrepareExport() is { } export) Paste.OpenFolder(export.Directory);
    }

    void CopyImage()
    {
        if (selected is not { } s || !Render(s) || pages[s].Images.FirstOrDefault() is not { } url) return;
        if (Paste.TrySetImage(url)) note.Text = "已复制当前图片";
    }
}

/// A column of icon buttons on one glass capsule, floating at the picture's left (BoardSideTools): the drawing tools
/// (one chosen at a time: a soft round fill and the accent) or undo / redo.
public sealed class SideTools : Border
{
    public Action<int>? OnPick;
    public List<Button> Buttons { get; } = new();
    readonly bool selects;
    readonly List<Geometry> symbols = new();
    int selected = -1;

    public SideTools((Geometry symbol, string tip)[] items, bool selects)
    {
        this.selects = selects;
        var stack = new StackPanel { Margin = new Thickness(4) };
        for (var i = 0; i < items.Length; i++)
        {
            var index = i;
            symbols.Add(items[i].symbol);
            var b = new Button { Width = 36, Height = 36, Margin = new Thickness(0, i == 0 ? 0 : 2, 0, 0), ToolTip = items[i].tip, Focusable = false };
            System.Windows.Automation.AutomationProperties.SetName(b, items[i].tip);
            b.Click += (_, _) => { if (this.selects) Selected = index; OnPick?.Invoke(index); };
            Buttons.Add(b);
            stack.Children.Add(b);
        }
        Child = stack;
        Width = 44;
        Background = Mac.B(0xEB, 0xFC, 0xFC, 0xFC);
        BorderBrush = Mac.B(0x14, 0, 0, 0);
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(22);
        Effect = Mac.Shadow(12, 2, 0.12);
        Selected = selects ? 0 : -1;
    }

    public int Selected
    {
        get => selected;
        set
        {
            selected = value;
            for (var i = 0; i < Buttons.Count; i++)
            {
                var on = i == selected;
                var pointer = symbols[i] == Icons.Pointer;
                Buttons[i].Content = Mac.Symbol(symbols[i], 18, on ? Mac.Accent : Mac.Label, 1.6, fill: pointer);
                Buttons[i].Template = Mac.Template(on ? Mac.Black(0.10) : Brushes.Transparent, on ? Mac.Black(0.12) : Mac.Hover, 18, pressed: Mac.Selection);
            }
        }
    }
}

static class Ui2
{
    public static StackPanel Row(params UIElement[] items)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var i in items) s.Children.Add(i);
        return s;
    }
}
