using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace T1Controller;

internal static partial class IntentParser
{
    private static readonly IReadOnlyDictionary<string, ControllerAction> Commands = new Dictionary<string, ControllerAction>
    {
        ["播放"] = new(ActionKind.Play), ["开始播放"] = new(ActionKind.Play), ["继续播放"] = new(ActionKind.Play),
        ["暂停"] = new(ActionKind.Pause), ["暂停播放"] = new(ActionKind.Pause), ["停止播放"] = new(ActionKind.Pause),
        ["上一首"] = new(ActionKind.PreviousTrack), ["上一曲"] = new(ActionKind.PreviousTrack),
        ["下一首"] = new(ActionKind.NextTrack), ["下一曲"] = new(ActionKind.NextTrack),
        ["调大音量"] = new(ActionKind.VolumeUp), ["音量加大"] = new(ActionKind.VolumeUp),
        ["调小音量"] = new(ActionKind.VolumeDown), ["音量减小"] = new(ActionKind.VolumeDown),
        ["静音切换"] = new(ActionKind.ToggleMute), ["切换静音"] = new(ActionKind.ToggleMute),
        ["切换音乐软件"] = new(ActionKind.NextPlayer), ["切换播放器"] = new(ActionKind.NextPlayer),
        ["切到下一个播放器"] = new(ActionKind.NextPlayer),
        ["打开网易云音乐"] = new(ActionKind.OpenPlayer, Player: "netease"),
        ["打开网易云"] = new(ActionKind.OpenPlayer, Player: "netease"),
        ["打开汽水音乐"] = new(ActionKind.OpenPlayer, Player: "soda"),
        ["切换主机"] = new(ActionKind.SwitchOtherHost), ["切到另一台主机"] = new(ActionKind.SwitchOtherHost)
    };

    public static ControllerAction? Parse(string text)
    {
        if (text.IndexOfAny(['《', '〈', '「', '“', '"']) >= 0 && ParseSong(text, requireQuoted: true) is { } quoted)
            return quoted;
        var normalized = Punctuation().Replace(text.Normalize(NormalizationForm.FormKC).ToLowerInvariant(), "");
        normalized = Prefix().Replace(normalized, "");
        if (Commands.TryGetValue(normalized, out var action))
            return action;
        if (Recommendations().IsMatch(normalized))
            return new(ActionKind.PlayDailyRecommendations);

        var display = DisplayCommand().Match(normalized);
        if (display.Success)
            return new(ActionKind.SwitchHost, Host: ParseHost(display.Groups[1].Value), DisplayOnly: true);

        var target = HostCommand().Match(normalized);
        if (target.Success)
            return new(ActionKind.SwitchHost, Host: ParseHost(target.Groups[1].Value));

        var volume = VolumeCommand().Match(normalized);
        if (!volume.Success)
            return ParseSong(text);
        var number = volume.Groups[1].Value;
        var percentage = int.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out var digits)
            ? digits : ParseChineseNumber(number);
        return percentage is >= 0 and <= 100 ? new(ActionKind.SetVolume, Volume: percentage) : null;
    }

    private static ControllerAction? ParseSong(string utterance, bool requireQuoted = false)
    {
        var text = CleanPhrase(utterance.Normalize(NormalizationForm.FormKC));
        foreach (var greeting in new[] { "小爱同学", "小愛同學", "你好飞鼠", "你好飛鼠", "麻烦帮我", "请帮我", "帮我", "請幫我", "请", "請" })
            if (text.StartsWith(greeting, StringComparison.Ordinal))
                text = CleanPhrase(text[greeting.Length..]);

        string? player = null;
        foreach (var prefix in new[] { "打开网易云音乐", "打开网易云", "用网易云音乐", "用网易云",
                     "在网易云音乐", "在网易云", "打开汽水音乐", "用汽水音乐", "在汽水音乐" })
        {
            if (!text.StartsWith(prefix, StringComparison.Ordinal)) continue;
            player = prefix.Contains("汽水", StringComparison.Ordinal) ? "soda" : "netease";
            text = CleanPhrase(text[prefix.Length..]);
            foreach (var join in new[] { "然后", "并且", "并", "再" })
                if (text.StartsWith(join, StringComparison.Ordinal))
                {
                    text = CleanPhrase(text[join.Length..]);
                    break;
                }
            break;
        }

        var verb = SongVerb().Match(text);
        if (!verb.Success) return null;
        var phrase = CleanPhrase(text[verb.Length..]);
        foreach (var suffix in new[] { "谢谢", "吧", "一下", "这首歌曲", "这首曲子", "这首歌" })
            if (phrase.EndsWith(suffix, StringComparison.Ordinal))
                phrase = CleanPhrase(phrase[..^suffix.Length]);
        if (phrase.StartsWith("一首", StringComparison.Ordinal) || phrase.StartsWith("一曲", StringComparison.Ordinal))
            phrase = CleanPhrase(phrase[2..]);

        string? title = null;
        string? artist = null;
        foreach (var (open, close) in new (char, char)[] { ('《', '》'), ('〈', '〉'), ('「', '」'), ('“', '”'), ('"', '"') })
        {
            var first = phrase.IndexOf(open);
            var last = phrase.LastIndexOf(close);
            if (first < 0 || last <= first) continue;
            var before = CleanPhrase(phrase[..first]);
            var after = CleanPhrase(phrase[(last + 1)..]);
            if (before.Length != 0 && after.Length != 0) continue;
            artist = before.Length > 0 ? Performer(before, true) : Performer(after, false);
            if ((before.Length > 0 || after.Length > 0) && artist is null) continue;
            title = CleanPhrase(phrase[(first + 1)..last]);
            break;
        }

        if (title is null)
        {
            if (requireQuoted) return null;
            var separator = phrase.LastIndexOfAny([',', '，', '、']);
            if (separator >= 0 && Performer(CleanPhrase(phrase[(separator + 1)..]), false) is { } trailing)
            {
                artist = trailing;
                title = CleanPhrase(phrase[..separator]);
            }
            else
            {
                var possessive = phrase.IndexOf('的');
                if (possessive > 0 && possessive < phrase.Length - 1)
                {
                    artist = Performer(CleanPhrase(phrase[..(possessive + 1)]), true);
                    if (artist is not null) title = CleanPhrase(phrase[(possessive + 1)..]);
                }
                title ??= phrase;
            }
        }

        if (title.Length is 0 or > 120 || artist?.Length > 80 ||
            title is "歌" or "曲" or "歌曲" or "音乐" or "一首歌" or "一些歌" or "几首歌" or "随便一首歌")
            return null;
        return new(ActionKind.PlaySong, Player: player, Title: title, Artist: artist);
    }

    private static string? Performer(string value, bool allowPossessive)
    {
        var marker = value.EndsWith("演唱的", StringComparison.Ordinal) ? "演唱的" :
            value.EndsWith("唱的", StringComparison.Ordinal) ? "唱的" :
            allowPossessive && value.EndsWith("的", StringComparison.Ordinal) ? "的" : null;
        if (marker is null) return null;
        var name = CleanPhrase(value[..^marker.Length]).Trim('"', '“', '”', '《', '》', '「', '」');
        if (marker != "的" && name.StartsWith('由')) name = CleanPhrase(name[1..]);
        return name.Length == 0 ? null : name;
    }

    private static string CleanPhrase(string text) => text.Trim().Trim(',', '，', '、', ':', '：',
        '.', '。', '!', '！', '?', '？', ';', '；').Trim();

    private static Host ParseHost(string name) =>
        name.StartsWith("win", StringComparison.Ordinal) ? Host.Windows : Host.Mac;

    private static int ParseChineseNumber(string input)
    {
        const string digits = "零一二三四五六七八九";
        if (input is "一百" or "百")
            return 100;
        if (input.Length == 1)
            return input == "十" ? 10 : digits.IndexOf(input[0]);
        var tensIndex = input.IndexOf('十');
        if (tensIndex is < 0 or > 1 || input.Length - tensIndex > 2)
            return -1;
        var tens = tensIndex == 0 ? 1 : digits.IndexOf(input[0]);
        var ones = input.Length == tensIndex + 1 ? 0 : digits.IndexOf(input[^1]);
        return tens > 0 && ones >= 0 ? tens * 10 + ones : -1;
    }

    [GeneratedRegex(@"[\s，,。！!？?、；;：:]+")]
    private static partial Regex Punctuation();
    [GeneratedRegex(@"^(?:小爱同学|小愛同學|你好飞鼠|你好飛鼠)?(?:请|請)?(?:帮我|幫我)?")]
    private static partial Regex Prefix();
    [GeneratedRegex(@"^(?:(?:打开|用)网易云(?:音乐)?(?:然后|并且|并|再)?)?(?:(?:开始)?播放(?:今天的?|今日|每日)(?:歌曲)?推荐(?:的?(?:歌曲|歌|音乐))?|打开(?:今日|每日)推荐播放)$")]
    private static partial Regex Recommendations();
    [GeneratedRegex(@"^(?:切到|切换到|切换至)(windows|win|macmini|mac)(?:主机|电脑)?$")]
    private static partial Regex HostCommand();
    [GeneratedRegex(@"^(?:只切画面到|仅切画面到|把画面切到|画面切到|切换显示器到)(windows|win|macmini|mac|苹果电脑)$")]
    private static partial Regex DisplayCommand();
    [GeneratedRegex(@"^(?:把)?音量(?:调到|设置为|设为|调至)(?:百分之)?([0-9零一二三四五六七八九十百]+)%?$")]
    private static partial Regex VolumeCommand();
    [GeneratedRegex(@"^(?:开始播放|播放一下|播放一首|放一首|我想听听|我想听|想听|播放)")]
    private static partial Regex SongVerb();
}
