using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace T1Controller;

/// Non-activating desktop feedback, including when Orvio is in the tray.
internal sealed class RemoteModeHUD : Window
{
    private readonly TextBlock title = new() { FontSize = 20, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock detail = new() { FontSize = 12, Foreground = new SolidColorBrush(Color.FromRgb(184, 192, 210)) };
    private readonly TextBlock symbol = new() { FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 25 };
    private readonly StackPanel steps = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
    private readonly DispatcherTimer dismissal = new() { Interval = TimeSpan.FromSeconds(2.4) };
    private long generation;

    public RemoteModeHUD()
    {
        Width = 370; Height = 112;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        IsHitTestVisible = false;
        Topmost = true;
        Foreground = Brushes.WhiteSmoke;
        var accent = new SolidColorBrush(Color.FromRgb(171, 186, 255));
        symbol.Foreground = accent;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(69) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var badge = new Border { Width = 54, Height = 54, CornerRadius = new CornerRadius(17),
            Background = new SolidColorBrush(Color.FromArgb(38, 171, 186, 255)),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
            Child = symbol };
        symbol.HorizontalAlignment = HorizontalAlignment.Center;
        symbol.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(badge);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(title);
        detail.Margin = new Thickness(0, 4, 0, 0);
        detail.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(detail);
        text.Children.Add(steps);
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        Content = new Border { CornerRadius = new CornerRadius(25), Padding = new Thickness(20),
            BorderBrush = new SolidColorBrush(Color.FromArgb(70, 255, 255, 255)), BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(242, 34, 40, 55)), Child = grid };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = GetWindowLongPtrW(handle, -20).ToInt64();
            SetWindowLongPtrW(handle, -20, new IntPtr(style | 0x08000000 | 0x00000080 | 0x00000020));
        };
        dismissal.Tick += (_, _) =>
        {
            dismissal.Stop();
            var token = generation;
            if (!SystemParameters.ClientAreaAnimation) { Hide(); return; }
            var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
            fade.Completed += (_, _) => { if (token == generation) Hide(); };
            BeginAnimation(OpacityProperty, fade);
        };
        Closed += (_, _) => dismissal.Stop();
    }

    public void ShowMode(RemoteMode mode, string player)
    {
        generation++; dismissal.Stop();
        BeginAnimation(OpacityProperty, null); Opacity = 1;
        title.Text = $"{RemoteModes.Title(mode)}模式";
        detail.Text = mode switch {
            RemoteMode.Native => "原生按键与语音输入已恢复",
            RemoteMode.Media => $"音乐控制 · {player}",
            _ => "使用已绑定的按键切换电脑"
        };
        symbol.Text = mode switch { RemoteMode.Native => "\uE765", RemoteMode.Media => "\uE8D6", _ => "\uE7F4" };
        steps.Children.Clear();
        foreach (var item in Enum.GetValues<RemoteMode>())
            steps.Children.Add(new Border { Width = item == mode ? 20 : 7, Height = 4,
                CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 0, 5, 0),
                Background = item == mode ? symbol.Foreground : new SolidColorBrush(Color.FromArgb(50, 200, 208, 230)),
                VerticalAlignment = VerticalAlignment.Center });
        steps.Children.Add(new TextBlock { Text = "O R V I O", FontSize = 8, Foreground = detail.Foreground });
        System.Windows.Automation.AutomationProperties.SetName(this, $"Orvio，{title.Text}");
        var monitor = MonitorFromWindow(GetForegroundWindow(), 2);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        var area = GetMonitorInfoW(monitor, ref info) ? info.Work : new RectNative { Right = 1920, Bottom = 1080 };
        var dpi = GetDpiForMonitor(monitor, 0, out var x, out _) == 0 ? x / 96.0 : 1.0;
        var handle = new WindowInteropHelper(this).EnsureHandle();
        var width = (int)Math.Round(Width * dpi); var height = (int)Math.Round(Height * dpi);
        SetWindowPos(handle, new IntPtr(-1), (area.Left + area.Right - width) / 2,
            area.Bottom - height - (int)(68 * dpi), width, height, 0x0010);
        Show();
        dismissal.Start();
    }

    [StructLayout(LayoutKind.Sequential)] private struct RectNative { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public RectNative Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern IntPtr SetWindowLongPtrW(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
}
