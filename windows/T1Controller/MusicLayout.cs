using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace T1Controller;

internal readonly record struct MusicBox(double X, double Y, double Width, double Height)
{
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;
    public double Right => X + Width;
}

internal sealed record MusicText(string Text, MusicBox Bounds)
{
    public string Name { get; } = MusicLayout.Normalize(Text);
}

internal sealed record SongRow(MusicText Title, string Performer);

internal static class MusicLayout
{
    private static readonly string[] Badges = ["超清母带", "臻品音质", "无损", "独家", "svip", "vip", "原唱", "sq"];

    public static string Normalize(string text)
    {
        var output = new StringBuilder(text.Length);
        foreach (var rune in text.Normalize(NormalizationForm.FormKC).ToLowerInvariant().EnumerateRunes())
            if (Rune.IsLetterOrDigit(rune)) output.Append(rune.ToString());
        return output.ToString();
    }

    public static string Query(ControllerAction song) => song.Artist is { Length: > 0 }
        ? $"{song.Artist} {song.Title}" : song.Title ?? "";

    public static bool TitleMatches(string value, string expected) =>
        StripBadges(Normalize(value), fromEnd: true) == Normalize(expected) || Normalize(value) == Normalize(expected);

    public static bool ArtistMatches(string value, string expected)
    {
        var want = Normalize(expected);
        if (Normalize(value) == want) return true;
        // A search hit mentioning an original performer in the title is never used as an artist credit.
        return value.Split(['/', '／', '、', '&', '＆', '；'], StringSplitOptions.RemoveEmptyEntries)
            .Select(part => StripBadges(Normalize(part), fromEnd: false))
            .Contains(want);
    }

    public static bool IsSearchHint(string text)
    {
        var label = Normalize(text);
        return label is "搜索" or "搜索音乐" or "音乐搜索" or "搜索歌曲" or "搜索歌曲歌手专辑" or
            "歌手歌曲或专辑名" or "搜索歌手歌曲专辑" or "search" or "searchmusic" or "搜索音乐视频歌词电台";
    }

    public static MusicText? SearchAnchor(IEnumerable<MusicText> labels)
    {
        var known = labels.Where(item => IsSearchHint(item.Text) && item.Bounds.MidY < .17).ToArray();
        return UniqueLocation(known);
    }

    public static MusicText? TrackTab(IEnumerable<MusicText> labels, bool soda)
    {
        var all = labels.ToArray();
        var title = soda ? "歌曲" : "单曲";
        var tabs = all.Where(item => item.Name == title && item.Bounds.MidY is > .09 and < .40 &&
            all.Any(other => other.Name is "综合" or "全部" or "音乐人" or "歌单" &&
                Math.Abs(other.Bounds.MidY - item.Bounds.MidY) < .018));
        return UniqueLocation(tabs);
    }

    public static bool ShowsResults(IEnumerable<MusicText> labels, string query)
    {
        var expected = Normalize(query);
        return expected.Length > 0 && labels.Any(item => item.Bounds.MidX > .15 && item.Bounds.MidY is > .075 and < .32 &&
            (item.Name == expected || item.Name == "搜索" + expected || item.Name == "搜索结果" + expected));
    }

    public static IReadOnlyList<SongRow> Rows(IEnumerable<MusicText> labels, string title, string? artist, bool soda)
    {
        var all = labels.ToArray();
        var tab = TrackTab(all, soda);
        if (tab is null) return [];
        var header = all.Where(item => item.Name is "标题" or "歌曲" or "歌名" &&
            item.Bounds.X > .13 && item.Bounds.X < .55 &&
            item.Bounds.MidY - tab.Bounds.MidY is > .025 and < .22)
            .MinBy(item => item.Bounds.MidY);
        if (header is null) return [];
        var creditHeader = all.Where(item => item.Name is "歌手" or "音乐人" or "艺术家" &&
            item.Bounds.X > header.Bounds.X + .09 && Math.Abs(item.Bounds.MidY - header.Bounds.MidY) < .021)
            .MinBy(item => item.Bounds.X);
        var albumHeader = all.Where(item => item.Name is "专辑" or "时长" &&
            item.Bounds.X > (creditHeader?.Bounds.X ?? header.Bounds.X) + .08 &&
            Math.Abs(item.Bounds.MidY - header.Bounds.MidY) < .021)
            .MinBy(item => item.Bounds.X);
        if (soda && creditHeader is null) return [];

        var rows = new List<SongRow>();
        foreach (var label in all.OrderBy(item => item.Bounds.MidY))
        {
            if (!TitleMatches(label.Text, title) || label.Bounds.MidY < header.Bounds.MidY + .022 ||
                label.Bounds.MidY >= .876 || label.Bounds.X < header.Bounds.X - .03 ||
                label.Bounds.X >= (creditHeader?.Bounds.X - .032 ?? header.Bounds.X + .17))
                continue;
            var credits = all.Where(item => creditHeader is not null
                ? Math.Abs(item.Bounds.MidY - label.Bounds.MidY) < .023 &&
                    item.Bounds.X >= creditHeader.Bounds.X - .024 &&
                    item.Bounds.X < (albumHeader?.Bounds.X - .023 ?? creditHeader.Bounds.X + .19)
                : item.Bounds.MidY - label.Bounds.MidY is > .009 and < .043 &&
                    item.Bounds.X >= label.Bounds.X - .018 && item.Bounds.X < label.Bounds.X + .19 &&
                    !all.Any(next => next != label && Math.Abs(next.Bounds.X - label.Bounds.X) < .06 &&
                        next.Bounds.MidY > label.Bounds.MidY + .022 && next.Bounds.MidY <= item.Bounds.MidY + .003 &&
                        TitleMatches(next.Text, title)))
                .Where(item => !IsBadge(item.Name))
                .ToArray();

            // Adjacent chromed text from the performer column can include release badges.
            var performer = artist is null ? UniqueLocation(credits) :
                credits.FirstOrDefault(item => ArtistMatches(item.Text, artist));
            if (performer is not null && !rows.Any(row => Math.Abs(row.Title.Bounds.MidY - label.Bounds.MidY) < .015))
                rows.Add(new(label, performer.Text));
        }
        return rows;
    }

    private static bool IsBadge(string label) => label.Length == 0 || Badges.Contains(label);

    private static string StripBadges(string value, bool fromEnd)
    {
        while (Badges.FirstOrDefault(badge => fromEnd ? value.EndsWith(badge, StringComparison.Ordinal) :
                   value.StartsWith(badge, StringComparison.Ordinal)) is { } badge)
            value = fromEnd ? value[..^badge.Length] : value[badge.Length..];
        return value;
    }

    private static MusicText? UniqueLocation(IEnumerable<MusicText> labels)
    {
        var distinct = new List<MusicText>();
        foreach (var label in labels.OrderBy(item => item.Bounds.Width))
            if (!distinct.Any(item => Math.Abs(item.Bounds.MidY - label.Bounds.MidY) < .015 &&
                Math.Abs(item.Bounds.MidX - label.Bounds.MidX) < .045))
                distinct.Add(label);
        return distinct.Count == 1 ? distinct[0] : null;
    }
}
