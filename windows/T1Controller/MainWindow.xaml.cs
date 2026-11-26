using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace T1Controller;

public partial class MainWindow : Window
{
    private const int FirstPresetHotkeyId = 3;
    private const int VoiceHotkeyId = 11;
    private const int FirstModeHotkeyId = 12;
    private static readonly ushort[] ModeHotkeyKeys = [0x79, 0x31, 0x32, 0x33];
    private const ushort F1 = 0x70;
    private const ushort F9 = 0x78;
    private const uint PresetModifiers = 7;
    private const string KeyboardVoiceOwner = "global-voice-hotkey";
    private static readonly ActionKind[] PresetActions =
    [
        ActionKind.PreviousTrack, ActionKind.TogglePlayback, ActionKind.NextTrack, ActionKind.VolumeDown,
        ActionKind.ToggleMute, ActionKind.VolumeUp, ActionKind.NextPlayer, ActionKind.SwitchOtherHost
    ];
    private sealed record RoleChoice(ButtonRole Role, string Name);
    private sealed record ModeChoice(RemoteMode? Mode, string Name);
    private sealed record BindingChoice(ButtonBinding Binding, string Name);
    private sealed record MarkerChoice(string? Path, string Name);
    private sealed record Learning(string Path, ButtonRole Role, string? Pressed = null);
    private NativeTextTarget? speechTextTarget;
    private bool speechIsDictation;
    private long voiceDeliveryRevision;
    private long speechRevisionAtStart;

    private static readonly RoleChoice[] Roles =
    [
        new(ButtonRole.CycleMode, "模式键 · 循环切换"),
        new(ButtonRole.Menu, "媒体 · 切换播放器"),
        new(ButtonRole.PlayPause, "媒体 · 播放 / 暂停"),
        new(ButtonRole.PreviousTrack, "媒体 · 上一曲"),
        new(ButtonRole.NextTrack, "媒体 · 下一曲"),
        new(ButtonRole.VolumeUp, "媒体 · 音量加"),
        new(ButtonRole.VolumeDown, "媒体 · 音量减"),
        new(ButtonRole.Mute, "媒体 · 静音 / 取消静音"),
        new(ButtonRole.Voice, "通用 · 按住说话"),
        new(ButtonRole.SwitchHost, "主机切换 · 切到另一台")
    ];

    private readonly Settings settings;
    private readonly Gestures gestures = new();
    private readonly RemoteModeHUD modeHud = new();
    private readonly DisplayService displays = new();
    private readonly MediaService media;
    private readonly SwitchCoordinator switcher;
    private readonly Recommendations recommendations;
    private readonly SongDesktopAgent songAgent;
    private readonly VoiceService voice;
    private readonly SemaphoreSlim actionGate = new(1, 1);
    private readonly DispatcherTimer voiceKeyRelease = new() { Interval = TimeSpan.FromMilliseconds(40) };
    private RawInput? raw;
    private HwndSource? source;
    private Forms.NotifyIcon? tray;
    private Learning? learning;
    private string? selectedDevice;
    private string? voiceButton;
    private bool ready;
    private bool updatingDevices;
    private bool updatingPlayers;
    private bool exiting;
    private bool offeredSetupGuide;
    private long? lastModeRelease;

    public MainWindow()
    {
        var loaded = Settings.Load();
        settings = loaded.Value;
        foreach (var menu in settings.Bindings.Where(binding => binding.Role == ButtonRole.Menu).ToArray())
            if (!settings.Bindings.Any(binding => binding.Role == ButtonRole.SwitchHost &&
                string.Equals(binding.DevicePath, menu.DevicePath, StringComparison.OrdinalIgnoreCase)))
                settings.Bindings.Add(menu with { Role = ButtonRole.SwitchHost });
        settings.XiaoAI ??= new();
        media = new MediaService(settings);
        switcher = new SwitchCoordinator(settings, displays);
        recommendations = new Recommendations(settings, media);
        songAgent = new SongDesktopAgent(settings, media);
        voice = new VoiceService(settings);
        voiceKeyRelease.Tick += FollowVoiceHotkey;
        voice.Status += message => VoiceStatus.Text = message;
        voice.Starting += () =>
        {
            speechIsDictation = RemoteModes.VoiceDestination(settings.RemoteMode, false) == VoiceInputDestination.Text;
            speechRevisionAtStart = voiceDeliveryRevision;
            speechTextTarget = speechIsDictation ? NativeTextTarget.Capture() : null;
        };
        voice.Transcribed += text =>
        {
            VoiceTranscript.Text = text;
            if (!speechIsDictation) TextCommand.Text = text;
            _ = DeliverVoiceText(text, speechIsDictation, speechTextTarget, speechRevisionAtStart);
        };

        InitializeComponent();
        DeviceOverview.ConfigureRequested += ConfigureGuideDevice;
        if (loaded.Warning is { } warning)
            ActionStatus.Text = warning;
        RoleBox.ItemsSource = Roles;
        RoleBox.SelectedItem = Roles.First(choice => choice.Role ==
            (settings.RemoteMode is null ? ButtonRole.Menu : ButtonRole.CycleMode));
        RemappingEnabled.IsChecked = settings.Remapping;
        MediaMode.IsChecked = settings.MediaMode;
        RefreshModeChoices();
        PlayerVolume.IsChecked = settings.PreferPlayerVolume;
        MusicTraceEnabled.IsChecked = settings.RecordMusicDiagnostics;
        MusicOcrPath.Text = settings.MusicOcrExecutable ?? "";
        PlayPauseHotkey.Text = settings.PlayPauseHotkey ?? "";
        SwitchHostHotkey.Text = settings.SwitchHostHotkey ?? "";
        PresetHotkeys.IsChecked = settings.ActionHotkeysEnabled;
        ModeHotkeys.IsChecked = settings.ModeHotkeysEnabled;
        KeyboardVoice.IsChecked = settings.VoiceHotkeyEnabled;
        WindowsInput.Text = FormatInput(settings.WindowsInput);
        MacInput.Text = FormatInput(settings.MacInput);
        ToggleWithPeripherals.IsChecked = settings.SwitchWithPeripherals;
        HubHotkey.Text = settings.HubHotkey ?? "";
        WhisperExe.Text = settings.WhisperExecutable ?? "";
        WhisperModel.Text = settings.WhisperModel ?? "";
        if (voice.FindRecognizer() is not null)
            VoiceStatus.Text = "本地中文识别可用。请选择要使用的麦克风。";
        XiaoAIEnabled.IsChecked = settings.XiaoAI.Enabled;
        XiaoAIAddress.Text = settings.XiaoAI.HomeAssistantUrl;
        XiaoAIEntity.Text = settings.XiaoAI.NotifyEntity;
        XiaoAITopic.Text = settings.XiaoAI.Topic;
        XiaoAICommand.Text = settings.XiaoAI.Command;
        XiaoAISilent.IsChecked = settings.XiaoAI.IncludeSilentParameter;
        XiaoAIPython.Text = settings.XiaoAI.PythonExecutable;
        RefreshPlayers();
        RefreshBindings();
        LoadMicrophones();
        LoadOutputs();
        ready = true;
        UpdateOverview();
    }

    private void OnSourceInitialized(object? sender, EventArgs args)
    {
        source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        if (source is null)
            return;
        source.AddHook(WindowMessage);
        try
        {
            raw = new RawInput(source);
            raw.DevicesChanged += RefreshDeviceChoices;
            raw.DeviceRemoved += OnDeviceRemoved;
            raw.Button += OnRawButton;
            raw.Report += AppendInputLog;
            raw.Error += message => ActionStatus.Text = message;
            RefreshDeviceChoices();
        }
        catch (Win32Exception exception)
        {
            ActionStatus.Text = exception.Message;
        }
        RefreshHotkeys();
        SystemEvents.PowerModeChanged += PowerModeChanged;
        tray = CreateTray();
        _ = LoadDisplays();
    }

    private Forms.NotifyIcon CreateTray()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("打开设置", null, (_, _) => Reveal());
        menu.Items.Add("切换播放器", null, (_, _) => _ = Dispatch(new(ActionKind.NextPlayer)));
        menu.Items.Add("上一曲", null, (_, _) => _ = Dispatch(new(ActionKind.PreviousTrack)));
        menu.Items.Add("播放 / 暂停", null, (_, _) => _ = Dispatch(new(ActionKind.TogglePlayback)));
        menu.Items.Add("下一曲", null, (_, _) => _ = Dispatch(new(ActionKind.NextTrack)));
        menu.Items.Add("音量加", null, (_, _) => _ = Dispatch(new(ActionKind.VolumeUp)));
        menu.Items.Add("音量减", null, (_, _) => _ = Dispatch(new(ActionKind.VolumeDown)));
        menu.Items.Add("全部切到 Windows", null, (_, _) => _ = Dispatch(new(ActionKind.SwitchHost, Host: Host.Windows)));
        menu.Items.Add("全部切到 Mac", null, (_, _) => _ = Dispatch(new(ActionKind.SwitchHost, Host: Host.Mac)));
        var modes = new Forms.ToolStripMenuItem("遥控器模式");
        foreach (var mode in Enum.GetValues<RemoteMode>())
            modes.DropDownItems.Add(RemoteModes.Title(mode), null, (_, _) => SelectRemoteMode(mode)).Tag = mode;
        menu.Items.Add(modes);
        var remap = (Forms.ToolStripMenuItem)menu.Items.Add("启用映射", null, (_, _) =>
        {
            RemappingEnabled.IsChecked = RemappingEnabled.IsChecked != true;
        });
        menu.Opening += (_, _) =>
        {
            remap.Visible = settings.RemoteMode is null;
            remap.Checked = settings.Remapping;
            modes.Text = $"遥控器模式 · {RemoteModes.Title(settings.RemoteMode)}";
            foreach (Forms.ToolStripMenuItem item in modes.DropDownItems)
                item.Checked = item.Tag is RemoteMode mode && settings.RemoteMode == mode;
        };
        menu.Items.Add("退出", null, (_, _) =>
        {
            exiting = true;
            Application.Current.Shutdown();
        });
        var icon = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application, Text = "Orvio", ContextMenuStrip = menu, Visible = true
        };
        icon.DoubleClick += (_, _) => Reveal();
        return icon;
    }

    private void Reveal()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void HideWindow(object sender, RoutedEventArgs args) => HideToTray();

    private void HideToTray()
    {
        learning = null;
        ProbeEnabled.IsChecked = false;
        if (voiceButton is { } owner)
        {
            voiceButton = null;
            _ = voice.Finish(owner, cancel: true);
        }
        Hide();
    }

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (exiting || tray is null)
        {
            raw?.Dispose();
            raw = null;
            if (source is not null)
            {
                for (var id = 1; id < FirstModeHotkeyId + ModeHotkeyKeys.Length; id++)
                    Keyboard.UnregisterHotKey(source.Handle, id);
                source.RemoveHook(WindowMessage);
            }
            return;
        }
        args.Cancel = true;
        HideToTray();
    }

    private void OnClosed(object? sender, EventArgs args)
    {
        modeHud.Close();
        SystemEvents.PowerModeChanged -= PowerModeChanged;
        voiceKeyRelease.Stop();
        voice.Dispose();
        if (tray is not null)
        {
            tray.Visible = false;
            tray.ContextMenuStrip?.Dispose();
            tray.Dispose();
        }
    }

    private void PowerModeChanged(object sender, PowerModeChangedEventArgs args)
    {
        _ = Dispatcher.InvokeAsync(() =>
        {
            gestures.Reset();
            raw?.ResetState();
            if (voice.Owner is { } owner)
                _ = voice.Finish(owner, cancel: true);
            if (args.Mode == PowerModes.Resume)
                RefreshRaw();
        });
    }

    private void RefreshRaw()
    {
        try { raw?.Refresh(); }
        catch (Win32Exception exception) { ActionStatus.Text = exception.Message; }
    }

    private void RefreshDevices(object sender, RoutedEventArgs args) => RefreshRaw();

    private void RefreshDeviceChoices()
    {
        updatingDevices = true;
        var devices = raw?.Devices ?? [];
        DeviceOverview.UpdateConnections(devices.Any(device => device.IsT1), devices.Any(device => device.IsXiaomiRemote),
            devices.Any(device => device.IsChromecastRemote));
        DeviceBox.ItemsSource = devices;
        DeviceBox.SelectedItem = devices.FirstOrDefault(device =>
            string.Equals(device.Path, selectedDevice, StringComparison.OrdinalIgnoreCase));
        var markers = devices.Select(device => new MarkerChoice(device.Path, device.DisplayName)).ToList();
        if (settings.HubOwnerDevicePath is { } existing && markers.All(marker => marker.Path != existing))
            markers.Add(new MarkerChoice(existing, "已校准设备 · 当前未连接"));
        markers.Insert(0, new MarkerChoice(null, "手动交接"));
        var selectedMarker = (HubDeviceBox.SelectedItem as MarkerChoice)?.Path ?? settings.HubOwnerDevicePath;
        HubDeviceBox.ItemsSource = markers;
        HubDeviceBox.SelectedItem = markers.FirstOrDefault(marker => marker.Path == selectedMarker) ?? markers[0];
        updatingDevices = false;
        UpdateDeviceStatus();
    }

    private void ConfigureGuideDevice(GuideDevice profile)
    {
        MainTabs.SelectedItem = RemoteTab;
        var options = (raw?.Devices ?? []).Where(device => profile == GuideDevice.Chromecast ? device.IsChromecastRemote : profile == GuideDevice.Xiaomi ? device.IsXiaomiRemote : device.IsT1)
            .ToArray();
        if (options.Length == 1) DeviceBox.SelectedItem = options[0];
        else if (options.Length > 1) DeviceBox.Focus();
        else ActionStatus.Text = "连接所选遥控器后，刷新设备并选择对应的输入设备。";
    }

    private void ShowFirstRunGuide(object sender, RoutedEventArgs args)
    {
        if (offeredSetupGuide || settings.SetupGuideSeen) return;
        offeredSetupGuide = true;
        _ = Dispatcher.InvokeAsync(() => { if (IsVisible && !exiting) OpenSetupGuide(); });
    }

    private void ShowSetupGuide(object sender, RoutedEventArgs args) => OpenSetupGuide();

    private void OpenSetupGuide()
    {
        var guide = new SetupGuide(() =>
        {
            RefreshRaw();
            var devices = raw?.Devices ?? [];
            var t1 = devices.Any(device => device.IsT1) ? "T1 已检测到" : "T1 未检测到";
            var xiaomi = devices.Any(device => device.IsXiaomiRemote) ? "小米 RC003 已检测到" : "小米 RC003 未检测到";
            return $"{t1} · {xiaomi}";
        }, () => voice.FindRecognizer() is not null) { Owner = this };
        guide.ShowDialog();
        if (!settings.SetupGuideSeen)
        {
            settings.SetupGuideSeen = true;
            Persist();
        }
        if (guide.OpenVoiceSettings) MainTabs.SelectedItem = VoiceTab;
    }

    private void DeviceSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!ready || updatingDevices)
            return;
        selectedDevice = (DeviceBox.SelectedItem as RawDevice)?.Path;
        learning = null;
        NativeVerified.IsChecked = false;
        InputLog.Items.Clear();
        gestures.Reset();
        raw?.ResetState();
        UpdateDeviceStatus();
    }

    private void TabChanged(object sender, SelectionChangedEventArgs args)
    {
        if (ready && ReferenceEquals(sender, args.OriginalSource) && sender is TabControl tabs && tabs.SelectedItem != RemoteTab)
            ProbeEnabled.IsChecked = false;
    }

    private void UpdateDeviceStatus()
    {
        if (DeviceBox.SelectedItem is RawDevice device)
        {
            DevicePath.Text = device.Path.Contains("VID_1A86&PID_8022", StringComparison.OrdinalIgnoreCase)
                ? "KMFU 共用设备。请用接收器直连或蓝牙验证 T1 的独立事件。"
                : device.Path;
        }
        else
            DevicePath.Text = "选择 T1 的接收器或蓝牙设备，或已配对的小米蓝牙遥控器。";
        UpdateWatchedDevices();
        UpdateOverview();
    }

    private void ProbeChanged(object sender, RoutedEventArgs args)
    {
        if (!ready)
            return;
        if (ProbeEnabled.IsChecked != true)
        {
            learning = null;
            LearningStatus.Text = "按键诊断已停止。";
        }
        InputLog.Items.Clear();
        gestures.Reset();
        raw?.ResetState();
        UpdateWatchedDevices();
    }

    private void UpdateWatchedDevices()
    {
        if (raw is null)
            return;
        raw.ProbePath = ProbeEnabled.IsChecked == true && DeviceBox.SelectedItem is RawDevice device ? device.Path : null;
        try
        {
            // Follow releases across presets so held keys cannot become fresh presses at a mode change.
            raw.Watch(settings.Bindings.Where(binding => binding.Enabled && (settings.RemoteMode is not null || AllowsRemoteRole(binding.Role)))
                .Select(binding => binding.DevicePath));
        }
        catch (Win32Exception exception)
        {
            ActionStatus.Text = exception.Message;
        }
    }

    private void LearnButton(object sender, RoutedEventArgs args)
    {
        if (DeviceBox.SelectedItem is not RawDevice device || RoleBox.SelectedItem is not RoleChoice choice)
        {
            LearningStatus.Text = "请先选择飞鼠设备和功能。";
            return;
        }
        if (NativeVerified.IsChecked != true)
        {
            LearningStatus.Text = "先观察该键在其他应用中的原生动作，确认无冲突后再学习。";
            return;
        }
        if (device.Path.Contains("VID_1A86&PID_8022", StringComparison.OrdinalIgnoreCase))
        {
            LearningStatus.Text = "请改选能独立识别 T1 的设备路径。该 KMFU 集合还会报告普通键鼠。";
            return;
        }
        ProbeEnabled.IsChecked = true;
        learning = new Learning(device.Path, choice.Role);
        LearningStatus.Text = "请按下并松开飞鼠上的实体键。";
    }

    private void CancelLearning(object sender, RoutedEventArgs args)
    {
        learning = null;
        LearningStatus.Text = "已取消学习。";
    }

    private void AppendInputLog(string message)
    {
        InputLog.Items.Insert(0, message);
        if (InputLog.Items.Count > 40)
            InputLog.Items.RemoveAt(InputLog.Items.Count - 1);
    }

    private void CopyDiagnostics(object sender, RoutedEventArgs args)
    {
        if (DeviceBox.SelectedItem is not RawDevice device || InputLog.Items.Count == 0)
        {
            LearningStatus.Text = "先选择设备并采集按键事件。";
            return;
        }
        try
        {
            Clipboard.SetText(string.Join(Environment.NewLine,
                new[] { "Orvio · Windows", device.DisplayName, device.Path }
                    .Concat(InputLog.Items.Cast<string>().Reverse())));
            LearningStatus.Text = "已将设备及最近按键事件复制到剪贴板。";
        }
        catch (ExternalException)
        {
            LearningStatus.Text = "暂时无法访问剪贴板，请稍后重试。";
        }
    }

    private void OnDeviceRemoved(string path)
    {
        var identity = path.ToUpperInvariant();
        gestures.Reset(identity);
        if (learning is { } candidate && string.Equals(path, candidate.Path, StringComparison.OrdinalIgnoreCase))
        {
            learning = null;
            LearningStatus.Text = "设备已断开，请连接后重新学习。";
        }
        if (voice.Owner is { } owner && owner.StartsWith(identity + "|", StringComparison.Ordinal))
            _ = voice.Finish(owner, cancel: true);
    }

    private void OnRawButton(ButtonEvent button)
    {
        if (ProbeEnabled.IsChecked == true && DeviceBox.SelectedItem is RawDevice device && device.Path == button.Device.Path)
        {
            AppendInputLog($"{(button.Repeat ? "重复" : button.Down ? "按下" : "松开")} · {button.Control}");
            if (learning is { } candidate && candidate.Path == button.Device.Path)
            {
                if (button.Down && !button.Repeat && candidate.Pressed is null)
                {
                    if (candidate.Role == ButtonRole.CycleMode && RemoteModes.IsReturnKey(button.Control))
                    {
                        LearningStatus.Text = "OK／回车用于原生输入和模式内动作，请另选一个模式键。";
                        return;
                    }
                    learning = candidate with { Pressed = button.Control };
                }
                else if (!button.Down && candidate.Pressed == button.Control)
                {
                    if (settings.Bindings.Any(binding => string.Equals(binding.DevicePath, candidate.Path, StringComparison.OrdinalIgnoreCase) &&
                        binding.Control == button.Control && binding.Role != candidate.Role && RemoteModes.Conflicts(binding.Role, candidate.Role)))
                    {
                        learning = candidate with { Pressed = null };
                        LearningStatus.Text = "此键在同一模式已有动作，或被模式键占用。请另选键，或移除旧绑定。";
                        return;
                    }
                    settings.Bindings.RemoveAll(binding => string.Equals(binding.DevicePath, candidate.Path, StringComparison.OrdinalIgnoreCase) &&
                        binding.Role == candidate.Role);
                    settings.Bindings.Add(new ButtonBinding(candidate.Path, button.Control, candidate.Role));
                    learning = null;
                    RefreshBindings();
                    Persist();
                    UpdateOverview();
                    LearningStatus.Text = "已学习。Windows 需接通设备级过滤驱动后才能隔离此键，功能组合可先用电脑快捷键切换。";
                }
            }
            return;
        }
        var binding = settings.Bindings.FirstOrDefault(item => item.Enabled && AllowsRemoteRole(item.Role) &&
            string.Equals(item.DevicePath, button.Device.Path, StringComparison.OrdinalIgnoreCase) && item.Control == button.Control);
        if (binding is null)
            return;
        if (settings.RemoteMode == RemoteMode.Native && binding.Role == ButtonRole.Voice &&
            (button.Device.IsT1 || button.Device.IsXiaomiRemote || button.Device.IsChromecastRemote))
            return; // Keep the hardware voice key's system behavior in native mode.
        if (RemoteModes.RequiresNativeIsolation(settings.RemoteMode, binding.Role))
        {
            if (!button.Down)
                ActionStatus.Text = "Windows 设备级过滤驱动尚未接通，此绑定已暂停。可用 Ctrl+Alt+Shift+F10 切换功能组合。";
            return;
        }
        var key = button.Device.Path.ToUpperInvariant();
        var volume = binding.Role is ButtonRole.VolumeUp or ButtonRole.VolumeDown;
        var gesture = gestures.Observe(key, button.Control, button.Down, button.Timestamp, volume, button.Repeat);
        if (binding.Role == ButtonRole.CycleMode)
        {
            if (gesture == Gesture.Short && (lastModeRelease is not long previous ||
                Stopwatch.GetElapsedTime(previous, button.Timestamp) >= TimeSpan.FromMilliseconds(180)))
            {
                lastModeRelease = button.Timestamp;
                SelectRemoteMode(RemoteModes.Next(settings.RemoteMode));
            }
            return;
        }
        if (binding.Role == ButtonRole.Voice)
        {
            var owner = key + "|" + button.Control;
            if (gesture == Gesture.Press)
            {
                ReportVoiceEdge(button, "down");
                if (!voice.EndPulseOnNextPress(owner)) voice.Start(owner, probe: false);
            }
            else if (!button.Down)
            {
                ReportVoiceEdge(button, "up");
                voice.Release(owner, button.Device.IsT1 && button.Control == "hid:000C/00CF/02");
            }
            return;
        }
        var action = RemoteModes.Resolve(binding.Role, gesture, settings.RemoteMode, settings.Remapping, settings.MediaMode);
        if (action is { } value)
            _ = Dispatch(new ControllerAction(value));
    }

    private void ReportVoiceEdge(ButtonEvent button, string edge)
    {
        if (!settings.RecordMusicDiagnostics) return;
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "T1Controller", "MusicDiagnostics");
        try
        {
            Directory.CreateDirectory(folder);
            var device = button.Device.IsXiaomiRemote ? "RC003" : button.Device.IsT1 ? "T1" : "Remote";
            File.AppendAllText(Path.Combine(folder, "voice-edges.log"),
                $"{DateTimeOffset.Now:O}\t{device}\t{button.Control}\t{edge}{Environment.NewLine}");
        }
        catch (Exception issue) when (issue is IOException or UnauthorizedAccessException)
        {
            VoiceStatus.Text = "无法保存按键诊断。";
        }
    }

    private void RefreshBindings()
    {
        BindingsList.ItemsSource = settings.Bindings.Select(binding =>
            new BindingChoice(binding, $"{RoleName(binding.Role)} · {binding.Control} · {(binding.Enabled ? "已启用" : "已停用")}")).ToArray();
        UpdateWatchedDevices();
    }

    private string RoleName(ButtonRole role) => role == ButtonRole.Menu && settings.RemoteMode is null
        ? "菜单 · 短按切播放器 / 长按切主机"
        : Roles.First(choice => choice.Role == role).Name;

    private bool AllowsRemoteRole(ButtonRole role) => RemoteModes.Allows(role, settings.RemoteMode, settings.Remapping);

    private void RefreshModeChoices()
    {
        var legacy = settings.RemoteMode is null;
        var modes = Enum.GetValues<RemoteMode>().Select(mode => new ModeChoice(mode, RemoteModes.Title(mode)));
        var choices = (legacy ? modes.Prepend(new ModeChoice(null, RemoteModes.Title(null))) : modes).ToArray();
        ModePicker.ItemsSource = choices;
        ModePicker.SelectedItem = choices.First(choice => choice.Mode == settings.RemoteMode);
        RemappingEnabled.Visibility = MediaMode.Visibility = legacy ? Visibility.Visible : Visibility.Collapsed;
        var selection = (RoleBox.SelectedItem as RoleChoice)?.Role ?? ButtonRole.CycleMode;
        var roles = Roles.Select(choice => choice with { Name = RoleName(choice.Role) }).ToArray();
        RoleBox.ItemsSource = roles;
        RoleBox.SelectedItem = roles.First(choice => choice.Role == selection);
    }

    private void ModeSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (ready && ModePicker.SelectedItem is ModeChoice { Mode: { } mode }) SelectRemoteMode(mode);
    }

    private void SelectRemoteMode(RemoteMode mode)
    {
        if (settings.RemoteMode == mode) return;
        settings.RemoteMode = mode;
        voiceDeliveryRevision++;
        speechTextTarget = null;
        gestures.Reset();
        if (voice.Owner is { } owner)
            _ = voice.Finish(owner, cancel: true);
        RefreshModeChoices();
        RefreshBindings();
        UpdateOverview();
        modeHud.ShowMode(mode, settings.Players.FirstOrDefault(item => item.Id == settings.CurrentPlayer)?.Name ?? "未选播放器");
        if (Persist()) ActionStatus.Text = $"遥控器已切到「{RemoteModes.Title(mode)}」模式。";
    }

    private void MappingChanged(object sender, RoutedEventArgs args)
    {
        if (!ready)
            return;
        settings.Remapping = RemappingEnabled.IsChecked == true;
        settings.MediaMode = MediaMode.IsChecked == true;
        gestures.Reset();
        raw?.ResetState();
        if (!settings.Remapping && voice.Owner is { } owner && owner.Contains('|'))
            _ = voice.Finish(owner, cancel: true);
        UpdateWatchedDevices();
        Persist();
        UpdateOverview();
    }

    private void ToggleBinding(object sender, RoutedEventArgs args)
    {
        if (BindingsList.SelectedItem is not BindingChoice choice)
            return;
        var index = settings.Bindings.IndexOf(choice.Binding);
        if (index >= 0)
        {
            settings.Bindings[index] = choice.Binding with { Enabled = !choice.Binding.Enabled };
            gestures.Reset();
            if (!settings.Bindings[index].Enabled && choice.Binding.Role == ButtonRole.Voice && voice.Owner is { } owner && owner.Contains('|'))
                _ = voice.Finish(owner, cancel: true);
            RefreshBindings();
            Persist();
            UpdateOverview();
        }
    }

    private void RemoveBinding(object sender, RoutedEventArgs args)
    {
        if (BindingsList.SelectedItem is BindingChoice choice)
        {
            settings.Bindings.Remove(choice.Binding);
            gestures.Reset();
            if (choice.Binding.Role == ButtonRole.Voice && voice.Owner is { } owner && owner.Contains('|'))
                _ = voice.Finish(owner, cancel: true);
            RefreshBindings();
            Persist();
            UpdateOverview();
        }
    }

    private void ResetBindings(object sender, RoutedEventArgs args)
    {
        settings.Bindings.Clear();
        SelectRemoteMode(RemoteMode.Native);
        RemappingEnabled.IsChecked = false;
        MediaMode.IsChecked = false;
        learning = null;
        gestures.Reset();
        RefreshBindings();
        Persist();
        ActionStatus.Text = "已恢复默认透传。";
    }

    private void SaveGlobalHotkeys(object sender, RoutedEventArgs args)
    {
        var presets = PresetHotkeys.IsChecked == true;
        var modes = ModeHotkeys.IsChecked == true;
        var keyboardVoice = KeyboardVoice.IsChecked == true;
        if (!ValidOptionalChord(PlayPauseHotkey.Text) || !ValidOptionalChord(SwitchHostHotkey.Text) ||
            SameChord(PlayPauseHotkey.Text, SwitchHostHotkey.Text) ||
            SameChord(settings.HubHotkey, PlayPauseHotkey.Text) || SameChord(settings.HubHotkey, SwitchHostHotkey.Text) ||
            new[] { PlayPauseHotkey.Text, SwitchHostHotkey.Text, settings.HubHotkey }
                .Any(chord => ConflictsWithPreset(chord, presets, keyboardVoice, modes)))
        {
            PresetHotkeys.IsChecked = settings.ActionHotkeysEnabled;
            ModeHotkeys.IsChecked = settings.ModeHotkeysEnabled;
            KeyboardVoice.IsChecked = settings.VoiceHotkeyEnabled;
            ActionStatus.Text = "请填写互不冲突的有效快捷键，或留空。自定义、预设和 KMFU 快捷键不能重复。";
            return;
        }
        settings.PlayPauseHotkey = PlayPauseHotkey.Text.Trim();
        settings.SwitchHostHotkey = SwitchHostHotkey.Text.Trim();
        settings.ActionHotkeysEnabled = presets;
        settings.ModeHotkeysEnabled = modes;
        settings.VoiceHotkeyEnabled = keyboardVoice;
        if (!keyboardVoice && voice.Owner == KeyboardVoiceOwner)
        {
            voiceKeyRelease.Stop();
            _ = voice.Finish(KeyboardVoiceOwner, cancel: true);
        }
        if (Persist())
            ActionStatus.Text = RefreshHotkeys() ? "已保存全局快捷键。" : "有快捷键被占用，请修改后重试。";
    }

    private bool RefreshHotkeys()
    {
        if (source is null)
            return false;
        for (var id = 1; id < FirstModeHotkeyId + ModeHotkeyKeys.Length; id++)
            Keyboard.UnregisterHotKey(source.Handle, id);
        var ok = Register(1, settings.PlayPauseHotkey) & Register(2, settings.SwitchHostHotkey);
        if (settings.ActionHotkeysEnabled)
            for (var index = 0; index < PresetActions.Length; index++)
                ok &= Keyboard.RegisterHotKey(source.Handle, FirstPresetHotkeyId + index, PresetModifiers | 0x4000, (uint)(F1 + index));
        if (settings.VoiceHotkeyEnabled)
            ok &= Keyboard.RegisterHotKey(source.Handle, VoiceHotkeyId, PresetModifiers | 0x4000, F9);
        if (settings.ModeHotkeysEnabled)
            for (var index = 0; index < ModeHotkeyKeys.Length; index++)
                ok &= Keyboard.RegisterHotKey(source.Handle, FirstModeHotkeyId + index, PresetModifiers | 0x4000, ModeHotkeyKeys[index]);
        return ok;

        bool Register(int id, string? text)
        {
            return !KeyChord.TryParse(text, out var chord) ||
                Keyboard.RegisterHotKey(source.Handle, id, chord.Modifiers | 0x4000, chord.VirtualKey);
        }
    }

    private static bool ConflictsWithPreset(string? chord, bool actions, bool keyboardVoice, bool modes) =>
        KeyChord.TryParse(chord, out var parsed) && parsed.Modifiers == PresetModifiers &&
        ((actions && parsed.VirtualKey is >= F1 and < F9) || (keyboardVoice && parsed.VirtualKey == F9) ||
            (modes && ModeHotkeyKeys.Contains(parsed.VirtualKey)));

    private void FollowVoiceHotkey(object? sender, EventArgs args)
    {
        if (voice.Owner == KeyboardVoiceOwner && Keyboard.IsDown(F9)) return;
        voiceKeyRelease.Stop();
        _ = voice.Finish(KeyboardVoiceOwner);
    }

    private IntPtr WindowMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == 0x0312)
        {
            var id = wParam.ToInt32();
            if (id is 1 or 2)
            {
                handled = true;
                _ = Dispatch(new(id == 1 ? ActionKind.TogglePlayback : ActionKind.SwitchOtherHost));
            }
            else if (id is >= FirstPresetHotkeyId and < VoiceHotkeyId)
            {
                handled = true;
                _ = Dispatch(new(PresetActions[id - FirstPresetHotkeyId]));
            }
            else if (id == VoiceHotkeyId)
            {
                handled = true;
                if (settings.VoiceHotkeyEnabled && Keyboard.IsDown(F9) && voice.Owner is null)
                {
                    voice.Start(KeyboardVoiceOwner, probe: false);
                    if (voice.Owner == KeyboardVoiceOwner) voiceKeyRelease.Start();
                }
            }
            else if (id >= FirstModeHotkeyId && id < FirstModeHotkeyId + ModeHotkeyKeys.Length && settings.ModeHotkeysEnabled)
            {
                handled = true;
                SelectRemoteMode(id == FirstModeHotkeyId ? RemoteModes.Next(settings.RemoteMode) :
                    (RemoteMode)(id - FirstModeHotkeyId - 1));
            }
        }
        return IntPtr.Zero;
    }

    private async Task Dispatch(ControllerAction action, bool viaXiaoAI = false, bool xiaoAITest = false)
    {
        if (!await actionGate.WaitAsync(0))
        {
            ActionStatus.Text = "正在执行上一条指令。";
            return;
        }
        try
        {
            var result = action.Kind switch
            {
                ActionKind.OpenPlayer => media.Open(action.Player ?? settings.CurrentPlayer),
                ActionKind.NextPlayer => media.OpenNext(),
                ActionKind.Play or ActionKind.Pause or ActionKind.TogglePlayback or ActionKind.PreviousTrack or ActionKind.NextTrack
                    => await media.Playback(action.Kind),
                ActionKind.VolumeUp or ActionKind.VolumeDown or ActionKind.ToggleMute or ActionKind.SetVolume
                    => await Task.Run(() => media.VolumeForCurrent(action)),
                ActionKind.SwitchHost => await switcher.Switch(action.Host, action.DisplayOnly),
                ActionKind.SwitchOtherHost => await switcher.Switch(null, displayOnly: false),
                ActionKind.PlayDailyRecommendations => await PlayDaily(viaXiaoAI, xiaoAITest),
                ActionKind.PlaySong => await songAgent.Play(action, new Progress<string>(message => ActionStatus.Text = message)),
                _ => ActionResult.Unavailable("当前动作不可用。")
            };
            if (action.Kind is ActionKind.OpenPlayer or ActionKind.NextPlayer or ActionKind.PlayDailyRecommendations or ActionKind.PlaySong)
            {
                RefreshPlayers();
                Persist();
            }
            if (action.Kind is ActionKind.SwitchHost or ActionKind.SwitchOtherHost)
            {
                VideoStatus.Text = switcher.VideoStatus;
                HubStatus.Text = switcher.HubStatus;
            }
            ReportResult(result);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Win32Exception or
                                          InvalidOperationException or COMException or ArgumentException)
        {
            ReportResult(ActionResult.Failed(exception.Message));
        }
        finally
        {
            actionGate.Release();
            UpdateOverview();
        }
    }

    private async Task<ActionResult> PlayDaily(bool withXiaoAI, bool test)
    {
        if (media.CurrentPlayer is not { } player || MediaService.ServiceId(player) != "netease")
            return ActionResult.Unavailable("每日推荐需要先在播放器列表中选择网易云音乐。");
        var revision = settings.PlayerSelectionRevision;
        if (withXiaoAI)
        {
            XiaoAIStatus.Text = "等待小爱和巴法回传…";
            var bridge = await XiaoAIWindows.Request(settings.XiaoAI);
            XiaoAIStatus.Text = bridge.Message;
            if (!bridge.Submitted && test) return bridge;
        }
        if (revision != settings.PlayerSelectionRevision)
            return ActionResult.Unavailable("播放器选择已变更，本次每日推荐操作已取消。");
        return await recommendations.Play();
    }

    private void BrowseXiaoAIPython(object sender, RoutedEventArgs args)
    {
        if (ChooseFile("Python 3|python.exe") is { } chosen) XiaoAIPython.Text = chosen;
    }

    private void SaveXiaoAI(object sender, RoutedEventArgs args)
    {
        var uid = BemfaSecret.Password.Trim();
        var token = HAToken.Password.Trim();
        if ((uid.Length > 0) != (token.Length > 0))
        {
            XiaoAIStatus.Text = "保存凭据时请同时填写 UID 和令牌。";
            return;
        }
        try
        {
            if (uid.Length > 0)
            {
                XiaoAIWindows.Save(uid, token);
                BemfaSecret.Clear();
                HAToken.Clear();
            }
            settings.XiaoAI = new XiaoAIOptions
            {
                Enabled = XiaoAIEnabled.IsChecked == true,
                HomeAssistantUrl = XiaoAIAddress.Text.Trim(), NotifyEntity = XiaoAIEntity.Text.Trim(),
                Topic = XiaoAITopic.Text.Trim(), Command = XiaoAICommand.Text.Trim(),
                IncludeSilentParameter = XiaoAISilent.IsChecked == true, PythonExecutable = XiaoAIPython.Text.Trim()
            };
            if (Persist()) XiaoAIStatus.Text = "已保存小爱设置。";
        }
        catch (Exception issue) when (issue is IOException or UnauthorizedAccessException or Win32Exception)
        {
            XiaoAIStatus.Text = "无法保存当前用户的小爱凭据。";
        }
    }

    private void ClearXiaoAI(object sender, RoutedEventArgs args)
    {
        try
        {
            XiaoAIWindows.Clear();
            BemfaSecret.Clear();
            HAToken.Clear();
            XiaoAIStatus.Text = "已清除本机的小爱凭据。";
        }
        catch (Exception issue) when (issue is IOException or UnauthorizedAccessException)
        {
            XiaoAIStatus.Text = "无法删除本机凭据。";
        }
    }

    private void TestXiaoAI(object sender, RoutedEventArgs args) =>
        _ = Dispatch(new ControllerAction(ActionKind.PlayDailyRecommendations), viaXiaoAI: true, xiaoAITest: true);

    private void ReportResult(ActionResult result)
    {
        var label = result.State switch
        {
            ResultState.Confirmed => "已确认", ResultState.Sent => "待确认", ResultState.Partial => "部分完成",
            ResultState.Unavailable => "不可用", _ => "失败"
        };
        ActionStatus.Text = $"{label} · {result.Message}";
        if (!IsVisible && tray is not null && result.State is ResultState.Failed or ResultState.Partial or ResultState.Unavailable)
            tray.ShowBalloonTip(3000, "Orvio", ActionStatus.Text, Forms.ToolTipIcon.Warning);
    }

    private void MusicAction(object sender, RoutedEventArgs args) =>
        _ = Dispatch(new ControllerAction(Enum.Parse<ActionKind>((string)((Button)sender).Tag)));

    private void MusicOptionsChanged(object sender, RoutedEventArgs args)
    {
        if (!ready) return;
        settings.PreferPlayerVolume = PlayerVolume.IsChecked == true;
        settings.RecordMusicDiagnostics = MusicTraceEnabled.IsChecked == true;
        Persist();
    }

    private void BrowseMusicOcr(object sender, RoutedEventArgs args)
    {
        if (ChooseFile("Tesseract|tesseract.exe") is not { } selected) return;
        settings.MusicOcrExecutable = selected;
        MusicOcrPath.Text = selected;
        Persist();
    }

    private void OpenMusicDiagnostics(object sender, RoutedEventArgs args)
    {
        try
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "T1Controller", "MusicDiagnostics");
            Directory.CreateDirectory(folder);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(folder) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception issue) when (issue is IOException or UnauthorizedAccessException or Win32Exception)
        {
            ReportResult(ActionResult.Failed(issue.Message));
        }
    }

    private void RefreshPlayers()
    {
        updatingPlayers = true;
        PlayerBox.ItemsSource = settings.Players.ToArray();
        PlayerBox.SelectedItem = settings.Players.FirstOrDefault(player => player.Id == settings.CurrentPlayer);
        LoadPlayerFields();
        updatingPlayers = false;
    }

    private void PlayerSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!ready || updatingPlayers || PlayerBox.SelectedItem is not Player player)
            return;
        settings.CurrentPlayer = player.Id;
        LoadPlayerFields();
        Persist();
        UpdateOverview();
    }

    private void LoadPlayerFields()
    {
        var player = PlayerBox.SelectedItem as Player;
        PlayerName.Text = player?.Name ?? "";
        PlayerExe.Text = player?.Executable ?? "";
        PlayerSession.Text = player?.SessionId ?? "";
        AppPlayPause.Text = player?.PlayPauseHotkey ?? "";
        AppPrevious.Text = player?.PreviousHotkey ?? "";
        AppNext.Text = player?.NextHotkey ?? "";
    }

    private void BrowsePlayer(object sender, RoutedEventArgs args)
    {
        if (ChooseFile("应用程序 (*.exe)|*.exe") is { } path)
            PlayerExe.Text = path;
    }

    private async void RefreshSessions(object sender, RoutedEventArgs args)
    {
        try
        {
            var value = PlayerSession.Text;
            PlayerSession.ItemsSource = await media.ListSessions();
            PlayerSession.Text = value;
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException)
        {
            ActionStatus.Text = $"无法读取媒体会话。{exception.Message}";
        }
    }

    private void SavePlayer(object sender, RoutedEventArgs args)
    {
        if (PlayerBox.SelectedItem is not Player player)
            return;
        if (string.IsNullOrWhiteSpace(PlayerName.Text) || !ValidOptionalChord(AppPlayPause.Text) ||
            !ValidOptionalChord(AppPrevious.Text) || !ValidOptionalChord(AppNext.Text))
        {
            ActionStatus.Text = "请填写播放器名称和有效的应用快捷键。";
            return;
        }
        player.Name = PlayerName.Text.Trim();
        player.Executable = PlayerExe.Text.Trim();
        player.SessionId = PlayerSession.Text.Trim();
        player.PlayPauseHotkey = AppPlayPause.Text.Trim();
        player.PreviousHotkey = AppPrevious.Text.Trim();
        player.NextHotkey = AppNext.Text.Trim();
        RefreshPlayers();
        UpdateOverview();
        if (Persist())
            ActionStatus.Text = "已保存播放器。";
    }

    private void AddPlayer(object sender, RoutedEventArgs args)
    {
        if (ChooseFile("应用程序 (*.exe)|*.exe") is not { } path)
            return;
        var player = new Player { Id = Guid.NewGuid().ToString("N"), Name = Path.GetFileNameWithoutExtension(path), Executable = path };
        settings.Players.Add(player);
        settings.CurrentPlayer = player.Id;
        RefreshPlayers();
        UpdateOverview();
        Persist();
    }

    private void RemovePlayer(object sender, RoutedEventArgs args)
    {
        if (PlayerBox.SelectedItem is not Player player || player.Id == "netease")
        {
            ActionStatus.Text = "网易云音乐是内置播放器选项，可以更新其路径。";
            return;
        }
        settings.Players.Remove(player);
        settings.CurrentPlayer = settings.Players.FirstOrDefault()?.Id ?? "netease";
        RefreshPlayers();
        UpdateOverview();
        Persist();
    }

    private async Task LoadDisplays()
    {
        try
        {
            var id = (MonitorBox.SelectedItem as DisplayTarget)?.Id ?? settings.MonitorId;
            var inventory = await Task.Run(displays.Enumerate);
            MonitorBox.ItemsSource = inventory.Targets;
            MonitorBox.SelectedItem = inventory.Targets.FirstOrDefault(monitor =>
                    string.Equals(monitor.Id, id, StringComparison.OrdinalIgnoreCase)) ??
                (id is null && inventory.Diagnostic is null && inventory.Targets.Count == 1 ? inventory.Targets[0] : null);
            VideoStatus.Text = inventory.Diagnostic ?? (inventory.Targets.Count == 0
                ? "当前没有可单独寻址的外接显示器。"
                : "请选择共享显示器并读取当前输入。");
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            VideoStatus.Text = exception.Message;
        }
    }

    private async void RefreshMonitors(object sender, RoutedEventArgs args) => await LoadDisplays();

    private async void ReadMonitorInput(object sender, RoutedEventArgs args)
    {
        if (MonitorBox.SelectedItem is not DisplayTarget monitor)
        {
            VideoStatus.Text = "请先选择共用显示器。";
            return;
        }
        try
        {
            VideoStatus.Text = $"当前输入 0x{await Task.Run(() => displays.Read(monitor.Id)):X2}。";
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            VideoStatus.Text = exception.Message;
        }
    }

    private void SaveSwitch(object sender, RoutedEventArgs args)
    {
        if (switcher.IsBusy)
            return;
        if (MonitorBox.SelectedItem is not DisplayTarget monitor || !ParseInput(WindowsInput.Text, out var windows) ||
            !ParseInput(MacInput.Text, out var mac) || windows == mac)
        {
            ActionStatus.Text = "请选择显示器并填写两个不同的输入代码。";
            return;
        }
        if (!ValidOptionalChord(HubHotkey.Text) || SameChord(HubHotkey.Text, settings.PlayPauseHotkey) ||
            SameChord(HubHotkey.Text, settings.SwitchHostHotkey) ||
            ConflictsWithPreset(HubHotkey.Text, settings.ActionHotkeysEnabled, settings.VoiceHotkeyEnabled, settings.ModeHotkeysEnabled))
        {
            ActionStatus.Text = "KMFU 快捷键需为可识别且未被本工具占用的组合。";
            return;
        }
        var marker = (HubDeviceBox.SelectedItem as MarkerChoice)?.Path;
        var output = (HubOutputBox.SelectedItem as MarkerChoice)?.Path;
        if (marker?.Contains("VID_1A86&PID_8022", StringComparison.OrdinalIgnoreCase) == true)
        {
            ActionStatus.Text = "请选择实测随端口交接的独立设备作为归属标记。";
            return;
        }
        settings.MonitorId = monitor.Id;
        settings.WindowsInput = windows;
        settings.MacInput = mac;
        settings.ToggleWithPeripherals = ToggleWithPeripherals.IsChecked == true;
        settings.HubHotkey = HubHotkey.Text.Trim();
        if (settings.HubOwnerDevicePath != marker || settings.HubOwnerOutputId != output)
        {
            settings.HubHandoffPending = false;
            settings.HubDepartureObserved = false;
        }
        settings.HubOwnerDevicePath = marker;
        settings.HubOwnerOutputId = output;
        if (Persist())
            ActionStatus.Text = "已保存输入代码和 KMFU 设置，可分别测试画面与外设。";
    }

    private void SwitchHost(object sender, RoutedEventArgs args) => DispatchHost(sender, displayOnly: false);
    private void DisplayOnly(object sender, RoutedEventArgs args) => DispatchHost(sender, displayOnly: true);
    private void DispatchHost(object sender, bool displayOnly) =>
        _ = Dispatch(new ControllerAction(ActionKind.SwitchHost, Host: Enum.Parse<Host>((string)((Button)sender).Tag), DisplayOnly: displayOnly));

    private async void HubOnly(object sender, RoutedEventArgs args)
    {
        try
        {
            var result = await switcher.Handoff(Host.Mac);
            HubStatus.Text = switcher.HubStatus;
            ReportResult(result);
        }
        catch (Exception exception) when (exception is COMException or IOException or UnauthorizedAccessException)
        {
            ReportResult(ActionResult.Failed(exception.Message));
        }
    }

    private void ConfirmHubOwner(object sender, RoutedEventArgs args)
    {
        if (switcher.IsBusy)
            return;
        try
        {
            if (settings.HubOwnerDevicePath is not { } receiver || settings.HubOwnerOutputId is not { } speaker ||
                !RawInput.IsPresent(receiver) || !MediaService.ListOutputDevices().Any(device => device.Id == speaker))
            {
                HubStatus.Text = "Windows 当前没有同时枚举到已保存的接收器和共享音响。";
                return;
            }
            settings.HubHandoffPending = false;
            settings.HubDepartureObserved = false;
            if (Persist())
                HubStatus.Text = "已记录 Windows 当前持有全部外设。";
        }
        catch (COMException exception)
        {
            HubStatus.Text = exception.Message;
        }
    }

    private void RefreshOutputs(object sender, RoutedEventArgs args) => LoadOutputs();

    private void LoadOutputs()
    {
        try
        {
            var selected = (HubOutputBox.SelectedItem as MarkerChoice)?.Path ?? settings.HubOwnerOutputId;
            var outputs = MediaService.ListOutputDevices().Select(device => new MarkerChoice(device.Id, device.Name)).ToList();
            if (selected is { } existing && outputs.All(output => output.Path != existing))
                outputs.Add(new MarkerChoice(existing, "已保存的音响 · 当前未连接"));
            outputs.Insert(0, new MarkerChoice(null, "手动交接"));
            HubOutputBox.ItemsSource = outputs;
            HubOutputBox.SelectedItem = outputs.First(output => output.Path == selected);
        }
        catch (COMException exception)
        {
            HubStatus.Text = exception.Message;
        }
    }

    private void LoadMicrophones()
    {
        try
        {
            var microphones = new[] { new Microphone("", "系统默认录音输入") }.Concat(VoiceService.ListMicrophones()).ToList();
            if (settings.MicrophoneId is { Length: > 0 } missing && microphones.All(mic => mic.Id != missing))
                microphones.Add(new Microphone(missing, "已保存的麦克风 · 当前未连接"));
            MicrophoneBox.ItemsSource = microphones;
            MicrophoneBox.SelectedItem = microphones.FirstOrDefault(mic => mic.Id == settings.MicrophoneId) ?? microphones[0];
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException)
        {
            VoiceStatus.Text = $"无法枚举麦克风。{exception.Message}";
        }
    }

    private void RefreshMicrophones(object sender, RoutedEventArgs args) => LoadMicrophones();
    private void BrowseWhisper(object sender, RoutedEventArgs args)
    {
        if (ChooseFile("应用程序 (*.exe)|*.exe") is { } path)
            WhisperExe.Text = path;
    }

    private void BrowseModel(object sender, RoutedEventArgs args)
    {
        if (ChooseFile("模型 (*.bin)|*.bin") is { } path)
            WhisperModel.Text = path;
    }

    private void SaveVoice(object sender, RoutedEventArgs args)
    {
        settings.MicrophoneId = (MicrophoneBox.SelectedItem as Microphone)?.Id;
        settings.WhisperExecutable = WhisperExe.Text;
        settings.WhisperModel = WhisperModel.Text;
        if (Persist())
            VoiceStatus.Text = voice.FindRecognizer() is null ? "已保存。还需配置本地语音程序和模型。" : "已保存，本地中文识别可用。";
        UpdateOverview();
    }

    private void VoiceDown(object sender, MouseButtonEventArgs args)
    {
        var button = (Button)sender;
        button.Focus();
        if (!button.CaptureMouse())
            return;
        StartVoiceButton(button);
        args.Handled = true;
    }

    private void VoiceUp(object sender, MouseButtonEventArgs args)
    {
        var button = (Button)sender;
        StopVoiceButton(button, cancel: !button.IsMouseOver);
        button.ReleaseMouseCapture();
        args.Handled = true;
    }

    private void VoiceLostCapture(object sender, MouseEventArgs args) => StopVoiceButton((Button)sender, cancel: true);
    private void VoiceLostFocus(object sender, KeyboardFocusChangedEventArgs args) => StopVoiceButton((Button)sender, cancel: true);

    private void VoiceKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key is Key.Space or Key.Enter)
        {
            if (!args.IsRepeat)
                StartVoiceButton((Button)sender);
            args.Handled = true;
        }
    }

    private void VoiceKeyUp(object sender, KeyEventArgs args)
    {
        if (args.Key is Key.Space or Key.Enter)
        {
            StopVoiceButton((Button)sender, cancel: false);
            args.Handled = true;
        }
    }

    private void StartVoiceButton(Button button)
    {
        if (voiceButton is not null || voice.Owner is not null)
            return;
        voiceButton = (string)button.Tag;
        voice.Start(voiceButton, probe: voiceButton == "probe");
    }

    private void StopVoiceButton(Button button, bool cancel)
    {
        if (voiceButton is not { } owner || !Equals(owner, button.Tag))
            return;
        voiceButton = null;
        _ = voice.Finish(owner, cancel);
    }

    private void RunTextCommand(object sender, RoutedEventArgs args) => _ = ExecuteText(TextCommand.Text);

    private async Task DeliverVoiceText(string text, bool dictation, NativeTextTarget? target, long revision)
    {
        if (revision != voiceDeliveryRevision) return;
        if (!dictation) { await ExecuteText(text); return; }
        var result = target is null ? ActionResult.Unavailable("已转写；请先把光标放进可编辑文本框，文字保留在语音页。") :
            await target.Insert(text, () => revision == voiceDeliveryRevision && settings.RemoteMode == RemoteMode.Native);
        if (revision == voiceDeliveryRevision) { VoiceStatus.Text = result.Message; ActionStatus.Text = result.Message; }
    }

    private async Task ExecuteText(string text)
    {
        if (IntentParser.Parse(text) is { } action)
        {
            var command = text.TrimStart();
            var callsXiaoAI = action.Kind == ActionKind.PlayDailyRecommendations && settings.XiaoAI.Enabled &&
                (command.StartsWith("小爱同学", StringComparison.Ordinal) || command.StartsWith("小愛同學", StringComparison.Ordinal));
            await Dispatch(action, viaXiaoAI: callsXiaoAI);
        }
        else
            ActionStatus.Text = "无法确定指令。可以说「下一首」「音量调到 35%」或「切到 Mac」。";
    }

    private string? ChooseFile(string filter)
    {
        var dialog = new OpenFileDialog { Filter = filter, CheckFileExists = true };
        return dialog.ShowDialog(this) == true ? dialog.FileName : null;
    }

    private static string FormatInput(uint? input) => input is uint code ? $"0x{code:X2}" : "";

    private static bool ParseInput(string value, out uint code)
    {
        value = value.Trim();
        return (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? uint.TryParse(value.AsSpan(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code)
            : uint.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out code)) && code <= byte.MaxValue;
    }

    private static bool ValidOptionalChord(string? text) =>
        string.IsNullOrWhiteSpace(text) || KeyChord.TryParse(text, out _);

    private static bool SameChord(string? left, string? right) =>
        KeyChord.TryParse(left, out var first) && KeyChord.TryParse(right, out var second) && first == second;

    private bool Persist()
    {
        try
        {
            settings.Save();
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ActionStatus.Text = $"无法保存设置。{exception.Message}";
            return false;
        }
    }

    private void UpdateOverview()
    {
        var remote = DeviceBox.SelectedItem is RawDevice ? "已选设备" : "等待配置飞鼠";
        var player = media.CurrentPlayer?.Name ?? "未选播放器";
        var mic = (MicrophoneBox.ItemsSource as IEnumerable<Microphone>)?.FirstOrDefault(item =>
            item.Id == (settings.MicrophoneId ?? ""))?.Name ?? "系统默认输入";
        Overview.Text = $"Windows · {remote} · {player} · {mic}";
        DeviceOverview.UpdateSummary(settings.Bindings, settings.RemoteMode, settings.Remapping, settings.MediaMode, player);
    }
}
