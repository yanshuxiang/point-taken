// The tray menu, drawn like the macOS menu bar menu (BoardHome.boardMenu): a rounded translucent panel, 14-pt items
// with their shortcuts on the right, the blue highlight, a check for the chosen model, a submenu for the models.
//   开始标注        Alt+N     (while recording: 正在标注 · 请使用顶部灵动岛, greyed)
//   ───
//   识别模型：X        ▸     (submenu: each model · 本地 / · API, ✓ on the chosen one, ─, 模型与 API 设置…)
//   ───
//   历史记录…
//   设置…           Ctrl+,
//   ───
//   退出            Ctrl+Q
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;

namespace PointTaken.App;

public static class TrayMenu
{
    const string Xaml = """
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="MacMenu" TargetType="ContextMenu">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="HasDropShadow" Value="False"/>
    <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ContextMenu">
          <Border Margin="12" Background="#F5F6F6F7" BorderBrush="#26000000" BorderThickness="0.5" CornerRadius="11" Padding="5" MinWidth="250">
            <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="6" Direction="270" Opacity="0.22"/></Border.Effect>
            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Separator">
          <Border Height="1" Background="#1A000000" Margin="14,5,14,5"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="MenuItem">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Foreground" Value="#D9000000"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="MenuItem">
          <Grid>
            <Border x:Name="bg" CornerRadius="6" Background="Transparent" Height="30" SnapsToDevicePixels="True">
              <Grid Margin="8,0,10,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="20"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Path x:Name="check" Grid.Column="0" Data="M4,12.5 L9.5,18 L20,6" Stretch="Uniform" Width="11" Height="11" Stroke="{TemplateBinding Foreground}" StrokeThickness="1.8"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Hidden" VerticalAlignment="Center"/>
                <ContentPresenter Grid.Column="1" ContentSource="Header" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                <TextBlock x:Name="key" Grid.Column="2" Text="{TemplateBinding InputGestureText}" Margin="28,0,0,0" VerticalAlignment="Center" Opacity="0.5"/>
                <Path x:Name="arrow" Grid.Column="2" Data="M0,0 L5,4.5 L0,9 Z" Fill="{TemplateBinding Foreground}" VerticalAlignment="Center" Margin="28,0,0,0" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <Popup x:Name="PART_Popup" Placement="Right" HorizontalOffset="-6" VerticalOffset="-17" IsOpen="{TemplateBinding IsSubmenuOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
              <Border Margin="12" Background="#F5F6F6F7" BorderBrush="#26000000" BorderThickness="0.5" CornerRadius="11" Padding="5" MinWidth="230">
                <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="6" Direction="270" Opacity="0.22"/></Border.Effect>
                <StackPanel IsItemsHost="True"/>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="check" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="Role" Value="TopLevelHeader"><Setter TargetName="arrow" Property="Visibility" Value="Visible"/><Setter TargetName="key" Property="Visibility" Value="Collapsed"/></Trigger>
            <Trigger Property="Role" Value="SubmenuHeader"><Setter TargetName="arrow" Property="Visibility" Value="Visible"/><Setter TargetName="key" Property="Visibility" Value="Collapsed"/></Trigger>
            <Trigger Property="IsHighlighted" Value="True">
              <Setter TargetName="bg" Property="Background" Value="#2F6FE4"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#42000000"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
""";

    /// macOS overlay scrollbars: a thin rounded thumb, no track, no arrows; a little wider under the pointer.
    const string ScrollXaml = """
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="MacThumb" TargetType="Thumb">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="t" CornerRadius="3.5" Background="#59000000" Margin="2"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#80000000"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Background" Value="Transparent"/>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Vertical">
        <Setter Property="Width" Value="11"/>
        <Setter Property="MinWidth" Value="11"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Grid Background="Transparent">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                  <Track.Thumb><Thumb Style="{StaticResource MacThumb}"/></Track.Thumb>
                </Track>
              </Grid>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Height" Value="11"/>
        <Setter Property="MinHeight" Value="11"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Grid Background="Transparent">
                <Track x:Name="PART_Track">
                  <Track.Thumb><Thumb Style="{StaticResource MacThumb}"/></Track.Thumb>
                </Track>
              </Grid>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToolTip">
          <Border Background="#F7F7F7F8" BorderBrush="#26000000" BorderThickness="0.5" CornerRadius="6" Padding="8,4" Margin="6">
            <Border.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="2" Direction="270" Opacity="0.15"/></Border.Effect>
            <ContentPresenter TextElement.FontSize="12" TextElement.Foreground="#D9000000" TextElement.FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI">
              <ContentPresenter.Resources>
                <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="MaxWidth" Value="320"/></Style>
              </ContentPresenter.Resources>
            </ContentPresenter>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
""";

    /// Installs the macOS scrollbars and tooltips for every window of the app.
    public static void InstallStyles(Application app) => app.Resources.MergedDictionaries.Add((ResourceDictionary)XamlReader.Parse(ScrollXaml));

    static ResourceDictionary? resources;
    static ResourceDictionary Resources => resources ??= (ResourceDictionary)XamlReader.Parse(Xaml);

    public static ContextMenu Create()
    {
        var menu = new ContextMenu { Style = (Style)Resources["MacMenu"] };
        menu.Resources.MergedDictionaries.Add(Resources);
        return menu;
    }

    public static MenuItem Item(string title, Action? run, string? key = null, bool enabled = true, bool check = false, string? tip = null)
    {
        var item = new MenuItem { Header = title, InputGestureText = key ?? "", IsEnabled = enabled && (run != null), IsChecked = check, ToolTip = tip };
        if (run != null) item.Click += (_, _) => run();
        return item;
    }
}
