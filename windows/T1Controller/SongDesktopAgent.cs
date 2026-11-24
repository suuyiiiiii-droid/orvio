using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using Windows.Media.Control;

namespace T1Controller;

internal sealed class SongDesktopAgent(Settings settings, MediaService media)
{
    private sealed record Playback(string Title, string Artist, bool Playing, TimeSpan Position);
    private sealed record View(Rectangle Bounds, MusicText[] Labels, AutomationElement? Search);
    private sealed class Stopped(string message) : Exception(message);

    public async Task<ActionResult> Play(ControllerAction song, IProgress<string>? progress = null)
    {
        if (string.IsNullOrWhiteSpace(song.Title))
            return ActionResult.Unavailable("请说出歌曲名。");
        var player = media.SongPlayer(song.Player);
        if (player is null || MediaService.ServiceId(player) is not { } service)
            return ActionResult.Unavailable("请在音乐控制中选择已安装的网易云音乐或汽水音乐。");
        var path = MediaService.ResolveExecutable(player);
        if (path is null)
            return ActionResult.Unavailable($"未找到 {player.Name}。请在音乐控制中选择它的程序。");

        var trace = settings.RecordMusicDiagnostics ? MusicTrace.TryStart() : null;
        var ocr = MusicOcr.FindExecutable(settings.MusicOcrExecutable);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(65));
        var token = deadline.Token;
        var query = MusicLayout.Query(song);
        var soda = service == "soda";
        var stage = "打开播放器";
        var submitted = false;
        var result = ActionResult.Unavailable("点歌未完成。");
        try
        {
            progress?.Report($"正在打开 {player.Name}");
            var window = await OpenWindow(path, token);
            var before = await Snapshot(player);

            stage = "定位搜索栏";
            progress?.Report($"{player.Name} · 正在定位搜索栏");
            var initial = await Wait(window, ocr, trace, stage,
                view => view.Search is not null || MusicLayout.SearchAnchor(view.Labels) is not null,
                TimeSpan.FromSeconds(12), token);
            if (initial is null)
                throw new Stopped(ocr is null
                    ? "播放器没有向 Windows 公开可识别的搜索栏。可在音乐控制中配置本地 OCR。"
                    : "未确认搜索栏的位置，请检查播放器窗口是否可见。");

            stage = "输入并提交搜索";
            var anchor = MusicLayout.SearchAnchor(initial.Labels);
            if (initial.Search is { } field)
            {
                if (!await Task.Run(() => window.Focus(field), token).WaitAsync(token))
                    throw new Stopped("无法确认搜索栏取得焦点。");
            }
            else if (anchor is null || !window.Click(initial.Bounds, anchor))
                throw new Stopped("无法确认搜索栏点击位置。");
            if (!window.TypeQuery(query))
                throw new Stopped("未能将搜索词输入目标播放器。");
            var typed = initial.Search is { } search &&
                await Task.Run(() => window.ReadsQuery(search, query), token).WaitAsync(token);
            if (!typed)
            {
                var readback = await Wait(window, ocr, trace, "核对搜索词",
                    view => view.Labels.Any(label => label.Bounds.MidY < .135 && label.Name == MusicLayout.Normalize(query)),
                    TimeSpan.FromSeconds(7), token);
                if (readback is null)
                    throw new Stopped("搜索栏里的文字未能读回，请检查是否成功输入。");
            }
            if (trace is not null)
                await Read(window, null, trace, "搜索词已输入", _ => true, token, query);
            if (!window.Submit())
                throw new Stopped("未能在已验证的窗口提交搜索。");

            stage = "定位歌曲列表";
            progress?.Report($"{player.Name} · 正在核对《{song.Title}》");
            var searchResults = await Wait(window, ocr, trace, stage,
                view => MusicLayout.ShowsResults(view.Labels, query) && MusicLayout.TrackTab(view.Labels, soda) is not null,
                TimeSpan.FromSeconds(14), token);
            if (searchResults is null || MusicLayout.TrackTab(searchResults.Labels, soda) is not { } tab ||
                !window.Click(searchResults.Bounds, tab))
                throw new Stopped("未确认搜索结果页或歌曲标签。");

            stage = "匹配歌名和歌手";
            var results = await Wait(window, ocr, trace, stage, view => MusicLayout.ShowsResults(view.Labels, query) &&
                    MusicLayout.Rows(view.Labels, song.Title, song.Artist, soda).Count > 0,
                TimeSpan.FromSeconds(13), token);
            if (results is null)
                throw new Stopped($"当前可见结果里未找到{song.Artist ?? ""}的《{song.Title}》。");
            var rows = MusicLayout.Rows(results.Labels, song.Title, song.Artist, soda);
            if (song.Artist is null && rows.Count > 1)
                throw new Stopped("找到了多首同名歌曲，请补充歌手。");
            var chosen = rows[0];
            trace?.Write("选中歌曲", "matched", [chosen.Title], detail: chosen.Performer);
            stage = "播放并验证";
            if (!window.Click(results.Bounds, chosen.Title, count: 2))
                throw new Stopped("播放位置已变化，点击已停止。");
            submitted = true;
            progress?.Report($"{player.Name} · 已选中《{song.Title}》，核对播放");
            media.Remember(player);
            var performer = song.Artist ?? chosen.Performer;
            var verified = await Verify(player, window, before, song.Title, performer, trace, token);
            result = verified
                ? new(ResultState.Confirmed, $"{player.Name} 已开始播放 {performer} 的《{song.Title}》。")
                : new(ResultState.Sent, $"已点击 {performer} 的《{song.Title}》。播放器未返回可核对的当前曲目与播放状态。");
        }
        catch (Stopped problem)
        {
            result = new(submitted ? ResultState.Sent : ResultState.Partial, $"{stage} · {problem.Message}");
        }
        catch (OperationCanceledException)
        {
            result = new(submitted ? ResultState.Sent : ResultState.Partial, $"{stage}超时。");
        }
        catch (Exception issue) when (issue is COMException or ElementNotAvailableException or InvalidOperationException or
                                      IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            result = new(submitted ? ResultState.Sent : ResultState.Partial, $"{stage} · {issue.Message}");
        }
        trace?.Write("操作结果", result.State.ToString(), [], detail: result.Message);
        if (trace is { Failed: false })
            return result with { Message = $"{result.Message} 诊断已保存至 {trace.DirectoryPath}" };
        return settings.RecordMusicDiagnostics ? result with { Message = $"{result.Message} 部分或全部诊断未能保存。" } : result;
    }

    private static async Task<MusicWindow> OpenWindow(string executable, CancellationToken token)
    {
        var hwnd = MediaService.FindPlayerWindow(executable);
        if (hwnd == IntPtr.Zero)
            Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true })?.Dispose();
        var until = Stopwatch.StartNew();
        while (until.Elapsed < TimeSpan.FromSeconds(10))
        {
            token.ThrowIfCancellationRequested();
            hwnd = MediaService.FindPlayerWindow(executable);
            if (hwnd != IntPtr.Zero)
            {
                var window = new MusicWindow(hwnd);
                if (window.IsForeground || (MediaService.TryActivate(hwnd) && window.IsForeground))
                    return window;
            }
            await Task.Delay(300, token);
        }
        throw new Stopped("无法把选定播放器切到前台。");
    }

    private static async Task<View?> Wait(MusicWindow window, string? ocr, MusicTrace? trace, string stage,
        Func<View, bool> accepts, TimeSpan limit, CancellationToken token)
    {
        var timer = Stopwatch.StartNew();
        do
        {
            token.ThrowIfCancellationRequested();
            if (!window.IsForeground) throw new Stopped("前台窗口发生变化，已停止输入。");
            var frame = await Read(window, ocr, trace, stage, accepts, token);
            if (frame is not null && accepts(frame)) return frame;
            await Task.Delay(340, token);
        } while (timer.Elapsed < limit);
        return null;
    }

    private static async Task<View?> Read(MusicWindow window, string? ocr, MusicTrace? trace, string stage,
        Func<View, bool> accepts, CancellationToken token, string? detail = null)
    {
        MusicWindow.Frame? native = null;
        try { native = await Task.Run(window.ReadAccessibility, token).WaitAsync(token); }
        catch (Exception failure) when (failure is ElementNotAvailableException or COMException) { }
        var view = native is null ? null : new View(native.Bounds, native.Labels, native.Search);
        if (window.VisibleBounds() is not { } bounds) return null;
        if (view is not null && accepts(view))
        {
            if (trace is not null)
            {
                using var evidence = window.Capture(view.Bounds);
                trace.Write(stage, "UI Automation", view.Labels, evidence, detail);
            }
            return view;
        }
        using var image = ocr is not null || trace is not null ? window.Capture(bounds) : null;
        if (image is null || ocr is null)
        {
            trace?.Write(stage, "UI Automation", view?.Labels ?? [], image, detail);
            return view;
        }
        try
        {
            var text = await MusicOcr.Read(ocr, image, token);
            var labels = (view?.Labels ?? []).Concat(text).Distinct().ToArray();
            trace?.Write(stage, "OCR", labels, image, detail);
            return new(bounds, labels, view?.Search);
        }
        catch (Exception issue) when (issue is IOException || (issue is OperationCanceledException && !token.IsCancellationRequested))
        {
            trace?.Write(stage, "OCR", view?.Labels ?? [], image, issue.Message);
            return view;
        }
    }

    private async Task<Playback?> Snapshot(Player player)
    {
        try
        {
            var session = await media.FindSession(player);
            if (session is null) return null;
            var track = await session.TryGetMediaPropertiesAsync();
            var status = session.GetPlaybackInfo().PlaybackStatus;
            return new(track?.Title ?? "", track?.Artist ?? "",
                status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing, session.GetTimelineProperties().Position);
        }
        catch (COMException) { return null; }
    }

    private async Task<bool> Verify(Player player, MusicWindow window, Playback? before, string title, string artist,
        MusicTrace? trace, CancellationToken token)
    {
        Playback? last = null;
        for (var attempt = 0; attempt < 12; attempt++)
        {
            await Task.Delay(450, token);
            var current = await Snapshot(player);
            if (current?.Playing != true || !MusicLayout.TitleMatches(current.Title, title) ||
                !MusicLayout.ArtistMatches(current.Artist, artist))
            {
                last = null;
                continue;
            }
            var changed = before is not null && (!before.Playing || !MusicLayout.TitleMatches(before.Title, title) ||
                !MusicLayout.ArtistMatches(before.Artist, artist));
            if (last is not null && (changed || current.Position - last.Position >= TimeSpan.FromMilliseconds(100)))
            {
                if (trace is not null)
                    await Read(window, null, trace, "播放已确认", _ => true, token,
                        $"{current.Artist} · {current.Title} · {current.Position.TotalSeconds:F2}s");
                return true;
            }
            last = current;
        }
        if (trace is not null)
            await Read(window, null, trace, "未确认播放", _ => true, token);
        return false;
    }
}
