using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Media3D;
using System.Windows.Shapes;

namespace T1Controller;

internal enum GuideDevice { T1, Xiaomi }

public partial class DeviceGuide : UserControl
{
    private const double CameraCenter = -.20;
    private const double VisibleHeight = 8.94;
    private readonly AxisAngleRotation3D yaw = new(new Vector3D(0, 1, 0), -.20 * 180 / Math.PI);
    private readonly AxisAngleRotation3D pitch = new(new Vector3D(1, 0, 0), .025 * 180 / Math.PI);
    private readonly Transform3DGroup orientation = new();
    private readonly OrthographicCamera camera = new(new Point3D(0, CameraCenter, 19),
        new Vector3D(0, 0, -1), new Vector3D(0, 1, 0), VisibleHeight) { NearPlaneDistance = 1, FarPlaneDistance = 36 };
    private readonly Dictionary<GeometryModel3D, string> parts = [];
    private readonly Dictionary<string, Button> labels = [];
    private readonly SolidColorBrush highlight = new(Color.FromRgb(32, 47, 113));
    private readonly SolidColorBrush leader = new(Color.FromArgb(96, 171, 185, 255));
    private readonly Model3DGroup hardware = new();
    private RemoteModel model = null!;
    private GuideDevice current;
    private int faceIndex;
    private string selected = "ok";
    private Point? press, lastDrag;
    private bool t1Connected, xiaomiConnected;
    private bool ready, animating;
    private IReadOnlyList<ButtonBinding> summaryBindings = [];
    private RemoteMode? remoteMode;
    private bool remapping, mediaMode;
    private string player = "未选播放器";
    internal event Action<GuideDevice>? ConfigureRequested;

    public DeviceGuide()
    {
        InitializeComponent();
        orientation.Children.Add(new RotateTransform3D(pitch));
        orientation.Children.Add(new RotateTransform3D(yaw));
        orientation.Children.Add(new RotateTransform3D(new AxisAngleRotation3D(new Vector3D(0, 0, 1), -2)));
        RemoteViewport.Camera = camera;
        RemoteViewport.Children.Add(new ModelVisual3D { Content = new AmbientLight(Color.FromRgb(126, 127, 139)) });
        RemoteViewport.Children.Add(new ModelVisual3D
        {
            Content = new DirectionalLight(Color.FromRgb(205, 207, 221), new Vector3D(.39, -.46, -.80))
        });
        RemoteViewport.Children.Add(new ModelVisual3D
        {
            Content = new DirectionalLight(Color.FromRgb(104, 126, 176), new Vector3D(-.68, .52, -.52))
        });
        hardware.Transform = orientation;
        RemoteViewport.Children.Add(new ModelVisual3D { Content = hardware });
        ready = true;
        LoadProfile(GuideDevice.T1);
    }

    internal void UpdateConnections(bool t1, bool xiaomi)
    {
        t1Connected = t1;
        xiaomiConnected = xiaomi;
        UpdateConnectionLabel();
    }

    internal void UpdateSummary(IReadOnlyList<ButtonBinding> bindings, RemoteMode? mode, bool enabled, bool music, string name)
    {
        summaryBindings = bindings;
        remoteMode = mode;
        remapping = enabled;
        mediaMode = music;
        player = name;
        DisplaySummary();
        DisplaySelection();
    }

    private void UpdateConnectionLabel()
    {
        var xiaomi = current == GuideDevice.Xiaomi;
        var connected = xiaomi ? xiaomiConnected : t1Connected;
        ConnectionDot.Fill = connected ? Brushes.LightGreen : (Brush)FindResource("MutedBrush");
        Connection.Text = xiaomi
            ? connected ? "小米遥控器已连接" : "小米遥控器未检测到"
            : connected ? "T1 接收器已连接" : "T1 接收器未检测到";
    }

    private void SelectProfile(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: string tag })
            LoadProfile(tag == "1" ? GuideDevice.Xiaomi : GuideDevice.T1);
    }

    private void LoadProfile(GuideDevice profile)
    {
        if (model is not null && current == profile) return;
        current = profile;
        var xiaomi = profile == GuideDevice.Xiaomi;
        model = RemoteModel.For(xiaomi);
        ProfileSubtitle.Text = xiaomi ? "小米蓝牙遥控器 2 Pro · RC003" : "T1 空中飞鼠";
        T1Profile.Background = ChoiceBrush(!xiaomi);
        XiaomiProfile.Background = ChoiceBrush(xiaomi);
        hardware.Children.Clear();
        parts.Clear();
        foreach (var part in model.Parts)
        {
            var mesh = RemoteMesh.Create(part);
            hardware.Children.Add(mesh);
            parts.Add(mesh, part.Key);
        }
        FacePicker.Children.Clear();
        for (var i = 0; i < model.Faces.Length; i++)
        {
            var face = new Button { Content = model.Faces[i].Name, Tag = i, Margin = new Thickness(1, 0, 1, 0) };
            AutomationProperties.SetName(face, $"查看{model.Faces[i].Name}");
            face.Click += (_, _) => SetFace((int)face.Tag, animate: true);
            FacePicker.Children.Add(face);
        }
        selected = "ok";
        SetFace(0, animate: false);
        UpdateConnectionLabel();
        DisplaySummary();
    }

    private void SetFace(int index, bool animate)
    {
        faceIndex = index;
        var face = model.Faces[index];
        if (!face.Keys.Contains(selected))
            selected = index == 0 ? "ok" : face.Keys[0];
        for (var i = 0; i < FacePicker.Children.Count; i++)
            ((Button)FacePicker.Children[i]).Background = ChoiceBrush(i == index);
        var from = yaw.Angle;
        var target = face.Yaw * 180 / Math.PI;
        yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, null);
        yaw.Angle = target;
        pitch.Angle = .025 * 180 / Math.PI;
        DisplaySelection();
        if (animate && SystemParameters.ClientAreaAnimation)
        {
            Labels.Visibility = Leaders.Visibility = Visibility.Hidden;
            animating = true;
            var motion = new DoubleAnimation(from, target, TimeSpan.FromMilliseconds(300))
            {
                FillBehavior = FillBehavior.Stop, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
            };
            motion.Completed += (_, _) =>
            {
                animating = false;
                LayoutCallouts(true);
            };
            yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, motion);
        }
        else
        {
            animating = false;
            LayoutCallouts(true);
        }
    }

    private void StageResized(object sender, SizeChangedEventArgs args)
    {
        if (!ready || Stage.ActualHeight <= 0 || Stage.ActualWidth <= 0) return;
        camera.Width = VisibleHeight * Stage.ActualWidth / Stage.ActualHeight;
        Rings.Children.Clear();
        foreach (var radius in new[] { 104.0, 158.0, 217.0, 284.0 })
        {
            var ring = new Ellipse
            {
                Width = radius * 2, Height = radius * 2, Stroke = LeaderBrush(24), StrokeThickness = 1
            };
            Canvas.SetLeft(ring, Stage.ActualWidth * .5 - radius);
            Canvas.SetTop(ring, Stage.ActualHeight * .49 - radius);
            Rings.Children.Add(ring);
        }
        LayoutCallouts(false);
    }

    private void LayoutCallouts(bool rebuild)
    {
        if (model is null || animating || lastDrag.HasValue || Stage.ActualWidth < 300) return;
        var width = Stage.ActualWidth;
        var height = Stage.ActualHeight;
        Labels.Visibility = Leaders.Visibility = Visibility.Visible;
        Leaders.Children.Clear();
        if (rebuild)
        {
            labels.Clear();
            Labels.Children.Clear();
        }
        foreach (var key in model.Faces[faceIndex].Keys)
        {
            var label = model.Keys[key];
            var caption = BindingAction(key) ?? label.Action;
            if (!labels.TryGetValue(key, out var button))
            {
                var title = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold };
                var action = new TextBlock
                {
                    FontSize = 9.5, Foreground = (Brush)FindResource("MutedBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis
                };
                var text = new StackPanel();
                text.Children.Add(title);
                text.Children.Add(action);
                button = new Button
                {
                    Content = text, Width = 108, Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0),
                    HorizontalContentAlignment = HorizontalAlignment.Left, ToolTip = label.Guide
                };
                button.Click += (_, _) => SelectKey(key);
                Labels.Children.Add(button);
                labels.Add(key, button);
            }
            var active = key == selected;
            var lines = (StackPanel)button.Content;
            ((TextBlock)lines.Children[0]).Text = label.Name;
            ((TextBlock)lines.Children[1]).Text = caption;
            AutomationProperties.SetName(button, $"{label.Name}，{caption}");
            button.Background = ChoiceBrush(active);
            button.BorderBrush = active ? (Brush)FindResource("AccentBrush") : (Brush)FindResource("GlassStroke");
            var left = label.Left ? 16 : width - 124;
            var top = height * label.Level;
            Canvas.SetLeft(button, left);
            Canvas.SetTop(button, top - 17);
            var a = label.Anchor;
            var p = orientation.Transform(new Point3D(a[0], a[1], a[2]));
            var unit = height / VisibleHeight;
            var anchor = new Point(width / 2 + p.X * unit, height / 2 - (p.Y - CameraCenter) * unit);
            var jointX = label.Left ? left + 108 : left;
            var ink = active ? (Brush)FindResource("AccentBrush") : leader;
            Leaders.Children.Add(new Polyline
            {
                Stroke = ink, StrokeThickness = active ? 1.4 : .8, StrokeLineJoin = PenLineJoin.Round,
                Points = new PointCollection([new(jointX, top), new(jointX + (label.Left ? 11 : -11), top), anchor])
            });
            var dot = new Ellipse { Width = active ? 6 : 4, Height = active ? 6 : 4, Fill = ink };
            Canvas.SetLeft(dot, anchor.X - dot.Width / 2);
            Canvas.SetTop(dot, anchor.Y - dot.Height / 2);
            Leaders.Children.Add(dot);
        }
    }

    private void BeginRotation(object sender, MouseButtonEventArgs args)
    {
        press = args.GetPosition(RemoteViewport);
        lastDrag = null;
        Mouse.Capture(RemoteViewport);
        args.Handled = true;
    }

    private void RotateRemote(object sender, MouseEventArgs args)
    {
        if (press is not { } origin || args.LeftButton != MouseButtonState.Pressed) return;
        var now = args.GetPosition(RemoteViewport);
        if (!lastDrag.HasValue && (now - origin).Length < 7) return;
        if (!lastDrag.HasValue)
        {
            var angle = yaw.Angle;
            yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, null);
            yaw.Angle = angle;
            animating = false;
            Leaders.Visibility = Labels.Visibility = Visibility.Hidden;
        }
        var delta = now - (lastDrag ?? origin);
        lastDrag = now;
        yaw.Angle = Math.Clamp(yaw.Angle + delta.X * .69, current == GuideDevice.Xiaomi ? -117.5 : -187.5, 22.9);
        pitch.Angle = Math.Clamp(pitch.Angle - delta.Y * .52, -20.6, 20.6);
    }

    private void EndRotation(object sender, MouseButtonEventArgs args)
    {
        if (!press.HasValue) return;
        var point = args.GetPosition(RemoteViewport);
        var dragged = lastDrag.HasValue;
        press = lastDrag = null;
        Mouse.Capture(null);
        if (dragged)
        {
            var index = yaw.Angle > -41 ? 0 : yaw.Angle > -125 || current == GuideDevice.Xiaomi ? 1 : 2;
            SetFace(index, animate: true);
        }
        else
        {
            VisualTreeHelper.HitTest(RemoteViewport, null, hit =>
            {
                if (hit is not RayMeshGeometry3DHitTestResult mesh ||
                    mesh.ModelHit is not GeometryModel3D geometry || !parts.TryGetValue(geometry, out var key))
                    return HitTestResultBehavior.Continue;
                if (key != "shell" && model.Faces[faceIndex].Keys.Contains(key)) SelectKey(key);
                return key.Length == 0 ? HitTestResultBehavior.Continue : HitTestResultBehavior.Stop;
            }, new PointHitTestParameters(point));
        }
        args.Handled = true;
    }

    private void ReleaseRotation(object sender, MouseEventArgs args)
    {
        if (!press.HasValue) return;
        press = lastDrag = null;
        SetFace(faceIndex, animate: false);
    }

    private void SelectKey(string key)
    {
        selected = key;
        DisplaySelection();
    }

    private void DisplaySelection()
    {
        if (model is null || !model.Keys.TryGetValue(selected, out var key)) return;
        KeyTitle.Text = key.Name;
        KeyIcon.Data = RemoteMesh.Icon(key.Icon);
        KeyDetail.Text = key.Guide;
        var binding = Mapping(selected);
        var active = BindingAction(selected);
        KeyAction.Text = active ?? key.Action;
        KeyStatus.Text = binding is null ? "原生功能" : !binding.Enabled ? "映射已暂停"
            : NeedsNativeIsolation(binding) ? "原生未隔离 · 映射暂停"
            : active is null ? "当前模式未使用" : "映射开启";
        ConfigureButton.Visibility = key.Mappable ? Visibility.Visible : Visibility.Collapsed;
        foreach (var (part, associatedKey) in parts)
            if (part.Material is MaterialGroup group && group.Children.Count == 3 && group.Children[2] is EmissiveMaterial glow)
                glow.Brush = associatedKey == selected ? highlight : Brushes.Black;
        LayoutCallouts(false);
    }

    private IEnumerable<ButtonBinding> ProfileBindings => summaryBindings.Where(binding =>
        current == GuideDevice.Xiaomi
            ? binding.DevicePath.Contains("32B8", StringComparison.OrdinalIgnoreCase)
            : binding.DevicePath.Contains("1915", StringComparison.OrdinalIgnoreCase));

    private ButtonBinding? Mapping(string key)
    {
        string[] controls = key switch
        {
            "voice" => new[] { "key:74/", "hid:000C/00CF/" },
            "ok" => ["key:0D/"],
            "home" => ["key:24/", "hid:000C/0223/"],
            "menu" => ["key:5D/"],
            "left" => ["key:25/", "hid:000C/00B6/"],
            "right" => ["key:27/", "hid:000C/00B5/"],
            "mute" => ["key:AD/", "hid:000C/00E2/"],
            "volumeUp" => ["key:AF/", "hid:000C/00E9/"],
            "volumeDown" => ["key:AE/", "hid:000C/00EA/"],
            _ => []
        };
        var matches = ProfileBindings.Where(binding => controls.Any(control =>
            binding.Control.StartsWith(control, StringComparison.OrdinalIgnoreCase))).ToArray();
        return matches.FirstOrDefault(binding => binding.Enabled && RemoteModes.Allows(binding.Role, remoteMode, remapping))
            ?? matches.FirstOrDefault();
    }

    private string? BindingAction(string key)
    {
        var binding = Mapping(key);
        if (binding is not { Enabled: true } || !RemoteModes.Allows(binding.Role, remoteMode, remapping) ||
            NeedsNativeIsolation(binding)) return null;
        return binding.Role switch
        {
            ButtonRole.Menu => remoteMode is null ? "切换播放器／主机" : "切换播放器",
            ButtonRole.CycleMode => "循环切换模式",
            ButtonRole.SwitchHost => "切换主机",
            ButtonRole.PlayPause => "播放／暂停",
            ButtonRole.PreviousTrack when remoteMode == RemoteMode.Media || mediaMode => "上一曲",
            ButtonRole.NextTrack when remoteMode == RemoteMode.Media || mediaMode => "下一曲",
            ButtonRole.VolumeUp => "提高音量",
            ButtonRole.VolumeDown => "降低音量",
            ButtonRole.Mute => "切换系统静音",
            ButtonRole.Voice => "按住说话",
            _ => null
        };
    }

    private bool NeedsNativeIsolation(ButtonBinding binding) => RemoteModes.RequiresNativeIsolation(remoteMode, binding.Role);

    private void DisplaySummary()
    {
        MappingSummary.Text = $"已启用绑定　{ProfileBindings.Count(binding => binding.Enabled)} 项";
        ModeSummary.Text = $"当前模式　{RemoteModes.Title(remoteMode)}";
        PlayerSummary.Text = $"当前播放器　{player}";
    }

    private static Brush ChoiceBrush(bool selected) => new SolidColorBrush(selected
        ? Color.FromArgb(68, 140, 158, 254) : Color.FromArgb(72, 57, 67, 87));
    private static Brush LeaderBrush(byte opacity) => new SolidColorBrush(Color.FromArgb(opacity, 171, 185, 255));
    private void Configure(object sender, RoutedEventArgs args) => ConfigureRequested?.Invoke(current);
}
