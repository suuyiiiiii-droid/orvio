using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace T1Controller;

internal sealed class NativeTextTarget
{
    private readonly AutomationElement element;
    private readonly int[] identity;
    private readonly IntPtr window;
    private readonly TextPatternRange? selection;
    private NativeTextTarget(AutomationElement element, IntPtr window)
    {
        this.element = element; identity = element.GetRuntimeId(); this.window = window;
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern))
            selection = ((TextPattern)pattern).GetSelection().SingleOrDefault()?.Clone();
    }
    public static NativeTextTarget? Capture()
    {
        try
        {
            var window = GetForegroundWindow();
            var node = AutomationElement.FocusedElement;
            for (var depth = 0; node is not null && depth < 6; depth++, node = TreeWalker.ControlViewWalker.GetParent(node))
            {
                var state = node.Current;
                if (state.IsPassword || !state.IsEnabled) return null;
                if ((state.ControlType == ControlType.Edit || state.ControlType == ControlType.Document) &&
                    state.HasKeyboardFocus && IsWritable(node))
                    return new NativeTextTarget(node, window);
            }
        }
        catch (Exception failure) when (failure is ElementNotAvailableException or InvalidOperationException or COMException) { }
        return null;
    }
    private static bool IsWritable(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value))
            return !((ValuePattern)value).Current.IsReadOnly;
        if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var text)) return false;
        return ((TextPattern)text).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is false;
    }
    public async Task<ActionResult> Insert(string text, Func<bool> current)
    {
        if (!Matches(current) || !SelectionMatches())
            return ActionResult.Unavailable("输入焦点或光标已变化；转写文字已保留。");
        for (var offset = 0; offset < text.Length;)
        {
            if (!Matches(current)) return ActionResult.Unavailable("输入焦点已变化，已停止输入；完整文字已保留。");
            var length = Math.Min(32, text.Length - offset);
            if (offset + length < text.Length && char.IsHighSurrogate(text[offset + length - 1])) length--;
            if (!Keyboard.SendText(text.Substring(offset, length)))
                return ActionResult.Unavailable("系统未接受文字输入；请确认目标应用权限级别，转写已保留。");
            offset += length;
            if (offset < text.Length) await Task.Delay(30);
        }
        return new(ResultState.Sent, "已向原文本框输入转写文字。");
    }
    private bool Matches(Func<bool> current)
    {
        try
        {
            return current() && GetForegroundWindow() == window && !element.Current.IsPassword &&
                   AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(identity);
        }
        catch (Exception failure) when (failure is ElementNotAvailableException or InvalidOperationException or COMException) { return false; }
    }
    private bool SelectionMatches()
    {
        if (selection is null) return true;
        try
        {
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) return false;
            var ranges = ((TextPattern)pattern).GetSelection();
            return ranges.Length == 1 && selection.CompareEndpoints(TextPatternRangeEndpoint.Start, ranges[0], TextPatternRangeEndpoint.Start) == 0 &&
                   selection.CompareEndpoints(TextPatternRangeEndpoint.End, ranges[0], TextPatternRangeEndpoint.End) == 0;
        }
        catch (Exception failure) when (failure is ElementNotAvailableException or InvalidOperationException or COMException) { return false; }
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
}
