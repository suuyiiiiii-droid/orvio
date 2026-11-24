using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using Windows.Media.Control;

namespace T1Controller;

internal sealed class Recommendations(Settings settings, MediaService media)
{
    private static readonly string[] PageNames = ["每日推荐", "每日歌曲推荐", "今日推荐", "每日推荐歌曲"];
    private static readonly string[] PlayNames = ["播放全部", "全部播放"];
    private readonly SemaphoreSlim running = new(1, 1);

    public async Task<ActionResult> Play()
    {
        if (!await running.WaitAsync(0))
            return ActionResult.Unavailable("网易云每日推荐正在执行。");
        try
        {
            var player = settings.Players.FirstOrDefault(item => item.Id == "netease");
            if (player is null || MediaService.ResolveExecutable(player) is not { } executable)
                return ActionResult.Unavailable("请先配置网易云音乐的程序路径。");

            var before = await PlaybackSnapshot(player);
            var launch = media.Open("netease");
            if (!launch.Submitted)
                return launch;

            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(18));
            var result = await Task.Run(() => Navigate(executable, deadline.Token));
            if (!result.Submitted)
                return result;
            for (var attempt = 0; attempt < 10; attempt++)
            {
                var after = await PlaybackSnapshot(player);
                if (after.Playing && (!before.Playing ||
                    (!string.IsNullOrWhiteSpace(after.Track) && before.Track != after.Track)))
                    return new(ResultState.Confirmed, "已进入网易云每日推荐并确认开始播放。");
                await Task.Delay(250);
            }
            return result;
        }
        catch (OperationCanceledException)
        {
            return new(ResultState.Partial, "已打开网易云音乐。等待每日推荐页面或播放控件超时。");
        }
        finally
        {
            running.Release();
        }
    }

    private static ActionResult Navigate(string executable, CancellationToken token)
    {
        var navigationInvoked = false;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var handle = MediaService.FindPlayerWindow(executable);
            if (handle != IntPtr.Zero)
            {
                try
                {
                    var window = AutomationElement.FromHandle(handle);
                    if (Unique(window, ["立即登录", "登录网易云音乐"], actionable: true) is not null)
                        return new(ResultState.Partial, "已打开网易云音乐。请先登录，再重试每日推荐。");

                    var pageTitle = Unique(window, PageNames, actionable: false);
                    var play = Unique(window, PlayNames, actionable: true);
                    if (pageTitle is not null && play is not null && RelatedContent(window, pageTitle, play))
                    {
                        token.ThrowIfCancellationRequested();
                        if (Invoke(play))
                            return new(ResultState.Sent, "已进入每日推荐并请求播放，请在网易云确认播放状态。");
                    }
                    if (!navigationInvoked && Unique(window, PageNames, actionable: true) is { } page)
                    {
                        token.ThrowIfCancellationRequested();
                        navigationInvoked = Invoke(page);
                    }
                }
                catch (ElementNotAvailableException)
                {
                    // Client windows can be replaced while they start or navigate.
                }
                catch (System.Runtime.InteropServices.COMException)
                {
                    // Retry while the client UI Automation provider initializes.
                }
            }
            token.WaitHandle.WaitOne(250);
        }
    }

    private static AutomationElement? Unique(AutomationElement window, string[] labels, bool actionable)
    {
        var names = new OrCondition(labels.Select(label => new PropertyCondition(AutomationElement.NameProperty, label)).ToArray());
        var condition = new AndCondition(names,
            new PropertyCondition(AutomationElement.ProcessIdProperty, window.Current.ProcessId),
            new PropertyCondition(AutomationElement.IsOffscreenProperty, false));
        var candidates = window.FindAll(TreeScope.Descendants, condition)
            .Cast<AutomationElement>()
            .Where(element => actionable
                ? element.Current.IsEnabled && (element.TryGetCurrentPattern(InvokePattern.Pattern, out _) ||
                    element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _))
                : element.Current.ControlType == ControlType.Text)
            .Take(2).ToArray();
        return candidates.Length == 1 ? candidates[0] : null;
    }

    private static bool RelatedContent(AutomationElement window, AutomationElement title, AutomationElement play)
    {
        var walker = TreeWalker.ControlViewWalker;
        var titleParent = walker.GetParent(title);
        for (var step = 0; step < 3 && titleParent is not null && !titleParent.Equals(window); step++)
        {
            var playParent = walker.GetParent(play);
            for (var other = 0; other < 3 && playParent is not null && !playParent.Equals(window); other++)
            {
                if (titleParent.Equals(playParent))
                    return true;
                playParent = walker.GetParent(playParent);
            }
            titleParent = walker.GetParent(titleParent);
        }
        return false;
    }

    private static bool Invoke(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke) && invoke is InvokePattern button)
        {
            button.Invoke();
            return true;
        }
        if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var select) && select is SelectionItemPattern item)
        {
            item.Select();
            return true;
        }
        return false;
    }

    private async Task<(bool Playing, string Track)> PlaybackSnapshot(Player player)
    {
        try
        {
            var session = await media.FindSession(player);
            if (session is null)
                return (false, "");
            var info = session.GetPlaybackInfo();
            var track = await session.TryGetMediaPropertiesAsync();
            return (info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
                string.IsNullOrWhiteSpace(track?.Title) ? "" : $"{track.Artist}\u001f{track.Title}");
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return (false, "");
        }
    }
}
