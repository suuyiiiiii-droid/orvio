using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Input;

namespace T1Controller;

internal readonly record struct KeyChord(uint Modifiers, ushort VirtualKey)
{
    private static readonly IReadOnlyDictionary<string, uint> Names = new Dictionary<string, uint>(StringComparer.OrdinalIgnoreCase)
    {
        ["Alt"] = 1, ["Ctrl"] = 2, ["Control"] = 2, ["Shift"] = 4, ["Win"] = 8, ["Windows"] = 8
    };

    public static bool TryParse(string? text, out KeyChord chord)
    {
        chord = default;
        if (string.IsNullOrWhiteSpace(text))
            return false;
        var parts = text.Split('+', StringSplitOptions.TrimEntries);
        uint modifiers = 0;
        foreach (var part in parts.SkipLast(1))
        {
            if (!Names.TryGetValue(part, out var bit) || (modifiers & bit) != 0)
                return false;
            modifiers |= bit;
        }
        var last = parts[^1];
        if (last.Length == 1 && last[0] is >= '0' and <= '9')
            last = "D" + last;
        if (!Enum.TryParse<Key>(last, true, out var key) || !Enum.IsDefined(key) ||
            key is Key.None or Key.LeftAlt or Key.RightAlt or Key.LeftCtrl or Key.RightCtrl or Key.LeftShift
                or Key.RightShift or Key.LWin or Key.RWin or Key.System or Key.ImeProcessed or Key.DeadCharProcessed)
            return false;
        var virtualKey = KeyInterop.VirtualKeyFromKey(key);
        if (virtualKey == 0)
            return false;
        chord = new KeyChord(modifiers, (ushort)virtualKey);
        return true;
    }
}

internal static class Keyboard
{
    public static bool IsDown(ushort key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public static bool SendText(string text)
    {
        if (text.Length is 0 or > 210 || text.Any(char.IsControl) ||
            new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0))
            return false;
        var inputs = text.SelectMany(unit => new[] { CreateUnicode(unit, false), CreateUnicode(unit, true) }).ToArray();
        var size = Marshal.SizeOf<Input>();
        var sent = SendInput((uint)inputs.Length, inputs, size);
        if (sent == inputs.Length) return true;
        if ((sent & 1) == 1) SendInput(1, [inputs[sent]], size);
        return false;
    }

    public static bool Click(int count)
    {
        if (count is < 1 or > 2 || (GetAsyncKeyState(1) & 0x8000) != 0)
            return false;
        var inputs = Enumerable.Range(0, count)
            .SelectMany(_ => new[] { CreateMouse(2), CreateMouse(4) }).ToArray();
        var size = Marshal.SizeOf<Input>();
        var sent = SendInput((uint)inputs.Length, inputs, size);
        if ((sent & 1) == 1) SendInput(1, [CreateMouse(4)], size);
        return sent == inputs.Length;
    }

    public static bool Send(KeyChord chord)
    {
        var modifiers = new ushort[] { 0x12, 0x11, 0x10, 0x5B };
        var involved = modifiers.Where((_, index) => (chord.Modifiers & (1u << index)) != 0)
            .Append(chord.VirtualKey).ToArray();
        if (modifiers.Append((ushort)0x5C).Append(chord.VirtualKey).Any(key => (GetAsyncKeyState(key) & 0x8000) != 0))
            return false;

        var inputs = involved.Select(key => Create(key, false))
            .Concat(involved.Reverse().Select(key => Create(key, true))).ToArray();
        var size = Marshal.SizeOf<Input>();
        var submitted = SendInput((uint)inputs.Length, inputs, size);
        if (submitted == inputs.Length)
            return true;
        if (submitted > 0)
        {
            var releases = involved.Take((int)submitted).Reverse().Select(key => Create(key, true)).ToArray();
            SendInput((uint)releases.Length, releases, size);
        }
        return false;
    }

    private static Input Create(ushort key, bool release) => new()
    {
        Type = 1,
        Data = new InputData
        {
            Keyboard = new KeyInput
            {
                VirtualKey = key,
                Flags = (release ? 2u : 0u) | (key is >= 0xA6 and <= 0xB7 or >= 0x21 and <= 0x2E or 0x5B ? 1u : 0u)
            }
        }
    };

    private static Input CreateUnicode(char unit, bool release) => new()
    {
        Type = 1,
        Data = new InputData { Keyboard = new KeyInput { Scan = unit, Flags = release ? 6u : 4u } }
    };

    private static Input CreateMouse(uint flags) => new()
    {
        Type = 0,
        Data = new InputData { Mouse = new MouseInput { Flags = flags } }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputData Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)] public KeyInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyInput
    {
        public ushort VirtualKey, Scan;
        public uint Flags, Time;
        public UIntPtr ExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint Data, Flags, Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterHotKey(IntPtr window, int id);
}
