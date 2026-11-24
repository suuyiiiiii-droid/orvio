using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace T1Controller;

internal enum ActionKind
{
    Play, Pause, TogglePlayback, PreviousTrack, NextTrack,
    VolumeUp, VolumeDown, SetVolume, ToggleMute, NextPlayer,
    OpenPlayer, SwitchHost, SwitchOtherHost, PlayDailyRecommendations, PlaySong
}

internal enum Host { Windows, Mac }

internal readonly record struct ControllerAction(ActionKind Kind, string? Player = null, Host? Host = null,
    int? Volume = null, bool DisplayOnly = false, string? Title = null, string? Artist = null);

internal enum ResultState { Confirmed, Sent, Partial, Unavailable, Failed }

internal sealed record ActionResult(ResultState State, string Message)
{
    public bool Submitted => State is ResultState.Confirmed or ResultState.Sent;
    public static ActionResult Unavailable(string message) => new(ResultState.Unavailable, message);
    public static ActionResult Failed(string message) => new(ResultState.Failed, message);
}

internal enum ButtonRole
{
    Menu, PlayPause, PreviousTrack, NextTrack, VolumeUp, VolumeDown, Mute, Voice, CycleMode, SwitchHost
}

internal enum RemoteMode { Native, Media, Host }

internal sealed record ButtonBinding(string DevicePath, string Control, ButtonRole Role, bool Enabled = true);

internal sealed class Player
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Executable { get; set; } = "";
    public string SessionId { get; set; } = "";
    public string? PlayPauseHotkey { get; set; }
    public string? PreviousHotkey { get; set; }
    public string? NextHotkey { get; set; }
}

internal sealed class Settings
{
    public int Version { get; set; } = 1;
    public bool SetupGuideSeen { get; set; }
    public List<ButtonBinding> Bindings { get; set; } = [];
    public List<Player> Players { get; set; } = [new() { Id = "netease", Name = "网易云音乐" }];
    private string currentPlayer = "netease";
    public string CurrentPlayer
    {
        get => currentPlayer;
        set
        {
            if (currentPlayer == value) return;
            currentPlayer = value;
            PlayerSelectionRevision++;
        }
    }
    [JsonIgnore] public long PlayerSelectionRevision { get; private set; }
    public bool Remapping { get; set; }
    public bool MediaMode { get; set; }
    public RemoteMode? RemoteMode { get; set; }
    public bool PreferPlayerVolume { get; set; }
    public bool RecordMusicDiagnostics { get; set; }
    public string? MusicOcrExecutable { get; set; }
    public string? MonitorId { get; set; }
    public uint? WindowsInput { get; set; }
    public uint? MacInput { get; set; }
    public bool? ToggleWithPeripherals { get; set; }
    public string? HubHotkey { get; set; }
    public string? HubOwnerDevicePath { get; set; }
    public string? HubOwnerOutputId { get; set; }
    public bool HubHandoffPending { get; set; }
    public bool HubDepartureObserved { get; set; }
    public string? PlayPauseHotkey { get; set; }
    public string? SwitchHostHotkey { get; set; }
    public bool ActionHotkeysEnabled { get; set; }
    public bool ModeHotkeysEnabled { get; set; } = true;
    public bool VoiceHotkeyEnabled { get; set; }
    public string? MicrophoneId { get; set; }
    public string? WhisperExecutable { get; set; }
    public string? WhisperModel { get; set; }
    public XiaoAIOptions XiaoAI { get; set; } = new();

    [JsonIgnore]
    public bool SwitchWithPeripherals => ToggleWithPeripherals ??
        (!string.IsNullOrWhiteSpace(HubHotkey) && !string.IsNullOrWhiteSpace(HubOwnerDevicePath) &&
            !string.IsNullOrWhiteSpace(HubOwnerOutputId));

    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "T1Controller", "settings.json");
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) }
    };

    public static (Settings Value, string? Warning) Load()
    {
        try
        {
            if (!File.Exists(FilePath))
                return (new Settings { RemoteMode = T1Controller.RemoteMode.Native }, null);
            var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Options);
            return settings?.Version == 1 && settings.Players is not null && settings.Bindings is not null &&
                settings.Players.TrueForAll(player => player is not null && !string.IsNullOrWhiteSpace(player.Id)) &&
                settings.Bindings.TrueForAll(binding => binding is not null && !string.IsNullOrWhiteSpace(binding.DevicePath) &&
                    !string.IsNullOrWhiteSpace(binding.Control))
                ? (settings, null)
                : (new Settings(), "配置版本或字段无效。正在使用默认设置。");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return (new Settings(), "无法读取配置，正在使用默认设置。");
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = $"{FilePath}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, Options));
            File.Move(temporary, FilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }
}

internal sealed class XiaoAIOptions
{
    public bool Enabled { get; set; }
    public string HomeAssistantUrl { get; set; } = "";
    public string NotifyEntity { get; set; } = "";
    public string Topic { get; set; } = "t1music006";
    public string Command { get; set; } = "打开电脑音乐开关";
    public bool IncludeSilentParameter { get; set; } = true;
    public string PythonExecutable { get; set; } = "";
}
