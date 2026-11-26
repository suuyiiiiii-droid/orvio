using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace T1Controller;

internal static class ProcessTree
{
    public static IReadOnlyDictionary<uint, uint> Parents()
    {
        var result = new Dictionary<uint, uint>();
        using var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot.IsInvalid) return result;
        var entry = new Entry { Size = (uint)Marshal.SizeOf<Entry>(), Name = "" };
        if (!Process32FirstW(snapshot, ref entry)) return result;
        do { result[entry.Pid] = entry.Parent; } while (Process32NextW(snapshot, ref entry));
        return result;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Entry
    {
        public uint Size, Usage, Pid;
        public UIntPtr Heap;
        public uint Module, Threads, Parent;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags, uint process);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32FirstW(SafeFileHandle snapshot, ref Entry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32NextW(SafeFileHandle snapshot, ref Entry entry);
}
