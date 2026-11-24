import Foundation

public enum IntentParser {
    private static let greetings = ["小爱同学", "你好飞鼠", "请帮我", "麻烦帮我", "帮我", "请"]
    private static let politeSuffixes = ["一下", "谢谢", "吧"]
    private static let neteasePrefixes = ["打开网易云音乐", "打开网易云", "用网易云音乐", "用网易云"]
    private static let sodaPrefixes = ["打开汽水音乐", "用汽水音乐", "在汽水音乐"]
    private static let songQuotes: [(Character, Character)] = [("《", "》"), ("〈", "〉"), ("「", "」"), ("“", "”"), ("\"", "\"")]
    private static let phraseSeparators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "，,、：:。．.!！?？；;")
    )

    public static func addressesXiaoAI(_ transcript: String) -> Bool {
        let text = transcript.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? transcript
        return text.trimmingCharacters(in: phraseSeparators).hasPrefix("小爱同学")
    }

    public static func parse(_ transcript: String) -> ControllerAction? {
        let simplified = transcript.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
            ?? transcript
        if songQuotes.contains(where: { simplified.contains($0.0) }),
           let song = namedSong(simplified, requiresQuotedTitle: true) { return song }
        var text = simplified.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
            (!CharacterSet.punctuationCharacters.contains($0) || "-‐‑–—－.．%％".unicodeScalars.contains($0))
        }.map(String.init).joined()
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".．"))

        for prefix in greetings where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        for suffix in politeSuffixes where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }

        switch text {
        case "播放", "开始播放", "继续播放", "继续": return .play
        case "暂停", "暂停播放", "停止播放": return .pause
        case "播放暂停": return .togglePlayback
        case "上一首", "上一曲", "切到上一首": return .previousTrack
        case "下一首", "下一曲", "切歌", "切到下一首": return .nextTrack
        case "大声一点", "声音大一点", "调大音量", "音量加": return .volumeUp
        case "小声一点", "声音小一点", "调小音量", "音量减": return .volumeDown
        case "切换静音": return .toggleMute
        case "切换播放器", "切换音乐软件", "下一个播放器": return .nextPlayer
        case "打开网易云", "打开网易云音乐", "切到网易云", "切到网易云音乐":
            return .openPlayer("netease")
        case "打开汽水音乐", "切到汽水音乐":
            return .openPlayer(SongPlayer.soda.bundleID)
        case "切到mac", "切到macmini", "切换到mac", "切换到macmini", "切到苹果电脑", "切到麦克":
            return .switchHost(.mac)
        case "切到windows", "切换到windows", "切到win", "切换到win", "切到温豆思":
            return .switchHost(.windows)
        case "切换主机", "切到另一台", "切到另一台电脑", "切换电脑": return .switchOtherHost
        default: break
        }

        for prefix in ["只切画面到", "仅切画面到", "把画面切到", "画面切到", "切换显示器到"] where text.hasPrefix(prefix) {
            switch text.dropFirst(prefix.count) {
            case "mac", "macmini", "苹果电脑": return .switchDisplay(.mac)
            case "windows", "win": return .switchDisplay(.windows)
            default: return nil
            }
        }

        for prefix in neteasePrefixes where text.hasPrefix(prefix) {
            var remainder = String(text.dropFirst(prefix.count))
            if let connector = ["然后", "并且", "并", "再"].first(where: { remainder.hasPrefix($0) }) {
                remainder.removeFirst(connector.count)
            }
            if isDailyRequest(remainder) { return .playDailyRecommendations }
        }
        if isDailyRequest(text) { return .playDailyRecommendations }

        for prefix in ["把音量调到", "把音量设为", "音量调到", "音量设为", "音量设置为", "音量到"] where text.hasPrefix(prefix) {
            let amount = String(text.dropFirst(prefix.count))
            if let percent = percentage(amount) { return .setVolume(percent) }
        }
        return namedSong(simplified)
    }

    private static func isDailyRequest(_ text: String) -> Bool {
        let names = ["今日推荐", "今天的推荐", "每日推荐", "每日歌曲推荐",
                     "今日推荐的歌曲", "今天推荐的歌曲", "每日推荐的歌曲", "每日推荐歌曲"]
        if ["打开今日推荐播放", "打开每日推荐播放"].contains(text) { return true }
        return ["播放", "开始播放"].contains { prefix in
            names.contains { text == prefix + $0 }
        }
    }

    private static func namedSong(_ transcript: String, requiresQuotedTitle: Bool = false) -> ControllerAction? {
        var text = trimPhrase(transcript)
        for prefix in greetings where text.hasPrefix(prefix) {
            text = trimPhrase(text.dropFirst(prefix.count))
        }
        var player: SongPlayer?
        let providers: [(SongPlayer, [String])] = [(.netease, neteasePrefixes + ["在网易云音乐", "在网易云"]),
                                                    (.soda, sodaPrefixes)]
        for (candidate, prefixes) in providers {
            guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { continue }
            player = candidate
            text = trimPhrase(text.dropFirst(prefix.count))
            if let connector = ["然后", "并且", "并", "再"].first(where: { text.hasPrefix($0) }) {
                text = trimPhrase(text.dropFirst(connector.count))
            }
            break
        }
        guard let command = ["开始播放", "播放一下", "播放", "放一首", "我想听", "想听"]
            .first(where: { text.hasPrefix($0) }) else { return nil }
        var phrase = trimPhrase(text.dropFirst(command.count))
        if let count = ["一首", "一曲"].first(where: { phrase.hasPrefix($0) }) {
            phrase = trimPhrase(phrase.dropFirst(count.count))
        }
        for suffix in politeSuffixes.reversed() where phrase.hasSuffix(suffix) {
            phrase = trimPhrase(phrase.dropLast(suffix.count))
        }
        if isDailyRequest("播放" + phrase) { return player == .soda ? nil : .playDailyRecommendations }
        if let suffix = ["这首歌曲", "这首歌", "这首曲子"].first(where: { phrase.hasSuffix($0) }) {
            phrase = trimPhrase(phrase.dropLast(suffix.count))
        }

        guard let song = songComponents(phrase, requiresQuotedTitle: requiresQuotedTitle) else { return nil }
        let title = song.title
        guard !title.isEmpty, title.count <= 120, (song.artist?.count ?? 0) <= 80,
              !["歌", "歌曲", "音乐", "一首歌", "一首歌曲", "一些歌", "几首歌", "随便一首歌"].contains(title) else {
            return nil
        }
        return .playSong(title: title, artist: song.artist, player: player)
    }

    private static func songComponents(_ phrase: String, requiresQuotedTitle: Bool) -> (title: String, artist: String?)? {
        for (opening, closing) in songQuotes {
            guard let start = phrase.firstIndex(of: opening), let end = phrase.lastIndex(of: closing),
                  start < end else { continue }
            let title = String(phrase[phrase.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let leading = trimPhrase(phrase[..<start])
            let trailing = trimPhrase(phrase[phrase.index(after: end)...])
            if trailing.isEmpty {
                if leading.isEmpty { return (title, nil) }
                if let artist = performedBy(leading, allowPossessive: true) { return (title, artist) }
            } else if leading.isEmpty, let artist = performedBy(trailing) {
                return (title, artist)
            }
        }

        guard !requiresQuotedTitle else { return nil }
        if let comma = phrase.lastIndex(where: { "，,、".contains($0) }),
           let artist = performedBy(trimPhrase(phrase[phrase.index(after: comma)...])) {
            return (trimPhrase(phrase[..<comma]), artist)
        }
        if let possessive = phrase.firstIndex(of: "的"),
           let artist = performedBy(trimPhrase(phrase[...possessive]), allowPossessive: true) {
            let title = trimPhrase(phrase[phrase.index(after: possessive)...])
            if !title.isEmpty { return (title, artist) }
        }
        return (phrase, nil)
    }

    private static func performedBy(_ phrase: String, allowPossessive: Bool = false) -> String? {
        let suffixes = allowPossessive ? ["演唱的", "唱的", "的"] : ["演唱的", "唱的"]
        guard let suffix = suffixes.first(where: { phrase.hasSuffix($0) }) else { return nil }
        var artist = trimPhrase(phrase.dropLast(suffix.count))
        if suffix != "的", artist.hasPrefix("由") { artist = trimPhrase(artist.dropFirst()) }
        if artist.count >= 2, songQuotes.contains(where: { artist.first == $0.0 && artist.last == $0.1 }) {
            artist = String(artist.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return artist.isEmpty ? nil : artist
    }

    private static func trimPhrase(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: phraseSeparators)
    }

    private static func percentage(_ text: String) -> Int? {
        let withoutPrefix = text.hasPrefix("百分之") ? String(text.dropFirst(3)) : text
        let token = withoutPrefix.last.map { "%％".contains($0) } == true
            ? String(withoutPrefix.dropLast()) : withoutPrefix
        let digits = token.compactMap(\.wholeNumberValue)
        if !digits.isEmpty, digits.count == token.count, digits.allSatisfy({ $0 < 10 }),
           let n = Int(digits.map(String.init).joined()), (0...100).contains(n) {
            return n
        }
        if token == "一百" { return 100 }
        let chinese = "零一二三四五六七八九"
        let pieces = token.split(separator: "十", omittingEmptySubsequences: false)
        if pieces.count == 1, let digit = token.first, token.count == 1 {
            return chinese.firstIndex(of: digit).map { chinese.distance(from: chinese.startIndex, to: $0) }
        }
        guard pieces.count == 2, pieces.allSatisfy({ $0.count <= 1 }) else { return nil }
        let tens = pieces[0].first.flatMap { chinese.firstIndex(of: $0) }
            .map { chinese.distance(from: chinese.startIndex, to: $0) } ?? (pieces[0].isEmpty ? 1 : -1)
        let ones = pieces[1].first.flatMap { chinese.firstIndex(of: $0) }
            .map { chinese.distance(from: chinese.startIndex, to: $0) } ?? (pieces[1].isEmpty ? 0 : -1)
        return tens > 0 && ones >= 0 ? tens * 10 + ones : nil
    }
}
