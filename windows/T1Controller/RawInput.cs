using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace T1Controller;

internal sealed record RawDevice(IntPtr Handle, string Path, uint Type, ushort UsagePage, ushort Usage,
    uint? Vendor = null, uint? Product = null)
{
    public bool IsT1 => (Vendor == 0x1915 && Product == 0x1025) ||
        Path.Contains("VID_1915&PID_1025", StringComparison.OrdinalIgnoreCase);

    public bool IsXiaomiRemote => UsagePage == 1 && Usage == 6 &&
        (Path.Contains("{00001812-", StringComparison.OrdinalIgnoreCase) ||
         Path.Contains("BTHLE", StringComparison.OrdinalIgnoreCase)) &&
        (Path.Contains("VID&012717_PID&32B8", StringComparison.OrdinalIgnoreCase) ||
         Path.Contains("VID&002717_PID&32B8", StringComparison.OrdinalIgnoreCase) ||
         Path.Contains("VID_2717&PID_32B8", StringComparison.OrdinalIgnoreCase));

    public string DisplayName
    {
        get
        {
            var id = Path.Split('#');
            var product = id.Length > 1 ? id[1] : Path;
            var suffix = id.Length > 2 ? $" · {id[2]}" : "";
            var kind = Type == 1 ? "键盘" : "HID";
            var hardware = Vendor is uint vid && Product is uint pid ? $"VID {vid:X4} · PID {pid:X4} · " : "";
            var name = IsXiaomiRemote ? "小米遥控器 RC003 · " : IsT1 ? "T1 飞鼠 · " : "";
            return $"{name}{kind} · {UsagePage:X4}/{Usage:X4} · {hardware}{product}{suffix}";
        }
    }
}

internal readonly record struct ButtonEvent(RawDevice Device, string Control, bool Down, long Timestamp, bool Repeat = false);

internal sealed class RawInput : IDisposable
{
    private const int WmInput = 0x00FF;
    private const int WmInputDeviceChange = 0x00FE;
    private const uint RidiPreparsedData = 0x20000005;
    private const uint RidiDeviceName = 0x20000007;
    private const uint RidiDeviceInfo = 0x2000000B;
    private const uint RidInput = 0x10000003;
    private const int HidSuccess = 0x00110000;

    private readonly HwndSource source;
    private readonly Dictionary<IntPtr, RawDevice> devices = [];
    private readonly Dictionary<IntPtr, byte[]> preparsed = [];
    private readonly Dictionary<(IntPtr, byte), HashSet<string>> hidKeys = [];
    private readonly HashSet<(IntPtr Handle, string Control)> keyboardKeys = [];
    private readonly HashSet<(ushort, ushort)> registered = [];
    private readonly HashSet<string> watchedPaths = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<RawDevice> Devices => devices.Values.OrderBy(x => x.DisplayName).ToArray();
    public event Action? DevicesChanged;
    public event Action<string>? DeviceRemoved;
    public event Action<ButtonEvent>? Button;
    public event Action<string>? Report;
    public event Action<string>? Error;
    public string? ProbePath { get; set; }

    public RawInput(HwndSource source)
    {
        this.source = source;
        Refresh();
        source.AddHook(WindowMessage);
    }

    public void Watch(IEnumerable<string> paths)
    {
        watchedPaths.Clear();
        watchedPaths.UnionWith(paths);
        UpdateRegistration();
    }

    public static bool IsPresent(string path) =>
        ReadDevices().Any(device => string.Equals(device.Path, path, StringComparison.OrdinalIgnoreCase));

    private static IReadOnlyList<RawDevice> ReadDevices()
    {
        var itemSize = (uint)Marshal.SizeOf<RawDeviceListItem>();
        uint count = 0;
        if (GetRawInputDeviceList(null, ref count, itemSize) == uint.MaxValue || count == 0)
            return [];

        var items = new RawDeviceListItem[count];
        var read = GetRawInputDeviceList(items, ref count, itemSize);
        if (read == uint.MaxValue)
            return [];

        var list = new List<RawDevice>();
        foreach (var item in items.Take((int)read).Where(item => item.Type is 1 or 2))
        {
            var path = ReadDeviceName(item.Handle);
            if (string.IsNullOrEmpty(path))
                continue;

            if (item.Type == 1)
            {
                list.Add(new RawDevice(item.Handle, path, item.Type, 1, 6));
                continue;
            }

            var info = new RawDeviceInfo { Size = (uint)Marshal.SizeOf<RawDeviceInfo>() };
            var infoSize = info.Size;
            if (GetDeviceInfo(item.Handle, RidiDeviceInfo, ref info, ref infoSize) != uint.MaxValue &&
                info.Page != 0 && info.Usage != 0)
                list.Add(new RawDevice(item.Handle, path, item.Type, info.Page, info.Usage, info.Vendor, info.Product));
        }
        return list;
    }

    public void Refresh()
    {
        var current = ReadDevices();
        var present = current.Select(device => device.Handle).ToHashSet();
        foreach (var removed in devices.Values.Where(device => !present.Contains(device.Handle)).ToArray())
        {
            devices.Remove(removed.Handle);
            preparsed.Remove(removed.Handle);
            keyboardKeys.RemoveWhere(key => key.Handle == removed.Handle);
            foreach (var key in hidKeys.Keys.Where(key => key.Item1 == removed.Handle).ToArray())
                hidKeys.Remove(key);
            DeviceRemoved?.Invoke(removed.Path);
        }
        foreach (var device in current)
            devices[device.Handle] = device;

        UpdateRegistration();
        DevicesChanged?.Invoke();
    }

    public void ResetState()
    {
        hidKeys.Clear();
        keyboardKeys.Clear();
    }

    private void UpdateRegistration()
    {
        var required = new HashSet<(ushort Page, ushort Usage)> { (1, 6), (0x0C, 1), (1, 0x80) };
        foreach (var device in devices.Values)
        {
            if (watchedPaths.Contains(device.Path) || string.Equals(device.Path, ProbePath, StringComparison.OrdinalIgnoreCase))
                required.Add((device.UsagePage, device.Usage));
        }

        var changes = required.Except(registered)
            .Select(usage => new RawRegistration(usage.Item1, usage.Item2, 0x2100, source.Handle))
            .Concat(registered.Except(required).Select(usage => new RawRegistration(usage.Item1, usage.Item2, 1, IntPtr.Zero)))
            .ToArray();
        if (changes.Length == 0)
            return;
        if (!RegisterRawInputDevices(changes, (uint)changes.Length, (uint)Marshal.SizeOf<RawRegistration>()))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "无法注册 Raw Input 监听。");
        registered.Clear();
        registered.UnionWith(required);
    }

    private IntPtr WindowMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmInputDeviceChange)
        {
            try { Refresh(); }
            catch (Win32Exception exception) { Error?.Invoke(exception.Message); }
        }
        else if (message == WmInput)
            ReadInput(lParam);
        return IntPtr.Zero;
    }

    private void ReadInput(IntPtr handle)
    {
        uint size = 0;
        var headerSize = (uint)(8 + IntPtr.Size * 2);
        if (GetRawInputData(handle, RidInput, null, ref size, headerSize) == uint.MaxValue ||
            size < headerSize || size > 65536)
            return;

        var data = new byte[size];
        var bytesRead = GetRawInputData(handle, RidInput, data, ref size, headerSize);
        if (bytesRead != size)
            return;
        var deviceHandle = IntPtr.Size == 8
            ? new IntPtr(BitConverter.ToInt64(data, 8))
            : new IntPtr(BitConverter.ToInt32(data, 8));
        if (!devices.TryGetValue(deviceHandle, out var device))
            return;

        var probing = string.Equals(device.Path, ProbePath, StringComparison.OrdinalIgnoreCase);
        if (!probing && !watchedPaths.Contains(device.Path))
            return;

        var offset = (int)headerSize;
        var type = BitConverter.ToUInt32(data);
        var time = Stopwatch.GetTimestamp();
        if (type == 1 && size >= headerSize + 16)
        {
            var scan = BitConverter.ToUInt16(data, offset);
            var flags = BitConverter.ToUInt16(data, offset + 2);
            var key = BitConverter.ToUInt16(data, offset + 6);
            if (key == 255)
                return;
            var control = $"key:{key:X2}/{scan:X2}/{flags & 6:X1}";
            var pressed = (flags & 1) == 0;
            var held = (deviceHandle, control);
            var repeat = pressed && !keyboardKeys.Add(held);
            if (!pressed)
                keyboardKeys.Remove(held);
            Button?.Invoke(new ButtonEvent(device, control, pressed, time, repeat));
        }
        else if (type == 2 && size >= headerSize + 8)
        {
            var reportSize = BitConverter.ToUInt32(data, offset);
            var count = BitConverter.ToUInt32(data, offset + 4);
            if (reportSize == 0 || reportSize * (ulong)count > size - headerSize - 8)
                return;
            for (var index = 0; index < count; index++)
            {
                var report = data.AsSpan(offset + 8 + index * (int)reportSize, (int)reportSize).ToArray();
                var decoded = DecodeReport(device, report, time);
                if (probing && !decoded)
                    Report?.Invoke($"HID 报告 ID 0x{report[0]:X2} · {reportSize} 字节 · 未解码按键");
            }
        }
    }

    private bool DecodeReport(RawDevice device, byte[] report, long time)
    {
        if (!preparsed.TryGetValue(device.Handle, out var descriptor))
        {
            uint size = 0;
            if (GetDeviceData(device.Handle, RidiPreparsedData, null, ref size) == uint.MaxValue ||
                size == 0 || size > 65536)
                return false;
            descriptor = new byte[size];
            if (GetDeviceData(device.Handle, RidiPreparsedData, descriptor, ref size) == uint.MaxValue)
                return false;
            preparsed[device.Handle] = descriptor;
        }

        var capacity = HidP_MaxUsageListLength(0, 0, descriptor);
        if (capacity == 0 || capacity > 1024)
            return false;
        var usages = new HidUsage[capacity];
        var length = capacity;
        if (HidP_GetUsagesEx(0, 0, usages, ref length, descriptor, report, (uint)report.Length) != HidSuccess)
            return false;

        var key = (device.Handle, report[0]);
        var current = usages.Take((int)length)
            .Where(usage => usage.Value != 0)
            .Select(usage => $"hid:{usage.Page:X4}/{usage.Value:X4}/{report[0]:X2}")
            .ToHashSet();
        var previous = hidKeys.GetValueOrDefault(key) ?? [];
        hidKeys[key] = current;
        foreach (var released in previous.Except(current))
            Button?.Invoke(new ButtonEvent(device, released, false, time));
        foreach (var pressed in current.Except(previous))
            Button?.Invoke(new ButtonEvent(device, pressed, true, time));
        return true;
    }

    private static string ReadDeviceName(IntPtr handle)
    {
        uint count = 0;
        if (GetDeviceData(handle, RidiDeviceName, null, ref count) == uint.MaxValue || count == 0 || count > 16384)
            return "";
        var data = new byte[count * 2];
        return GetDeviceData(handle, RidiDeviceName, data, ref count) == uint.MaxValue
            ? ""
            : System.Text.Encoding.Unicode.GetString(data).TrimEnd('\0');
    }

    public void Dispose()
    {
        source.RemoveHook(WindowMessage);
        var removals = registered.Select(usage => new RawRegistration(usage.Item1, usage.Item2, 1, IntPtr.Zero)).ToArray();
        if (removals.Length > 0)
            RegisterRawInputDevices(removals, (uint)removals.Length, (uint)Marshal.SizeOf<RawRegistration>());
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RawDeviceListItem { public IntPtr Handle; public uint Type; }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    private struct RawDeviceInfo
    {
        [FieldOffset(0)] public uint Size;
        [FieldOffset(8)] public uint Vendor;
        [FieldOffset(12)] public uint Product;
        [FieldOffset(20)] public ushort Page;
        [FieldOffset(22)] public ushort Usage;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct RawRegistration(ushort page, ushort usage, uint flags, IntPtr target)
    {
        private readonly ushort page = page;
        private readonly ushort usage = usage;
        private readonly uint flags = flags;
        private readonly IntPtr target = target;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HidUsage { public ushort Value; public ushort Page; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputDeviceList([Out] RawDeviceListItem[]? devices, ref uint count, uint itemSize);
    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW", SetLastError = true)]
    private static extern uint GetDeviceData(IntPtr device, uint command, [Out] byte[]? data, ref uint size);
    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW", SetLastError = true)]
    private static extern uint GetDeviceInfo(IntPtr device, uint command, ref RawDeviceInfo data, ref uint size);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterRawInputDevices(RawRegistration[] devices, uint count, uint itemSize);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(IntPtr input, uint command, [Out] byte[]? data, ref uint size, uint headerSize);
    [DllImport("hid.dll")]
    private static extern uint HidP_MaxUsageListLength(int reportType, ushort usagePage, byte[] preparsedData);
    [DllImport("hid.dll")]
    private static extern int HidP_GetUsagesEx(int reportType, ushort linkCollection, [Out] HidUsage[] usages,
        ref uint usageLength, byte[] preparsedData, byte[] report, uint reportLength);
}
