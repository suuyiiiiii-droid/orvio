using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using Forms = System.Windows.Forms;

namespace T1Controller;

internal sealed class MusicWindow(IntPtr handle)
{
    public sealed record Frame(Rectangle Bounds, MusicText[] Labels, AutomationElement? Search);

    public bool IsForeground => GetForegroundWindow() == handle;

    public Frame? ReadAccessibility()
    {
        if (!IsForeground || Bounds() is not { } bounds) return null;
        var window = AutomationElement.FromHandle(handle);
        GetWindowThreadProcessId(handle, out var owner);
        var filter = new AndCondition(new PropertyCondition(AutomationElement.ProcessIdProperty, (int)owner),
            new PropertyCondition(AutomationElement.IsOffscreenProperty, false));
        var cache = new CacheRequest();
        cache.Add(AutomationElement.NameProperty);
        cache.Add(AutomationElement.BoundingRectangleProperty);
        cache.Add(AutomationElement.ControlTypeProperty);
        cache.Add(AutomationElement.HelpTextProperty);
        cache.Add(AutomationElement.IsPasswordProperty);
        cache.Add(AutomationElement.IsEnabledProperty);
        using (cache.Activate())
        {
            var nodes = window.FindAll(TreeScope.Descendants, filter).Cast<AutomationElement>().Take(1600);
            var labels = new List<MusicText>();
            var edits = new List<AutomationElement>();
            foreach (var node in nodes)
            {
                var item = node.Cached;
                var r = item.BoundingRectangle;
                if (r.IsEmpty || r.Width < 2 || r.Height < 2 || !bounds.Contains((int)(r.X + r.Width / 2),
                        (int)(r.Y + r.Height / 2))) continue;
                var b = new MusicBox((r.X - bounds.X) / bounds.Width, (r.Y - bounds.Y) / bounds.Height,
                    r.Width / bounds.Width, r.Height / bounds.Height);
                if (item.ControlType == ControlType.Edit && !item.IsPassword && item.IsEnabled && b.MidY < .19 &&
                    (MusicLayout.IsSearchHint(item.Name) || MusicLayout.IsSearchHint(item.HelpText)))
                    edits.Add(node);
                if (!string.IsNullOrWhiteSpace(item.Name) && item.Name.Length <= 230 && b.Height < .16 &&
                    (item.ControlType == ControlType.Text || item.ControlType == ControlType.Button ||
                     item.ControlType == ControlType.TabItem || item.ControlType == ControlType.Hyperlink ||
                     item.ControlType == ControlType.ListItem || item.ControlType == ControlType.Edit ||
                     item.ControlType == ControlType.HeaderItem || item.ControlType == ControlType.DataItem))
                    labels.Add(new(item.Name, b));
            }
            return new(bounds, labels.Distinct().ToArray(), edits.Count == 1 ? edits[0] : null);
        }
    }

    public bool Click(Rectangle expected, MusicText target, int count = 1)
    {
        if (!IsForeground || Bounds() != expected) return false;
        var point = new Point(expected.X + (int)Math.Round(target.Bounds.MidX * expected.Width),
            expected.Y + (int)Math.Round(target.Bounds.MidY * expected.Height));
        return expected.Contains(point) && Owns(point) && SetCursorPos(point.X, point.Y) &&
            IsForeground && Owns(point) && Keyboard.Click(count);
    }

    public bool Focus(AutomationElement field)
    {
        if (!IsForeground) return false;
        field.SetFocus();
        return FieldHasFocus(field);
    }

    public bool FieldHasFocus(AutomationElement field)
    {
        if (!IsForeground || !field.Current.IsEnabled || field.Current.IsPassword) return false;
        var focused = AutomationElement.FocusedElement;
        return focused is not null && focused.Equals(field);
    }

    public bool ReadsQuery(AutomationElement field, string query) =>
        FieldHasFocus(field) && field.TryGetCurrentPattern(ValuePattern.Pattern, out var value) &&
        value is ValuePattern input && MusicLayout.Normalize(input.Current.Value) == MusicLayout.Normalize(query);

    public bool TypeQuery(string query) =>
        IsForeground && Keyboard.Send(new KeyChord(2, 0x41)) && IsForeground && Keyboard.SendText(query);

    public bool Submit() => IsForeground && Keyboard.Send(new KeyChord(0, 0x0D));

    private bool Owns(Point point) => GetAncestor(WindowFromPoint(point), 2) == handle;

    private Rectangle? Bounds()
    {
        if (DwmGetWindowAttribute(handle, 9, out NativeRect area, Marshal.SizeOf<NativeRect>()) != 0 &&
            !GetWindowRect(handle, out area)) return null;
        var result = Rectangle.FromLTRB(area.Left, area.Top, area.Right, area.Bottom);
        return result.Width >= 400 && result.Height >= 300 ? result : null;
    }

    public Rectangle? VisibleBounds() => IsForeground ? Bounds() : null;

    public Bitmap? Capture(Rectangle expected)
    {
        if (!IsForeground || Bounds() != expected || expected.Width > 7680 || expected.Height > 4320 ||
            !Forms.Screen.AllScreens.Any(screen => screen.Bounds.Contains(expected)) || !Unobscured(expected))
            return null;
        using var original = new Bitmap(expected.Width, expected.Height, PixelFormat.Format32bppRgb);
        using (var paint = Graphics.FromImage(original))
            paint.CopyFromScreen(expected.Location, Point.Empty, expected.Size, CopyPixelOperation.SourceCopy);
        if (!IsForeground || Bounds() != expected || !Unobscured(expected)) return null;
        var factor = Math.Min(1, 2400.0 / Math.Max(expected.Width, expected.Height));
        return new Bitmap(original, (int)Math.Round(expected.Width * factor), (int)Math.Round(expected.Height * factor));
    }

    private bool Unobscured(Rectangle bounds)
    {
        for (var window = GetWindow(handle, 3); window != IntPtr.Zero; window = GetWindow(window, 3))
        {
            if (!IsWindowVisible(window) || IsIconic(window) ||
                (DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) ||
                !GetWindowRect(window, out var rect)) continue;
            if (bounds.IntersectsWith(Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom)))
                return false;
        }
        return true;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out NativeRect value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
}

internal sealed class MusicTrace
{
    private readonly string directory;
    private int sequence;

    private MusicTrace()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        directory = Path.Combine(local, "T1Controller", "MusicDiagnostics",
            $"{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid().ToString("N")[..8]}");
        Directory.CreateDirectory(directory);
    }

    public string DirectoryPath => directory;
    public bool Failed { get; private set; }

    public static MusicTrace? TryStart()
    {
        try { return new MusicTrace(); }
        catch (Exception issue) when (issue is IOException or UnauthorizedAccessException) { return null; }
    }

    public void Write(string stage, string origin, MusicText[] labels, Bitmap? image = null, string? detail = null)
    {
        var prefix = $"{++sequence:D3}";
        try
        {
            if (image is not null) image.Save(Path.Combine(directory, prefix + ".png"), ImageFormat.Png);
            File.WriteAllText(Path.Combine(directory, prefix + ".json"), JsonSerializer.Serialize(new
            {
                stage, origin, detail, image = image is null ? null : prefix + ".png", labels
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception issue) when (issue is IOException or UnauthorizedAccessException or ExternalException) { Failed = true; }
    }
}

internal static class MusicOcr
{
    public static string? FindExecutable(string? configured) =>
        new[] { configured, Path.Combine(AppContext.BaseDirectory, "OCR", "tesseract.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tesseract-OCR", "tesseract.exe") }
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value) && Path.IsPathFullyQualified(value) && File.Exists(value));

    public static async Task<MusicText[]> Read(string executable, Bitmap image, CancellationToken token)
    {
        var directory = Directory.CreateTempSubdirectory("T1MusicOCR-");
        try
        {
            var file = Path.Combine(directory.FullName, "frame.png");
            image.Save(file, ImageFormat.Png);
            var command = new ProcessStartInfo(executable)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                RedirectStandardError = true, StandardOutputEncoding = System.Text.Encoding.UTF8
            };
            foreach (var arg in new[] { file, "stdout", "-l", "chi_sim+eng", "--psm", "11", "tsv" })
                command.ArgumentList.Add(arg);
            using var process = Process.Start(command) ?? throw new IOException("无法启动本地 OCR。");
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
            budget.CancelAfter(TimeSpan.FromSeconds(9));
            var output = process.StandardOutput.ReadToEndAsync(budget.Token);
            var error = process.StandardError.ReadToEndAsync(budget.Token);
            try
            {
                await process.WaitForExitAsync(budget.Token);
                if (process.ExitCode != 0)
                    throw new IOException("本地 OCR 失败。请检查 Tesseract 的简体中文和英语识别数据。");
                _ = await error;
                return Parse(await output, image.Width, image.Height);
            }
            finally
            {
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
                catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(1)); }
                catch (Exception ex) when (ex is InvalidOperationException or TimeoutException) { }
            }
        }
        finally
        {
            try { directory.Delete(recursive: true); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    private sealed record Word(string Line, string Text, Rectangle Box);

    private static MusicText[] Parse(string output, int width, int height)
    {
        var words = new List<Word>();
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Skip(1))
        {
            var c = line.TrimEnd('\r').Split('\t', 12);
            if (c.Length != 12 || c[0] != "5" || string.IsNullOrWhiteSpace(c[11]) ||
                !double.TryParse(c[10], NumberStyles.Float, CultureInfo.InvariantCulture, out var confidence) || confidence < 30 ||
                !int.TryParse(c[6], out var x) || !int.TryParse(c[7], out var y) ||
                !int.TryParse(c[8], out var w) || !int.TryParse(c[9], out var h) || w < 1 || h < 1) continue;
            words.Add(new(string.Join("-", c.Skip(2).Take(3)), c[11].Trim(), new(x, y, w, h)));
        }
        MusicText ToText(string text, Rectangle box) => new(text,
            new((double)box.X / width, (double)box.Y / height, (double)box.Width / width, (double)box.Height / height));

        var result = new List<MusicText>();
        foreach (var group in words.GroupBy(word => word.Line))
        {
            var part = new List<Word>();
            void Emit()
            {
                if (part.Count == 0) return;
                var box = part.Select(word => word.Box).Aggregate(Rectangle.Union);
                result.Add(ToText(string.Join(" ", part.Select(word => word.Text)), box));
                if (part.Count > 1)
                    result.AddRange(part.Select(word => ToText(word.Text, word.Box)));
                part.Clear();
            }
            foreach (var word in group.OrderBy(word => word.Box.X))
            {
                if (part.Count > 0 && word.Box.X - part[^1].Box.Right > Math.Min(26, .020 * width)) Emit();
                part.Add(word);
            }
            Emit();
        }
        return result.Distinct().ToArray();
    }
}
