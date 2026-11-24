using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using T1Controller;
using Xunit;

namespace T1Controller.Tests;

public sealed class ControllerTests
{
    [Fact]
    public void SwitchingAwayAndBackInvalidatesTheOriginalPlayerRequest()
    {
        var settings = new Settings { CurrentPlayer = "soda" };
        var requestRevision = settings.PlayerSelectionRevision;
        settings.CurrentPlayer = "netease";
        settings.CurrentPlayer = "soda";
        Assert.NotEqual(requestRevision, settings.PlayerSelectionRevision);
        Assert.DoesNotContain(nameof(Settings.PlayerSelectionRevision), JsonSerializer.Serialize(settings));
    }

    [Fact]
    public void ClonedScreensAreMatchedByUniqueModelAndNeverByArrayPosition()
    {
        string?[] devices = ["JQ27F360L", "ANT27VQ"];
        Assert.Equal(1, MonitorIdentity.FindUniqueMatch("JQ27F360L", devices, ["ANT27VQ", "JQ27F360L"]));
        Assert.Null(MonitorIdentity.FindUniqueMatch("JQ27F360L", devices, ["Generic PnP Monitor", "Generic PnP Monitor"]));
        Assert.Null(MonitorIdentity.FindUniqueMatch("JQ27F360L", devices, ["JQ27F360L", null]));
        Assert.Null(MonitorIdentity.FindUniqueMatch("JQ27F360L", ["JQ27F360L", "JQ27F360L"], ["JQ27F360L", "JQ27F360L"]));
        Assert.Null(MonitorIdentity.FindUniqueMatch("JQ27F360L", devices, ["JQ27F360L"]));
    }

    [Fact]
    public void MonitorIdentityReadsTheEdidAndMccsModel()
    {
        var edid = new byte[128];
        Array.Fill(edid, (byte)255, 1, 6);
        edid[57] = 0xfc;
        Encoding.ASCII.GetBytes("JQ27F360L\n   ").CopyTo(edid, 59);
        edid[127] = unchecked((byte)-edid.Take(127).Sum(value => value));
        Assert.Equal("JQ27F360L", MonitorIdentity.EdidModel(edid));
        Assert.Equal("JQ27F360L", MonitorIdentity.CapabilityModel("(prot(monitor)model(JQ27F360L) vcp(60(0F 10)))"));
        Assert.Null(MonitorIdentity.CapabilityModel("(prot(monitor) model(Generic PnP Monitor))"));
        edid[127]++;
        Assert.Null(MonitorIdentity.EdidModel(edid));
    }

    [Fact]
    public void ExclusiveReturnRecognizesKeyboardEnterInMappedPresets()
    {
        Assert.True(RemoteModes.IsReturnKey("key:0D/1C/0"));
        Assert.True(RemoteModes.IsReturnKey("key:0D/1C/2"));
        Assert.False(RemoteModes.IsReturnKey("key:5D/5D/2"));
        Assert.False(RemoteModes.IsReturnKey("hid:000C/000D/02"));
        Assert.False(RemoteModes.RequiresExclusiveReturn(null));
        Assert.False(RemoteModes.RequiresExclusiveReturn(RemoteMode.Native));
        Assert.True(RemoteModes.RequiresExclusiveReturn(RemoteMode.Media));
        Assert.True(RemoteModes.RequiresExclusiveReturn(RemoteMode.Host));
        Assert.True(RemoteModes.RequiresNativeIsolation(RemoteMode.Media, ButtonRole.VolumeUp));
        Assert.True(RemoteModes.RequiresNativeIsolation(RemoteMode.Host, ButtonRole.SwitchHost));
        Assert.True(RemoteModes.RequiresNativeIsolation(RemoteMode.Native, ButtonRole.CycleMode));
        Assert.False(RemoteModes.RequiresNativeIsolation(RemoteMode.Native, ButtonRole.PlayPause));
        Assert.False(RemoteModes.RequiresNativeIsolation(null, ButtonRole.VolumeUp));
    }
    [Fact]
    public void RemotePresetsKeepCommandsAndModeKeySeparate()
    {
        var mode = RemoteMode.Native;
        foreach (var expected in new[] { RemoteMode.Media, RemoteMode.Host, RemoteMode.Native })
        {
            Assert.True(RemoteModes.Allows(ButtonRole.CycleMode, mode, legacyEnabled: false));
            mode = RemoteModes.Next(mode);
            Assert.Equal(expected, mode);
        }
        Assert.Null(RemoteModes.Resolve(ButtonRole.PlayPause, Gesture.Short, RemoteMode.Native, true, true));
        Assert.Equal(ActionKind.TogglePlayback, RemoteModes.Resolve(ButtonRole.PlayPause, Gesture.Short, RemoteMode.Media, false, false));
        Assert.Equal(ActionKind.PreviousTrack, RemoteModes.Resolve(ButtonRole.PreviousTrack, Gesture.Short, RemoteMode.Media, false, false));
        Assert.Null(RemoteModes.Resolve(ButtonRole.PlayPause, Gesture.Short, RemoteMode.Host, true, true));
        Assert.Null(RemoteModes.Resolve(ButtonRole.SwitchHost, Gesture.Short, RemoteMode.Media, true, true));
        Assert.Equal(ActionKind.SwitchOtherHost, RemoteModes.Resolve(ButtonRole.SwitchHost, Gesture.Short, RemoteMode.Host, false, false));
        Assert.Equal(ActionKind.NextPlayer, RemoteModes.Resolve(ButtonRole.Menu, Gesture.Long, RemoteMode.Media, true, true));
        Assert.Equal(ActionKind.SwitchOtherHost, RemoteModes.Resolve(ButtonRole.Menu, Gesture.Long, null, true, false));
        Assert.False(RemoteModes.Conflicts(ButtonRole.PlayPause, ButtonRole.SwitchHost));
        Assert.True(RemoteModes.Conflicts(ButtonRole.CycleMode, ButtonRole.PlayPause));
        Assert.True(RemoteModes.Conflicts(ButtonRole.Mute, ButtonRole.PlayPause));
    }

    [Fact]
    public void HeldKeyDoesNotAcquireAPressAfterModeReset()
    {
        var gestures = new Gestures();
        Assert.Equal(Gesture.Press, gestures.Observe("remote", "ok", true, Tick(10), false));
        gestures.Reset();
        Assert.Equal(Gesture.None, gestures.Observe("remote", "ok", true, Tick(70), false, repeat: true));
        Assert.Equal(Gesture.None, gestures.Observe("remote", "ok", false, Tick(100), false));
        Assert.Equal(Gesture.Press, gestures.Observe("remote", "ok", true, Tick(300), false));
        Assert.Equal(Gesture.Short, gestures.Observe("remote", "ok", false, Tick(450), false));
    }

    public static TheoryData<string, string?, string?, string?, int?, bool> IntentCases()
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "intent-fixtures.json")));
        var result = new TheoryData<string, string?, string?, string?, int?, bool>();
        foreach (var fixture in json.RootElement.EnumerateArray())
        {
            var text = fixture.GetProperty("text").GetString()!;
            var expected = fixture.GetProperty("expected");
            if (expected.ValueKind == JsonValueKind.Null)
            {
                result.Add(text, null, null, null, null, false);
                continue;
            }
            result.Add(text, expected.GetProperty("action").GetString(),
                expected.TryGetProperty("host", out var host) ? host.GetString() : null,
                expected.TryGetProperty("player", out var player) ? player.GetString() : null,
                expected.TryGetProperty("percent", out var percent) ? percent.GetInt32() : null,
                expected.TryGetProperty("displayOnly", out var displayOnly) && displayOnly.GetBoolean());
        }
        return result;
    }

    [Theory]
    [MemberData(nameof(IntentCases))]
    public void ChineseIntentUsesSharedWireContract(string text, string? kind, string? host, string? player, int? percent, bool displayOnly)
    {
        var action = IntentParser.Parse(text);
        if (kind is null)
        {
            Assert.Null(action);
            return;
        }
        Assert.NotNull(action);
        Assert.Equal(kind, JsonNamingPolicy.CamelCase.ConvertName(action.Value.Kind.ToString()));
        Assert.Equal(host, action.Value.Host?.ToString().ToLowerInvariant());
        Assert.Equal(player, action.Value.Player);
        Assert.Equal(percent, action.Value.Volume);
        Assert.Equal(displayOnly, action.Value.DisplayOnly);
    }

    [Fact]
    public void MenuLongPressIgnoresTypematicAndNeverProducesShortPress()
    {
        var gestures = new Gestures();
        Assert.Equal(Gesture.Press, gestures.Observe("a", "menu", true, Tick(100), false));
        Assert.Equal(Gesture.None, gestures.Observe("a", "menu", true, Tick(600), false));
        Assert.Equal(Gesture.Long, gestures.Observe("a", "menu", false, Tick(901), false));
        Assert.Equal(Gesture.None, gestures.Observe("a", "menu", false, Tick(905), false));
    }

    [Fact]
    public void DisconnectAndLostReleaseDoNotProduceAnAction()
    {
        var gestures = new Gestures();
        gestures.Observe("a", "menu", true, Tick(100), false);
        gestures.Observe("b", "menu", true, Tick(100), false);
        gestures.Reset("a");
        Assert.Equal(Gesture.None, gestures.Observe("a", "menu", false, Tick(190), false));
        Assert.Equal(Gesture.Short, gestures.Observe("b", "menu", false, Tick(190), false));
        gestures.Observe("a", "menu", true, Tick(200), false);
        Assert.Equal(Gesture.None, gestures.Observe("a", "menu", false, Tick(20_000), false));
    }

    [Fact]
    public void VolumeRepeatIsRateLimited()
    {
        var gestures = new Gestures();
        Assert.Equal(Gesture.Press, gestures.Observe("a", "volume", true, Tick(100), true));
        Assert.Equal(Gesture.None, gestures.Observe("a", "volume", true, Tick(160), true));
        Assert.Equal(Gesture.Repeat, gestures.Observe("a", "volume", true, Tick(201), true));
        Assert.Equal(Gesture.None, gestures.Observe("a", "volume", true, Tick(265), true));
    }

    [Theory]
    [InlineData("我想听周杰伦的晴天", null, "周杰伦", "晴天")]
    [InlineData("小爱同学，用网易云音乐播放陈奕迅的《十年》", "netease", "陈奕迅", "十年")]
    [InlineData("用汽水音乐播放一首 Taylor Swift 的 Love Story 吧", "soda", "Taylor Swift", "Love Story")]
    [InlineData("播放《夜空中最亮的星》，逃跑计划演唱的", null, "逃跑计划", "夜空中最亮的星")]
    [InlineData("播放《暂停》", null, null, "暂停")]
    public void SongIntentPreservesProviderArtistAndTitle(string voice, string? player, string? singer, string title)
    {
        Assert.Equal(new ControllerAction(ActionKind.PlaySong, Player: player, Title: title, Artist: singer),
            IntentParser.Parse(voice));
        Assert.Null(IntentParser.Parse("不要播放周杰伦的晴天"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SongResultsRejectCoverAndMatchOnlyTheArtistsInTheirOwnRows(bool soda)
    {
        static MusicText At(string text, double x, double y) => new(text, new(x, y, .055, .021));
        var labels = new[]
        {
            At("搜索 周杰伦 晴天", .24, .114), At("综合", .24, .194),
            At(soda ? "歌曲" : "单曲", .31, .194), At("歌单", .40, .194),
            At(soda ? "歌曲" : "标题", .31, .31), At("专辑", .66, .31),
            At("晴天（原唱：周杰伦）", .32, .42),
            At("晴天", .32, .51), At("晴天 VIP", .32, .60)
        }.Concat(soda
            ? [At("歌手", .49, .31), At("翻唱歌手", .49, .42), At("另一位歌手", .49, .51), At("周杰伦", .49, .60)]
            : new[] { At("翻唱歌手", .32, .443), At("另一位歌手", .32, .533), At("周杰伦", .32, .623) });

        Assert.True(MusicLayout.ShowsResults(labels, "周杰伦 晴天"));
        var match = Assert.Single(MusicLayout.Rows(labels, "晴天", "周杰伦", soda));
        Assert.Equal("晴天 VIP", match.Title.Text);
        Assert.Empty(MusicLayout.Rows(labels, "晴天", "周杰伦乐队", soda));
        Assert.Equal(2, MusicLayout.Rows(labels, "晴天", null, soda).Count);
    }

    private static long Tick(int milliseconds) => (long)(milliseconds * Stopwatch.Frequency / 1000.0);
}
