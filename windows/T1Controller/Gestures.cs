using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace T1Controller;

internal enum Gesture { None, Press, Short, Long, Repeat }
internal enum VoiceInputDestination { System, Text, Command }

internal static class RemoteModes
{
    public static VoiceInputDestination VoiceDestination(RemoteMode? mode, bool systemNativeKey) =>
        mode == RemoteMode.Native ? systemNativeKey ? VoiceInputDestination.System : VoiceInputDestination.Text : VoiceInputDestination.Command;
    public static string Title(RemoteMode? mode) => mode switch
    {
        RemoteMode.Native => "原生", RemoteMode.Media => "媒体", RemoteMode.Host => "主机切换", _ => "现有映射"
    };

    public static RemoteMode Next(RemoteMode? mode) => mode switch
    {
        RemoteMode.Media => RemoteMode.Host,
        RemoteMode.Host => RemoteMode.Native,
        _ => RemoteMode.Media
    };

    public static bool Allows(ButtonRole role, RemoteMode? mode, bool legacyEnabled) =>
        role == ButtonRole.CycleMode || (role == ButtonRole.Voice && mode is not null) || mode switch
    {
        RemoteMode.Native => false,
        RemoteMode.Media => role != ButtonRole.SwitchHost,
        RemoteMode.Host => role == ButtonRole.SwitchHost,
        _ => legacyEnabled && role != ButtonRole.SwitchHost
    };

    public static bool Conflicts(ButtonRole first, ButtonRole second) =>
        first == ButtonRole.CycleMode || second == ButtonRole.CycleMode ||
        first == ButtonRole.Voice || second == ButtonRole.Voice ||
        (first == ButtonRole.SwitchHost) == (second == ButtonRole.SwitchHost);

    public static bool IsReturnKey(string control) => control.StartsWith("key:0D/", StringComparison.OrdinalIgnoreCase);

    public static bool RequiresExclusiveReturn(RemoteMode? mode) => mode is RemoteMode.Media or RemoteMode.Host;

    public static bool RequiresNativeIsolation(RemoteMode? mode, ButtonRole role) =>
        mode is RemoteMode.Media or RemoteMode.Host && Allows(role, mode, legacyEnabled: true);

    public static ActionKind? Resolve(ButtonRole role, Gesture gesture, RemoteMode? mode, bool legacyEnabled, bool legacyMedia)
    {
        if (!Allows(role, mode, legacyEnabled)) return null;
        return (role, gesture) switch
        {
            (ButtonRole.Menu, Gesture.Short) => ActionKind.NextPlayer,
            (ButtonRole.Menu, Gesture.Long) => mode is null ? ActionKind.SwitchOtherHost : ActionKind.NextPlayer,
            (ButtonRole.SwitchHost, Gesture.Short) => ActionKind.SwitchOtherHost,
            (ButtonRole.PlayPause, Gesture.Short) => ActionKind.TogglePlayback,
            (ButtonRole.PreviousTrack, Gesture.Short) when mode == RemoteMode.Media || legacyMedia => ActionKind.PreviousTrack,
            (ButtonRole.NextTrack, Gesture.Short) when mode == RemoteMode.Media || legacyMedia => ActionKind.NextTrack,
            (ButtonRole.VolumeUp, Gesture.Press or Gesture.Repeat) => ActionKind.VolumeUp,
            (ButtonRole.VolumeDown, Gesture.Press or Gesture.Repeat) => ActionKind.VolumeDown,
            (ButtonRole.Mute, Gesture.Short) => ActionKind.ToggleMute,
            _ => null
        };
    }
}

internal sealed class Gestures
{
    private readonly Dictionary<(string Device, string Control), (long Started, long Repeated)> down = [];

    public Gesture Observe(string device, string control, bool pressed, long time, bool allowRepeat, bool repeat = false)
    {
        var key = (device, control);
        if (pressed)
        {
            if (repeat && !down.ContainsKey(key)) return Gesture.None;
            if (down.TryAdd(key, (time, time)))
                return Gesture.Press;
            var existing = down[key];
            if (allowRepeat && Stopwatch.GetElapsedTime(existing.Repeated, time) >= TimeSpan.FromMilliseconds(100))
            {
                down[key] = (existing.Started, time);
                return Gesture.Repeat;
            }
            return Gesture.None;
        }
        if (!down.Remove(key, out var entry))
            return Gesture.None;
        var duration = Stopwatch.GetElapsedTime(entry.Started, time);
        if (duration < TimeSpan.Zero || duration >= TimeSpan.FromSeconds(15))
            return Gesture.None;
        return duration >= TimeSpan.FromMilliseconds(800) ? Gesture.Long : Gesture.Short;
    }

    public void Reset(string? device = null)
    {
        if (device is null)
            down.Clear();
        else
            foreach (var key in down.Keys.Where(key => key.Device == device).ToArray())
                down.Remove(key);
    }
}
