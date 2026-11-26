using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using Windows.Media.Control;

namespace T1Controller;

internal sealed class MediaService(Settings settings)
{
    private GlobalSystemMediaTransportControlsSessionManager? manager;

    public async Task<IReadOnlyList<string>> ListSessions() =>
        (await Sessions()).Select(session => session.SourceAppUserModelId).Distinct().Order().ToArray();

    private async Task<IReadOnlyList<GlobalSystemMediaTransportControlsSession>> Sessions()
    {
        manager ??= await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        return manager.GetSessions();
    }

    public async Task<GlobalSystemMediaTransportControlsSession?> FindSession(Player player)
    {
        var all = await Sessions();
        var match = string.IsNullOrWhiteSpace(player.SessionId) ? DefaultSessionId(player) : player.SessionId;
        if (string.IsNullOrWhiteSpace(match))
            return null;
        var found = all.Where(session => string.Equals(session.SourceAppUserModelId, match, StringComparison.OrdinalIgnoreCase))
            .ToArray();
        return found.Length == 1 ? found[0] : null;
    }

    public Player? CurrentPlayer => settings.Players.FirstOrDefault(player => player.Id == settings.CurrentPlayer);

    internal static string? ServiceId(Player player)
    {
        if (player.Id is "netease" or "soda") return player.Id;
        return MusicLayout.Normalize(player.Name) switch
        {
            "网易云音乐" or "网易云" or "neteasecloudmusic" => "netease",
            "汽水音乐" or "sodamusic" => "soda",
            _ => (Path.GetFileNameWithoutExtension(player.Executable) ?? "").ToLowerInvariant() switch
            {
                "cloudmusic" => "netease",
                "sodamusic" or "汽水音乐" => "soda",
                _ => null
            }
        };
    }

    internal Player? SongPlayer(string? explicitService)
    {
        if (explicitService is null) return CurrentPlayer;
        var configured = settings.Players.Where(player => ServiceId(player) == explicitService && ResolveExecutable(player) is not null)
            .ToArray();
        if (configured.Length > 1)
            return configured.FirstOrDefault(player => player.Id == settings.CurrentPlayer);
        if (configured.Length == 1) return configured[0];
        var discovered = new Player { Id = explicitService, Name = explicitService == "soda" ? "汽水音乐" : "网易云音乐" };
        var executable = ResolveExecutable(discovered);
        if (executable is null) return null;
        discovered.Executable = executable;
        return discovered;
    }

    internal void Remember(Player player)
    {
        if (settings.Players.All(existing => existing.Id != player.Id))
            settings.Players.Add(player);
        settings.CurrentPlayer = player.Id;
    }

    public ActionResult OpenNext()
    {
        var players = settings.Players.Where(player => ResolveExecutable(player) is not null).ToArray();
        if (players.Length == 0)
            return ActionResult.Unavailable("请先在播放器设置中选择已安装应用的 exe。");
        var index = Array.FindIndex(players, player => player.Id == settings.CurrentPlayer);
        return Open(players[(index + 1) % players.Length].Id);
    }

    public ActionResult Open(string id)
    {
        var player = settings.Players.FirstOrDefault(player => player.Id == id);
        if (player is null && id == "soda") player = SongPlayer(id);
        if (player is null)
            return ActionResult.Unavailable("所选播放器尚未配置。");
        var path = ResolveExecutable(player);
        if (path is null)
            return ActionResult.Unavailable($"找不到 {player.Name}。请在设置中选择应用的 exe。");
        var window = FindPlayerWindow(path);
        var active = TryActivate(window);
        if (window == IntPtr.Zero)
        {
            using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        Remember(player);
        return new(active ? ResultState.Confirmed : ResultState.Sent,
            active ? $"已切换到 {player.Name}。" : $"已请求打开 {player.Name}。");
    }

    public async Task<ActionResult> Playback(ActionKind kind)
    {
        var player = CurrentPlayer;
        if (player is null)
            return ActionResult.Unavailable("请先选择播放器。");
        var revision = settings.PlayerSelectionRevision;
        bool IsCurrent() => settings.PlayerSelectionRevision == revision && settings.CurrentPlayer == player.Id;
        GlobalSystemMediaTransportControlsSession? session = null;
        try
        {
            session = await FindSession(player);
        }
        catch (COMException)
        {
            // A disabled media session service still permits configured keyboard shortcuts.
        }
        if (!IsCurrent()) return ActionResult.Unavailable("播放器选择已变更，本次操作已取消。");
        if (session is not null)
        {
            var result = await ControlSession(session, kind, IsCurrent);
            if (result.Submitted)
                return result;
        }

        var fallback = kind switch
        {
            ActionKind.TogglePlayback => player.PlayPauseHotkey,
            ActionKind.PreviousTrack => player.PreviousHotkey,
            ActionKind.NextTrack => player.NextHotkey,
            _ => null
        };
        if (!IsCurrent()) return ActionResult.Unavailable("播放器选择已变更，本次操作已取消。");
        if (KeyChord.TryParse(fallback, out var chord) && ResolveExecutable(player) is { } path &&
            chord.VirtualKey is not (>= 0xB0 and <= 0xB7) &&
            TryActivate(FindPlayerWindow(path)))
        {
            return Keyboard.Send(chord)
                ? new(ResultState.Sent, $"已向 {player.Name} 发送快捷键，播放状态待确认。")
                : ActionResult.Failed($"无法向 {player.Name} 发送快捷键。");
        }

        return ActionResult.Unavailable($"未找到 {player.Name} 可用的播放操作。请先在播放器中播放，再核对会话 ID。");
    }

    private static async Task<ActionResult> ControlSession(GlobalSystemMediaTransportControlsSession session, ActionKind kind,
        Func<bool> isCurrent)
    {
        var state = session.GetPlaybackInfo();
        var status = state.PlaybackStatus;
        var playing = status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        var controls = state.Controls;
        if ((kind == ActionKind.Play && playing) ||
            (kind == ActionKind.Pause && status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused))
            return new(ResultState.Confirmed, playing ? "当前播放器正在播放。" : "当前播放器已暂停。");

        var isTrackAction = kind is ActionKind.PreviousTrack or ActionKind.NextTrack;
        var beforeTrack = isTrackAction ? await TrackName(session) : null;
        if (!isCurrent()) return ActionResult.Unavailable("播放器选择已变更，本次操作已取消。");
        var accepted = kind switch
        {
            ActionKind.Play when controls.IsPlayEnabled => await session.TryPlayAsync(),
            ActionKind.Pause when controls.IsPauseEnabled => await session.TryPauseAsync(),
            ActionKind.TogglePlayback when controls.IsPlayPauseToggleEnabled => await session.TryTogglePlayPauseAsync(),
            ActionKind.TogglePlayback when playing && controls.IsPauseEnabled => await session.TryPauseAsync(),
            ActionKind.TogglePlayback when !playing && controls.IsPlayEnabled => await session.TryPlayAsync(),
            ActionKind.PreviousTrack when controls.IsPreviousEnabled => await session.TrySkipPreviousAsync(),
            ActionKind.NextTrack when controls.IsNextEnabled => await session.TrySkipNextAsync(),
            _ => false
        };
        if (!accepted)
            return ActionResult.Unavailable("播放器没有接受该操作。");
        if (isTrackAction && beforeTrack is not null)
        {
            for (var attempt = 0; attempt < 4; attempt++)
            {
                await Task.Delay(160);
                var after = await TrackName(session);
                if (after is not null && after != beforeTrack)
                    return new(ResultState.Confirmed, $"已切歌 · {after}");
            }
        }
        if (kind is ActionKind.Play or ActionKind.Pause or ActionKind.TogglePlayback)
        {
            var expected = kind == ActionKind.Play || (kind == ActionKind.TogglePlayback && !playing)
                ? GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing
                : GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused;
            for (var attempt = 0; attempt < 5; attempt++)
            {
                if (session.GetPlaybackInfo().PlaybackStatus == expected)
                    return new(ResultState.Confirmed, expected == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing
                        ? "已播放。" : "已暂停。");
                await Task.Delay(100);
            }
        }
        return new(ResultState.Sent, "目标播放器已接受操作，结果待确认。");
    }

    private static async Task<string?> TrackName(GlobalSystemMediaTransportControlsSession session)
    {
        try
        {
            var properties = await session.TryGetMediaPropertiesAsync();
            return string.IsNullOrWhiteSpace(properties?.Title) ? null : $"{properties.Title} · {properties.Artist}";
        }
        catch (COMException)
        {
            return null;
        }
    }

    public static ActionResult Volume(ControllerAction action)
    {
        using var enumerator = new MMDeviceEnumerator();
        using var output = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        var volume = output.AudioEndpointVolume;
        if (action.Kind == ActionKind.ToggleMute)
        {
            var muted = !volume.Mute;
            volume.Mute = muted;
            if (volume.Mute != muted) return ActionResult.Unavailable("系统未确认静音状态。请检查当前输出设备。");
            return new(ResultState.Confirmed, $"{output.FriendlyName} · {(volume.Mute ? "已静音" : "已取消静音")}。");
        }

        var target = action.Kind switch
        {
            ActionKind.VolumeUp => volume.MasterVolumeLevelScalar + .05f,
            ActionKind.VolumeDown => volume.MasterVolumeLevelScalar - .05f,
            _ => (action.Volume ?? 0) / 100f
        };
        volume.MasterVolumeLevelScalar = Math.Clamp(target, 0, 1);
        return new(ResultState.Confirmed, $"{output.FriendlyName} · 音量 {Math.Round(volume.MasterVolumeLevelScalar * 100)}%。");
    }

    internal ActionResult VolumeForCurrent(ControllerAction action)
    {
        if (!settings.PreferPlayerVolume)
            return Volume(action);
        if (CurrentPlayer is not { } player || ResolveExecutable(player) is not { } path)
            return ActionResult.Unavailable("请先选择要调音量的播放器。");
        var revision = settings.PlayerSelectionRevision;
        var candidates = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(path));
        var owned = new HashSet<uint>();
        foreach (var process in candidates)
        {
            using (process)
            {
                try
                {
                    if (string.Equals(process.MainModule?.FileName, path, StringComparison.OrdinalIgnoreCase))
                        owned.Add((uint)process.Id);
                }
                catch (Exception failure) when (failure is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException) { }
            }
        }
        var parents = ProcessTree.Parents();
        using var enumerator = new MMDeviceEnumerator();
        var endpoints = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active).ToArray();
        var targets = new List<AudioSessionControl>();
        try
        {
            foreach (var endpoint in endpoints)
            {
                var sessions = endpoint.AudioSessionManager.Sessions;
                for (var index = 0; index < sessions.Count; index++)
                {
                    var session = sessions[index];
                    if (!session.IsSystemSoundsSession && AudioMutePolicy.BelongsToPlayer(session.GetProcessID, owned, parents))
                        targets.Add(session);
                    else session.Dispose();
                }
            }
            if (targets.Count == 0)
                return ActionResult.Unavailable($"未找到 {player.Name} 的音频会话，请先播放音乐。");
            var muteTarget = AudioMutePolicy.Target(targets.Select(session => session.SimpleAudioVolume.Mute));
            var levels = new List<float>();
            foreach (var session in targets)
            {
                if (revision != settings.PlayerSelectionRevision || settings.CurrentPlayer != player.Id)
                    return ActionResult.Unavailable("播放器选择已变更，本次音量操作已停止。");
                var volume = session.SimpleAudioVolume;
                if (action.Kind == ActionKind.ToggleMute)
                {
                    volume.Mute = muteTarget;
                    if (volume.Mute != muteTarget)
                        return ActionResult.Unavailable($"{player.Name} 的音频会话未确认静音状态。");
                }
                else
                {
                    var target = action.Kind switch
                    {
                        ActionKind.VolumeUp => volume.Volume + .05f,
                        ActionKind.VolumeDown => volume.Volume - .05f,
                        _ => (action.Volume ?? 0) / 100f
                    };
                    volume.Volume = Math.Clamp(target, 0, 1);
                }
                levels.Add(volume.Volume);
            }
            return new(ResultState.Confirmed, action.Kind == ActionKind.ToggleMute
                ? $"{player.Name} · {(muteTarget ? "已静音" : "已取消静音")}（{targets.Count} 个音频会话）。"
                : $"{player.Name} · 应用音量 {Math.Round(levels.Average() * 100)}%。");
        }
        finally
        {
            foreach (var session in targets) session.Dispose();
            foreach (var endpoint in endpoints) endpoint.Dispose();
        }
    }

    private static string DefaultSessionId(Player player) =>
        ServiceId(player) == "netease" ? "cloudmusic.exe" : Path.GetFileName(player.Executable);

    internal static string? ResolveExecutable(Player player)
    {
        if (IsExecutable(player.Executable))
            return Path.GetFullPath(player.Executable);
        var service = ServiceId(player);
        if (service is null) return null;

        var roots = new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86,
            Environment.SpecialFolder.LocalApplicationData };
        var candidates = roots.Select(Environment.GetFolderPath).Where(root => root.Length > 0)
            .SelectMany(root => service == "netease"
                ? new[] { Path.Combine(root, "NetEase", "CloudMusic", "cloudmusic.exe"),
                    Path.Combine(root, "Programs", "NetEase", "CloudMusic", "cloudmusic.exe") }
                : new[] { Path.Combine(root, "SodaMusic", "SodaMusic.exe"),
                    Path.Combine(root, "Programs", "SodaMusic", "SodaMusic.exe") });
        return candidates.FirstOrDefault(IsExecutable) ?? FindPlayerInRegistry(service);
    }

    private static string? FindPlayerInRegistry(string service)
    {
        const string uninstall = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
        foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var key = RegistryKey.OpenBaseKey(hive, view);
            using var apps = key.OpenSubKey(uninstall);
            if (apps is null)
                continue;
            foreach (var name in apps.GetSubKeyNames())
            {
                using var app = apps.OpenSubKey(name);
                var displayName = app?.GetValue("DisplayName") as string;
                if (displayName is null || !displayName.Contains(service == "netease" ? "网易云音乐" : "汽水音乐",
                    StringComparison.OrdinalIgnoreCase))
                    continue;
                if (app?.GetValue("InstallLocation") is string folder)
                {
                    foreach (var file in ExecutableNames(service))
                    {
                        var candidate = Path.Combine(folder, file);
                        if (IsExecutable(candidate)) return candidate;
                    }
                }
                if (app?.GetValue("DisplayIcon") is string icon)
                {
                    var candidate = icon.Split(',')[0].Trim().Trim('"');
                    if (IsExecutable(candidate) && ExecutableNames(service).Contains(Path.GetFileName(candidate),
                            StringComparer.OrdinalIgnoreCase))
                        return candidate;
                }
            }
        }
        return null;
    }

    private static string[] ExecutableNames(string service) =>
        service == "netease" ? ["cloudmusic.exe"] : ["SodaMusic.exe", "汽水音乐.exe"];

    private static bool IsExecutable(string? path) =>
        !string.IsNullOrWhiteSpace(path) && Path.IsPathFullyQualified(path) &&
        string.Equals(Path.GetExtension(path), ".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(path);

    internal static IntPtr FindPlayerWindow(string executable)
    {
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(executable));
        try
        {
            foreach (var process in processes)
            {
                try
                {
                    if (process.MainWindowHandle != IntPtr.Zero &&
                        string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase))
                        return process.MainWindowHandle;
                }
                catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
                {
                    // The process can exit between enumeration and inspection.
                }
            }
            return IntPtr.Zero;
        }
        finally
        {
            foreach (var process in processes)
                process.Dispose();
        }
    }

    internal static (string Id, string Name)[] ListOutputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active).Select(device =>
        {
            using (device)
                return (device.ID, device.FriendlyName);
        }).ToArray();
    }

    internal static bool TryActivate(IntPtr handle)
    {
        if (handle == IntPtr.Zero)
            return false;
        if (IsIconic(handle))
            ShowWindow(handle, 9);
        return SetForegroundWindow(handle);
    }

    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);
}
