using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace T1Controller;

internal sealed record DisplayTarget(string Id, string Name);
internal sealed record DisplayInventory(IReadOnlyList<DisplayTarget> Targets, string? Diagnostic);

internal sealed class DisplayService
{
    private const byte InputSourceCode = 0x60;

    public DisplayInventory Enumerate() => WithDisplays(selectedId: null,
        (monitors, diagnostic) => new DisplayInventory(monitors.Select(monitor => monitor.Target).ToArray(), diagnostic));

    public uint Read(string id) => OnSelected(id, handle =>
    {
        if (!GetVCPFeatureAndVCPFeatureReply(handle, InputSourceCode, IntPtr.Zero, out var current, out _))
            throw DdcError(Marshal.GetLastPInvokeError(), "读取显示器输入失败");
        return current;
    });

    public async Task<ActionResult> Set(string id, uint target)
    {
        try
        {
            if (Read(id) == target)
                return new(ResultState.Confirmed, $"画面已在输入 0x{target:X2}。");
        }
        catch (Win32Exception)
        {
            // Some monitors allow a set request even when the current input cannot be read.
        }
        catch (InvalidOperationException exception)
        {
            return ActionResult.Unavailable(exception.Message);
        }

        try
        {
            OnSelected(id, handle =>
            {
                if (!SetVCPFeature(handle, InputSourceCode, target))
                    throw DdcError(Marshal.GetLastPInvokeError(), "写入显示器输入失败");
                return true;
            });
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            return ActionResult.Failed(exception.Message);
        }

        for (var attempt = 0; attempt < 5; attempt++)
        {
            await Task.Delay(180);
            try
            {
                if (Read(id) == target)
                    return new(ResultState.Confirmed, $"画面输入读回 0x{target:X2}。");
            }
            catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
            {
                // The previous input may disappear after a successful switch.
            }
        }
        return new(ResultState.Sent, $"已请求画面切换到 0x{target:X2}，请核对显示器当前输入。");
    }

    private static T OnSelected<T>(string id, Func<IntPtr, T> action) => WithDisplays(id, (monitors, diagnostic) =>
    {
        var matches = monitors.Where(monitor => SameId(monitor.Target.Id, id)).ToArray();
        if (matches.Length != 1)
            throw new InvalidOperationException(diagnostic ?? "已校准的显示器当前不可用，请连接后刷新。");
        return action(matches[0].Handle);
    });

    // Use the physical handles only while this enumeration owns them.
    private static T WithDisplays<T>(string? selectedId,
        Func<IReadOnlyList<(DisplayTarget Target, IntPtr Handle)>, string?, T> use)
    {
        var logicalMonitors = new List<IntPtr>();
        if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            (IntPtr monitor, IntPtr dc, ref Rectangle area, IntPtr data) =>
            {
                logicalMonitors.Add(monitor);
                return true;
            }, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Windows 无法枚举当前桌面的显示器。");

        var held = new List<PhysicalMonitor[]>();
        var resolved = new List<(DisplayTarget Target, IntPtr Handle)>();
        var unresolved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var monitor in logicalMonitors)
            {
                var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
                if (!GetMonitorInfo(monitor, ref info) ||
                    !GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out var count) || count is 0 or > 64)
                    continue;
                var devices = ActiveDisplays(info.Device);
                if (devices.Length == 0 || (selectedId is not null && !devices.Any(device => SameId(device.Id, selectedId))))
                    continue;

                var physical = new PhysicalMonitor[count];
                if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physical))
                    continue;
                held.Add(physical);

                if (devices.Length == 1 && physical.Length == 1)
                {
                    resolved.Add((new DisplayTarget(devices[0].Id, $"{devices[0].Name} · {info.Device}"), physical[0].Handle));
                    continue;
                }

                var models = devices.Select(device => device.Model).ToArray();
                var labels = physical.Select(monitor => MonitorIdentity.IsModelName(monitor.Description)
                    ? monitor.Description : ReadCapabilityModel(monitor.Handle)).ToArray();
                foreach (var device in devices)
                {
                    var index = MonitorIdentity.FindUniqueMatch(device.Model, models, labels);
                    if (index is int position)
                        resolved.Add((new DisplayTarget(device.Id, $"{device.Name} · {info.Device}"), physical[position].Handle));
                    else if (selectedId is null || SameId(device.Id, selectedId))
                        unresolved.Add(device.Name);
                }
            }
            var diagnostic = unresolved.Count == 0 ? null
                : $"Windows 正在复制屏幕，无法单独确认 {string.Join("、", unresolved)}。切到「扩展这些显示器」后刷新并重新读取输入。";
            return use(resolved, diagnostic);
        }
        finally
        {
            foreach (var physical in held)
                DestroyPhysicalMonitors((uint)physical.Length, physical);
        }
    }

    private sealed record ActiveDisplay(string Id, string Name, string? Model);

    private static ActiveDisplay[] ActiveDisplays(string source)
    {
        var result = new List<ActiveDisplay>();
        for (uint index = 0; index < 64; index++)
        {
            var device = new DisplayDevice { Size = (uint)Marshal.SizeOf<DisplayDevice>() };
            if (!EnumDisplayDevices(source, index, ref device, 1)) break;
            if ((device.Flags & 1) == 0 || string.IsNullOrWhiteSpace(device.Id)) continue;
            var model = ReadEdidModel(device.Id);
            if (model is null && MonitorIdentity.IsModelName(device.Description)) model = device.Description;
            result.Add(new ActiveDisplay(device.Id, model ?? device.Description, model));
        }
        return result.ToArray();
    }

    private static string? ReadEdidModel(string id)
    {
        var parts = id.Split('#');
        if (parts.Length != 4 || !parts[0].Equals(@"\\?\DISPLAY", StringComparison.OrdinalIgnoreCase)) return null;
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Enum\DISPLAY\{parts[1]}\{parts[2]}\Device Parameters");
            return key?.GetValue("EDID") is byte[] edid ? MonitorIdentity.EdidModel(edid) : null;
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            return null;
        }
    }

    private static string? ReadCapabilityModel(IntPtr handle)
    {
        if (!GetCapabilitiesStringLength(handle, out var size) || size is 0 or > 8192) return null;
        var buffer = new StringBuilder((int)size);
        return CapabilitiesRequestAndCapabilitiesReply(handle, buffer, size) ? MonitorIdentity.CapabilityModel(buffer.ToString()) : null;
    }

    private static bool SameId(string first, string second) => string.Equals(first, second, StringComparison.OrdinalIgnoreCase);

    private static Win32Exception DdcError(int code, string action)
    {
        var detail = unchecked((uint)code) switch
        {
            31 => "显示器或连接未响应",
            0xC0262589 => "该显示器路径不支持输入源 VCP 0x60",
            _ => "请检查 DDC/CI 和当前信号路径"
        };
        return new Win32Exception(code, $"{action}。{detail}（0x{code:X8}）。");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rectangle { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo
    {
        public uint Size;
        public Rectangle Area, WorkArea;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DisplayDevice
    {
        public uint Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Key;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PhysicalMonitor
    {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }
    [return: MarshalAs(UnmanagedType.Bool)]
    private delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, ref Rectangle area, IntPtr data);

    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", EntryPoint = "EnumDisplayDevicesW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayDevices(string device, uint number, ref DisplayDevice displayDevice, uint flags);
    [DllImport("Dxva2.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("Dxva2.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PhysicalMonitor[] physical);
    [DllImport("Dxva2.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyPhysicalMonitors(uint count, PhysicalMonitor[] physical);
    [DllImport("Dxva2.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCapabilitiesStringLength(IntPtr monitor, out uint length);
    [DllImport("Dxva2.dll", CharSet = CharSet.Ansi, ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr monitor, StringBuilder capabilities, uint length);
    [DllImport("Dxva2.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, IntPtr type, out uint value, out uint maximum);
    [DllImport("Dxva2.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);
}

internal sealed class SwitchCoordinator(Settings settings, DisplayService display)
{
    private readonly SemaphoreSlim operation = new(1, 1);
    public string VideoStatus { get; private set; } = "待校准";
    public string HubStatus { get; private set; } = "待校准";
    public bool IsBusy => operation.CurrentCount == 0;

    public async Task<ActionResult> Switch(Host? target, bool displayOnly)
    {
        if (!await operation.WaitAsync(0))
            return ActionResult.Unavailable("已有一次切换正在进行。");
        try
        {
            if (settings.MonitorId is not { Length: > 0 } monitor || settings.WindowsInput is not uint windows ||
                settings.MacInput is not uint mac || windows == mac)
                return ActionResult.Unavailable("请先在主机切换页保存显示器和两台主机的输入代码。");

            if (target is null)
            {
                displayOnly |= !settings.SwitchWithPeripherals;
                if (!displayOnly && settings.HubHandoffPending && !settings.HubDepartureObserved)
                    return ActionResult.Unavailable("上次外设交接待核对。请先确认外设当前归属。");
                var source = await Task.Run(() => display.Read(monitor));
                if (source != windows && source != mac)
                    return ActionResult.Unavailable("当前输入不在已校准的 Mac 和 Windows 输入之间。");
                if (!displayOnly && (source != windows || ReadHubMarkers() != (true, true)))
                    return ActionResult.Unavailable("当前画面和外设归属无法同时确认，请选择明确的目标。");
                target = source == windows ? Host.Mac : Host.Windows;
            }

            var result = await Task.Run(() => display.Set(monitor, target == Host.Windows ? windows : mac));
            VideoStatus = result.Message;
            if (displayOnly || !result.Submitted)
                return result;

            ActionResult hub;
            try
            {
                hub = await HandoffCore(target.Value);
            }
            catch (Exception exception) when (exception is System.IO.IOException or UnauthorizedAccessException or COMException)
            {
                hub = ActionResult.Failed($"外设交接失败。{exception.Message}");
            }
            HubStatus = hub.Message;
            var combined = hub.State switch
            {
                ResultState.Confirmed when result.State == ResultState.Confirmed => ResultState.Confirmed,
                ResultState.Confirmed or ResultState.Sent => ResultState.Sent,
                _ => ResultState.Partial
            };
            return new(combined, $"{result.Message} {hub.Message}");
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            VideoStatus = exception.Message;
            return ActionResult.Failed(exception.Message);
        }
        finally
        {
            operation.Release();
        }
    }

    public async Task<ActionResult> Handoff(Host target)
    {
        if (!await operation.WaitAsync(0))
            return ActionResult.Unavailable("已有一次切换正在进行。");
        try
        {
            var result = await HandoffCore(target);
            HubStatus = result.Message;
            return result;
        }
        finally
        {
            operation.Release();
        }
    }

    private async Task<ActionResult> HandoffCore(Host target)
    {
        if (ReadHubMarkers() is not { } markers)
            return ActionResult.Unavailable("请配置并实测 KMFU 接收器和共享音响的归属，或手动交接外设。");
        if (target == Host.Windows)
            return markers == (true, true)
                ? new(ResultState.Sent, "已在 Windows 枚举到接收器与音响，请核对键鼠归属。")
                : ActionResult.Unavailable("Windows 未枚举到完整外设，请从当前控制外设的主机或 KMFU 交接。");
        if (markers != (true, true) || !KeyChord.TryParse(settings.HubHotkey, out var chord))
            return ActionResult.Unavailable("当前外设归属或 KMFU 快捷键未确认，请使用 KMFU 手动交接。");

        if (settings.HubHandoffPending && !settings.HubDepartureObserved)
            return ActionResult.Unavailable("上次外设交接待核对。请在确认全部外设当前归属 Windows 后重新启用切换。");
        settings.HubHandoffPending = true;
        settings.HubDepartureObserved = false;
        settings.Save();
        if (!Keyboard.Send(chord))
            return ActionResult.Failed("未能发出 KMFU 快捷键，请检查按键与 KMFU 权限。");

        var absent = 0;
        for (var attempt = 0; attempt < 10; attempt++)
        {
            await Task.Delay(150);
            if (ReadHubMarkers() == (false, false))
            {
                if (++absent < 2)
                    continue;
                settings.HubDepartureObserved = true;
                settings.Save();
                return new(ResultState.Sent, "KMFU 接收器与音响已离开 Windows，请在 Mac 核对键鼠、接收器和音响。");
            }
            absent = 0;
        }
        return new(ResultState.Sent, "已发出 KMFU 快捷键，尚未观察到接收器与音响同时离开 Windows。");
    }

    private (bool Receiver, bool Output)? ReadHubMarkers()
    {
        if (settings.HubOwnerDevicePath is not { Length: > 0 } marker ||
            settings.HubOwnerOutputId is not { Length: > 0 } output)
            return null;
        var receiver = RawInput.IsPresent(marker);
        var speaker = MediaService.ListOutputDevices().Any(device => device.Id == output);
        return (receiver, speaker);
    }
}
