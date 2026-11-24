using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace T1Controller;

internal static class XiaoAIWindows
{
    private sealed record Credentials(string BemfaUid, string Token);
    private static string StorePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "T1Controller", "xiaoai-user.dat");

    public static void Save(string uid, string token)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(new Credentials(uid, token));
        try
        {
            var protectedBytes = Transform(plain, protect: true);
            Directory.CreateDirectory(Path.GetDirectoryName(StorePath)!);
            var temporary = StorePath + "." + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllBytes(temporary, protectedBytes);
                File.Move(temporary, StorePath, overwrite: true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public static void Clear() => File.Delete(StorePath);

    public static async Task<ActionResult> Request(XiaoAIOptions options)
    {
        var script = Path.Combine(AppContext.BaseDirectory, "XiaoAIBridge", "xiaoai_daily.py");
        if (!File.Exists(script)) return ActionResult.Unavailable("未找到小爱桥接组件。");
        if (!File.Exists(StorePath)) return ActionResult.Unavailable("请在语音控制中保存巴法 UID 和 Home Assistant 令牌。");
        var python = options.PythonExecutable.Trim();
        if (python.Length == 0)
            python = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
                .Where(folder => Path.IsPathFullyQualified(folder) && !folder.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase))
                .Select(folder => Path.Combine(folder, "python.exe")).FirstOrDefault(File.Exists) ?? "";
        if (!Path.IsPathFullyQualified(python) || !File.Exists(python))
            return ActionResult.Unavailable("请在语音控制中选择 Python 3。");

        try
        {
            var data = Transform(File.ReadAllBytes(StorePath), protect: false);
            Credentials? secrets;
            try { secrets = JsonSerializer.Deserialize<Credentials>(data); }
            finally { CryptographicOperations.ZeroMemory(data); }
            if (secrets is null) return ActionResult.Unavailable("无法解开当前用户的小爱凭据。");
            using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            var start = new ProcessStartInfo(python)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true,
                RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8
            };
            foreach (var arg in new[] { "-E", "-s", "-B", "-X", "utf8", script }) start.ArgumentList.Add(arg);
            using var process = Process.Start(start) ?? throw new IOException();
            var stdout = process.StandardOutput.ReadToEndAsync(budget.Token);
            var stderr = process.StandardError.ReadToEndAsync(budget.Token);
            try
            {
                await JsonSerializer.SerializeAsync(process.StandardInput.BaseStream, new
                {
                    topic = options.Topic.Trim(), bemfaUID = secrets.BemfaUid,
                    homeAssistantURL = options.HomeAssistantUrl.Trim(), homeAssistantToken = secrets.Token,
                    notifyEntity = options.NotifyEntity.Trim(), switchCommand = options.Command.Trim(),
                    includeSilentParameter = options.IncludeSilentParameter
                }, cancellationToken: budget.Token);
                process.StandardInput.Close();
                await process.WaitForExitAsync(budget.Token);
                _ = await stderr;
                using var reply = JsonDocument.Parse(await stdout);
                if (process.ExitCode == 0 && reply.RootElement.GetProperty("event").GetString() == "triggered")
                    return new(ResultState.Confirmed, "收到巴法开关回传。");
                return ActionResult.Unavailable(reply.RootElement.TryGetProperty("message", out var message)
                    ? message.GetString() ?? "小爱回传未确认。" : "小爱回传未确认。");
            }
            finally
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
        }
        catch (OperationCanceledException) { return ActionResult.Unavailable("等待小爱和巴法回传超时。"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or Win32Exception or
                                  InvalidOperationException or JsonException or System.Collections.Generic.KeyNotFoundException)
        {
            return ActionResult.Unavailable("小爱桥接无法完成，请核对 Python、凭据与服务地址。");
        }
    }

    private static byte[] Transform(byte[] value, bool protect)
    {
        var memory = Marshal.AllocHGlobal(value.Length);
        var input = new Blob { Size = value.Length, Data = memory };
        Blob output = default;
        try
        {
            Marshal.Copy(value, 0, memory, value.Length);
            var success = protect
                ? CryptProtectData(ref input, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
            var buffer = new byte[output.Size];
            Marshal.Copy(output.Data, buffer, 0, output.Size);
            return buffer;
        }
        finally
        {
            Marshal.Copy(new byte[value.Length], 0, memory, value.Length);
            Marshal.FreeHGlobal(memory);
            if (output.Data != IntPtr.Zero)
            {
                if (!protect) Marshal.Copy(new byte[output.Size], 0, output.Data, output.Size);
                LocalFree(output.Data);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr data);
}
