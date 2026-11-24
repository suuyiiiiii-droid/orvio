using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace T1Controller;

internal static class MonitorIdentity
{
    public static bool IsModelName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return false;
        name = name.Trim();
        return !name.StartsWith("Generic", StringComparison.OrdinalIgnoreCase) &&
            !name.StartsWith("通用", StringComparison.Ordinal) &&
            !name.Equals("Monitor", StringComparison.OrdinalIgnoreCase) &&
            !name.Equals("显示器", StringComparison.Ordinal);
    }

    // DXVA's physical handles and GDI's display device paths are separate lists.
    // Never pair them by position when a desktop source drives more than one display.
    public static int? FindUniqueMatch(string? model, IReadOnlyList<string?> devices, IReadOnlyList<string?> physical)
    {
        if (!IsModelName(model) || devices.Count != physical.Count ||
            devices.Count(device => SameModel(model, device)) != 1) return null;

        int? match = null;
        for (var index = 0; index < physical.Count; index++)
        {
            if (!SameModel(model, physical[index])) continue;
            if (match.HasValue) return null;
            match = index;
        }
        // If another physical handle has no identity it could also be this model.
        return physical.All(IsModelName) ? match : null;
    }

    private static bool SameModel(string? first, string? second) =>
        string.Equals(first?.Trim(), second?.Trim(), StringComparison.OrdinalIgnoreCase);

    public static string? EdidModel(ReadOnlySpan<byte> bytes)
    {
        ReadOnlySpan<byte> header = [0, 255, 255, 255, 255, 255, 255, 0];
        if (bytes.Length < 128 || !bytes[..8].SequenceEqual(header)) return null;
        var checksum = 0;
        foreach (var value in bytes[..128]) checksum += value;
        if ((checksum & 0xff) != 0) return null;

        for (var offset = 54; offset <= 108; offset += 18)
        {
            var descriptor = bytes.Slice(offset, 18);
            if (descriptor[0] != 0 || descriptor[1] != 0 || descriptor[2] != 0 ||
                descriptor[3] != 0xfc || descriptor[4] != 0) continue;
            var text = descriptor[5..];
            var end = text.IndexOfAny((byte)0, (byte)10);
            var name = Encoding.ASCII.GetString(end < 0 ? text : text[..end]).Trim();
            if (IsModelName(name)) return name;
        }
        return null;
    }

    public static string? CapabilityModel(string capability)
    {
        var match = Regex.Match(capability, @"\bmodel\s*\(\s*([^()]{1,64})\)", RegexOptions.IgnoreCase);
        var name = match.Success ? match.Groups[1].Value.Trim() : null;
        return IsModelName(name) ? name : null;
    }
}
