import AppKit
import CoreAudio
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

@MainActor
public final class MusicDesktopAgent {
    public enum Request: Sendable {
        case open
        case daily
        case prepareDaily
        case song(title: String, artist: String?)
    }

    public init() {}

    public nonisolated static let ocrWorkerArgument = "--read-music-window"

    // Both executables use this entry point so a diagnostic run exercises the same Vision worker.
    public static func runOCRWorker(arguments: [String]) -> Int32? {
        guard arguments.first == ocrWorkerArgument else { return nil }
        let rasterURL: URL?
        switch arguments.count {
        case 1: rasterURL = nil
        case 3 where arguments[1] == "--trace-raster":
            rasterURL = URL(fileURLWithPath: arguments[2])
        default: return 64
        }
        do {
            let input = FileHandle.standardInput
            var data = Data()
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 26_000_000 else { return 1 }
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width <= 2_400, image.height <= 2_400 else { return 1 }
            let labels = try MusicScreen.recognize(image, traceRaster: rasterURL)
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(labels))
            return 0
        } catch {
            return 1
        }
    }

    public static func screenCaptureAvailable() -> Bool { CGPreflightScreenCaptureAccess() }

    public static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    public func run(
        _ request: Request, player: PlayerProfile = .netease,
        recordingIn directory: URL? = nil, progress: (String) -> Void = { _ in }
    ) async -> PlatformResult {
        let trace = directory.map(MusicWindowTrace.init)
        let result = await execute(request, player: player, trace: trace, progress: progress)
        trace?.event(stage: "操作结果", detail: result.message)
        return result
    }

    public func inspectWindow(_ player: PlayerProfile, recordingIn directory: URL) async -> PlatformResult {
        let trace = MusicWindowTrace(directory)
        let result: PlatformResult
        if !Self.screenCaptureAvailable() {
            result = .init(.unavailable, "当前诊断进程没有录屏权限。")
        } else if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: player.bundleID
        ).first {
            do {
                let captured = try await MusicScreen.read(pid: app.processIdentifier, player: player, trace: trace,
                                                          stage: "当前\(player.name)窗口")
                result = captured == nil
                    ? .init(.unavailable, "未取得可用的\(player.name)窗口图像。")
                    : .init(.confirmed, "已读取\(player.name)窗口和识别结果。")
            } catch {
                result = .init(.unavailable, error.localizedDescription)
            }
        } else {
            result = .init(.unavailable, "\(player.name)未运行。")
        }
        trace.event(stage: "采集结果", detail: result.message)
        return result
    }

    public static func inspectImage(_ input: URL, recordingIn directory: URL) async -> PlatformResult {
        let trace = MusicWindowTrace(directory)
        let stage = "对照图片重放"
        do {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_400
                  ] as CFDictionary) else { throw MusicFrameError.capture }
            let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let (_, screen) = try await MusicScreen.readFrame(
                stage: stage, source: "对照图片", frame: frame, windowID: 0, pid: 0, trace: trace
            ) { image }
            trace.event(stage: stage, detail: "重放得到 \(screen.labels.count) 条文字")
            return .init(.confirmed, "已记录对照图片的识别结果。")
        } catch {
            trace.event(stage: stage, detail: error.localizedDescription)
            return .init(.unavailable, error.localizedDescription)
        }
    }

    private func execute(
        _ request: Request, player: PlayerProfile, trace: MusicWindowTrace?, progress: (String) -> Void
    ) async -> PlatformResult {
        guard PlayerController.accessibilityAvailable(), CGPreflightPostEventAccess() else {
            return .init(.unavailable, "请在音乐页开启辅助功能权限，让智能体操作播放器窗口。")
        }
        switch request {
        case .open: break
        case .daily, .prepareDaily:
            guard player == .netease else { return .init(.unavailable, "每日推荐操作适用于网易云音乐。") }
            fallthrough
        case .song:
            guard Self.screenCaptureAvailable() else {
                return .init(.unavailable, "请在音乐页开启屏幕录制权限，让智能体读取播放器窗口。")
            }
            guard PlayerProfile.songSearchPlayers.contains(player) else {
                return .init(.unavailable, "\(player.name)尚未适配语音点歌。")
            }
        }
        do {
            progress("智能体正在打开\(player.name)")
            let app = try await MusicAgentDesktop.bringToFront(player)
            let pid = app.processIdentifier
            switch request {
            case .open:
                return .init(.confirmed, "智能体已打开\(player.name)。")
            case .daily:
                return try await playDaily(pid: pid, trace: trace, progress: progress)
            case .prepareDaily:
                _ = try await dailyPlayTarget(pid: pid, trace: trace)
                return .init(.confirmed, "已打开网易云每日推荐，播放按钮可用。")
            case .song(let title, let artist):
                return try await playSong(title: title, artist: artist, player: player,
                                          pid: pid, trace: trace, progress: progress)
            }
        } catch is CancellationError {
            return .init(.unavailable, "播放器智能体操作已取消。")
        } catch {
            return .init(.unavailable, error.localizedDescription)
        }
    }

    private func playDaily(
        pid: pid_t, trace: MusicWindowTrace?, progress: (String) -> Void
    ) async throws -> PlatformResult {
        progress("智能体正在查找每日推荐")
        let (daily, button) = try await dailyPlayTarget(pid: pid, trace: trace)
        let audioWasRunning = audioOutputRunning(pid: pid)
        progress("智能体正在点击播放全部并检查播放进度")
        try await daily.click(button)
        return try await verifyPlayback(
            pid: pid, previous: daily.playback, title: nil, audioWasRunning: audioWasRunning, trace: trace
        )
    }

    private func dailyPlayTarget(pid: pid_t, trace: MusicWindowTrace?) async throws -> (MusicScreen, MusicLabel) {
        let daily = try await openDaily(pid: pid, trace: trace)
        guard let button = daily.playAllButton else {
            throw AgentIssue("已进入每日推荐歌曲列表，但未识别到唯一的「播放全部」按钮。")
        }
        return (daily, button)
    }

    private func openDaily(pid: pid_t, trace: MusicWindowTrace?) async throws -> MusicScreen {
        let first = try await awaitScreen(pid: pid, trace: trace, message: "网易云窗口未显示推荐入口。") {
            $0.isDaily || $0.dailyCard != nil || $0.recommendationTab != nil
        }
        if first.isDaily { return first }
        let home: MusicScreen
        if first.dailyCard == nil, let tab = first.recommendationTab {
            try await first.click(tab)
            try await first.scrollRecommendationUp()
            home = try await awaitScreen(pid: pid, trace: trace, message: "推荐首页上未找到「每日推荐」卡片。") {
                $0.dailyCard != nil || $0.isDaily
            }
            if home.isDaily { return home }
        } else {
            home = first
        }
        guard let card = home.dailyCard else {
            throw AgentIssue("推荐首页上未找到唯一的「每日推荐」卡片。")
        }
        try await home.click(card)
        return try await awaitScreen(pid: pid, trace: trace, message: "已点击每日推荐卡片，但网易云未切换到歌曲列表。") {
            $0.isDaily
        }
    }

    private func playSong(
        title: String, artist: String?, player: PlayerProfile,
        pid: pid_t, trace: MusicWindowTrace?, progress: (String) -> Void
    ) async throws -> PlatformResult {
        let query = [artist, title].compactMap { $0 }.joined(separator: " ")
        progress("智能体正在搜索「\(query)」")
        trace?.event(stage: "查找搜索框", detail: "\(player.name) · \(query)")
        let initial = try await awaitScreen(pid: pid, player: player, trace: trace, message: "未找到\(player.name)的搜索框。") {
            $0.searchField != nil
        }
        guard let field = initial.searchField else { throw AgentIssue("未找到\(player.name)的搜索框。") }
        try await initial.click(field)
        let beforeSubmit: (() async -> Void)? = trace.map { trace in
            { _ = try? await MusicScreen.read(pid: pid, player: player, trace: trace, stage: "输入搜索词后") }
        }
        try await MusicAgentDesktop.replaceSearchText(query, pid: pid,
            requiredPlaceholder: player == .soda ? MusicScreen.sodaSearchPlaceholder : nil, beforeSubmit: beforeSubmit)
        let search = try await awaitScreen(pid: pid, player: player, trace: trace, message: "未看到「\(query)」的搜索结果。") {
            $0.showsSearch(query) && $0.songsTab != nil
        }
        guard let tab = search.songsTab else { throw AgentIssue("未找到搜索结果的歌曲标签。") }
        try await search.click(tab)
        let phrase = artist.map { "\($0)演唱的《\(title)》" } ?? "《\(title)》"
        let results = try await awaitScreen(
            pid: pid, player: player, trace: trace, message: "未在\(player.name)当前搜索结果找到\(phrase)。"
        ) { !$0.songRows(title: title, artist: artist, query: query).isEmpty }
        let rows = results.songRows(title: title, artist: artist, query: query)
        let selection = await MusicAgentPlanner.select(
            .searchResult(title: title, artist: artist),
            candidates: rows.enumerated().map {
                MusicAgentCandidate(id: $0.offset, title: $0.element.label.text, artist: $0.element.artist)
            }
        )
        // If several albums expose the same exact title and requested artist, use the first result.
        let index = selection?.candidateID ?? (artist == nil ? nil : rows.indices.first)
        guard let index, rows.indices.contains(index) else {
            throw AgentIssue("找到多条匹配的单曲，请补充歌手或歌曲版本。")
        }
        progress("智能体已找到「\(title)」，正在检查播放进度")
        trace?.event(stage: "选择歌曲", detail: "\(rows[index].artist ?? "未显示歌手") · \(rows[index].label.text)")
        try await results.click(rows[index].label, count: 2)
        return try await verifyPlayback(pid: pid, player: player, previous: results.playback,
                                        title: title, artist: artist, trace: trace)
    }

    private func awaitScreen(
        pid: pid_t, player: PlayerProfile = .netease, trace: MusicWindowTrace?, message: String,
        until predicate: (MusicScreen) -> Bool
    ) async throws -> MusicScreen {
        var receivedFrame = false
        var readError: MusicFrameError?
        let deadline = ContinuousClock.now.advanced(by: .seconds(48))
        for attempt in 0..<9 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            if attempt > 0 { try await Task.sleep(for: .milliseconds(420)) }
            do {
                if let screen = try await MusicScreen.read(pid: pid, player: player, trace: trace, stage: message) {
                    receivedFrame = true
                    if predicate(screen) { return screen }
                }
            } catch let error as MusicFrameError {
                readError = error
            }
        }
        if !receivedFrame, let readError { throw readError }
        throw AgentIssue(message)
    }

    private func verifyPlayback(
        pid: pid_t, player: PlayerProfile = .netease, previous: MusicPlayback?, title: String?,
        artist: String? = nil, audioWasRunning: Bool? = nil, trace: MusicWindowTrace?
    ) async throws -> PlatformResult {
        var last: MusicPlayback?
        var first: MusicPlayback?
        let deadline = ContinuousClock.now.advanced(by: .seconds(75))
        for _ in 0..<7 {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(800))
            if title == nil, audioWasRunning == false, audioOutputRunning(pid: pid) == true {
                try await Task.sleep(for: .milliseconds(350))
                if audioOutputRunning(pid: pid) == true {
                    return .init(.confirmed, "网易云已开始播放每日推荐。")
                }
            }
            let captured: MusicScreen?
            do { captured = try await MusicScreen.read(pid: pid, player: player, trace: trace, stage: "核对播放进度") }
            catch is MusicFrameError { continue }
            guard let screen = captured, let current = screen.playback else { continue }
            if first == nil { first = current }
            let rightSong = title.map { screen.matchesPlaying($0, artist: artist, current: current) } ?? screen.isDaily
            let changedTrack = previous.map {
                (!current.trackText.isEmpty && current.trackText != $0.trackText) || current.rewound(from: $0)
            } ?? true
            let beganNearStart = first?.nearStart ?? false
            if rightSong, let last, current.advanced(from: last),
               (title != nil || changedTrack || beganNearStart) {
                trace?.event(stage: "确认播放", detail: "检测到\(player.name)的播放进度前进。")
                return .init(.confirmed, title.map { "\(player.name)已开始播放「\($0)」。" } ?? "网易云已开始播放每日推荐。")
            }
            last = current
        }
        return .init(.submitted, "智能体已在\(player.name)点击播放，尚未确认播放进度。")
    }

    private func audioOutputRunning(pid: pid_t) -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        var lookup = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var objectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &lookup,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &objectSize, &object) == noErr else { return nil }
        guard object != kAudioObjectUnknown else { return false }
        var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &dataSize, &running) == noErr else { return nil }
        return running != 0
    }
}

private struct AgentIssue: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

private enum MusicFrameError: LocalizedError {
    case capture, text

    var errorDescription: String? {
        switch self {
        case .capture: "无法读取播放器窗口，请确认录屏权限和窗口可见。"
        case .text: "已读取播放器窗口，但 macOS 文字识别暂不可用。"
        }
    }
}

private struct MisalignedMusicCapture: LocalizedError {
    let image: CGImage
    let frame: CGRect

    var errorDescription: String? {
        "窗口截图 \(image.width)×\(image.height) 与窗口 \(Int(frame.width))×\(Int(frame.height)) 的比例不一致。"
    }
}

private let musicCaptureLog = Logger(subsystem: "local.t1controller.app", category: "MusicWindow")

private struct MusicLabel: Codable, Sendable {
    let text: String
    // Normalized window coordinates with origin at the top left.
    let bounds: CGRect
    var name: String { normalizedMusicText(text) }
}

@MainActor
private final class MusicWindowTrace {
    let directory: URL
    private var nextIndex = 0

    init(_ directory: URL) { self.directory = directory }

    struct Entry: Encodable {
        let stage: String
        let source: String?
        let windowID: CGWindowID?
        let windowBounds: CGRect?
        var detail: String
        var image: String? = nil
        var pixelWidth: Int? = nil
        var pixelHeight: Int? = nil
        var labels: [MusicLabel]? = nil
        var targets: [String: MusicLabel]? = nil
        var isDaily: Bool? = nil
        var hasPlayerChrome: Bool? = nil
        var playing: String? = nil
        var elapsedSeconds: Int? = nil
        var progressFraction: Double? = nil
    }

    func next() -> URL {
        nextIndex += 1
        return directory.appendingPathComponent(String(format: "%03d", nextIndex))
    }

    func event(stage: String, detail: String) {
        write(Entry(stage: stage, source: nil, windowID: nil, windowBounds: nil, detail: detail), to: next())
    }

    func write(_ entry: Entry, to base: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(entry).write(to: base.appendingPathExtension("json"), options: .atomic)
        } catch {
            musicCaptureLog.error("Could not write music frame trace: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct MusicPlayback {
    let elapsed: Int?
    let progress: Double?
    let trackText: String

    var nearStart: Bool { (elapsed.map { $0 < 12 } ?? false) || (progress.map { $0 < 0.06 } ?? false) }

    func advanced(from previous: Self) -> Bool {
        if let elapsed, let before = previous.elapsed, elapsed > before { return true }
        if let progress, let before = previous.progress { return progress - before >= 0.003 }
        return false
    }

    func rewound(from previous: Self) -> Bool {
        if let elapsed, let before = previous.elapsed, elapsed < before { return true }
        if let progress, let before = previous.progress { return before - progress >= 0.04 }
        return false
    }
}

@MainActor
private struct MusicScreen {
    private static let clockPattern = try? NSRegularExpression(pattern: "([0-9]{1,2})[:：]([0-5][0-9])")
    private static let paddingColor = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
    static let sodaSearchPlaceholder = "歌手、歌曲或专辑名"
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let labels: [MusicLabel]
    let progress: Double?
    let player: PlayerProfile
    let accessibleSearch: CGRect?

    static func read(
        pid: pid_t, player: PlayerProfile = .netease, trace: MusicWindowTrace?, stage: String
    ) async throws -> MusicScreen? {
        try Task.checkCancellation()
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
            throw AgentIssue("\(player.name)窗口已关闭，智能体已停止操作。")
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch {
            trace?.event(stage: stage, detail: "无法枚举可捕捉窗口：\(error.localizedDescription)")
            throw MusicFrameError.capture
        }
        let musicWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 &&
            $0.frame.width >= 320 && $0.frame.height >= 240
        }
        let visibleWindows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []
        let orderedIDs = visibleWindows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let ordered = orderedIDs.lazy.compactMap { id in musicWindows.first { $0.windowID == id } }.first
        guard let window = ordered ?? musicWindows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            musicCaptureLog.notice("NetEase has no visible capturable main window")
            trace?.event(stage: stage, detail: "ScreenCaptureKit 没有返回\(player.name)主窗口。")
            return nil
        }
        guard let frame = quartzFrame(window.windowID, pid: pid) else {
            musicCaptureLog.notice("NetEase window bounds unavailable")
            trace?.event(stage: stage, detail: "无法读取 Quartz 的窗口坐标。")
            return nil
        }
        // Both capture paths restrict the source to the selected player window.
        // Focus is verified when dispatching input, so passive observation survives an app-switch.
        let image: CGImage
        let screen: MusicScreen
        if #available(macOS 26.0, *),
           let (snapshot, detected) = try? await readFrame(
               stage: stage, source: "窗口快照", frame: frame, windowID: window.windowID, pid: pid, trace: trace,
               player: player, capture: { try await captureWindowSnapshot(window: window, frame: frame) }
           ), hasPlayerChrome(detected.labels, player: player) {
            image = snapshot
            screen = detected
        } else if let (composited, detected) = try? await readFrame(
            stage: stage, source: "按显示器拼接", frame: frame, windowID: window.windowID, pid: pid, trace: trace,
            player: player, capture: { try await capture(window: window, frame: frame, displays: content.displays) }
        ), hasPlayerChrome(detected.labels, player: player) {
            image = composited
            screen = detected
        } else {
            do {
                (image, screen) = try await readFrame(
                    stage: stage, source: "独立窗口", frame: frame, windowID: window.windowID, pid: pid, trace: trace,
                    player: player
                ) { try await captureIndependent(window: window, frame: frame) }
            } catch let error as MusicFrameError {
                throw error
            } catch {
                let issue = error as NSError
                musicCaptureLog.error("Window capture error \(issue.domain, privacy: .public) \(issue.code)")
                throw MusicFrameError.capture
            }
        }
        try Task.checkCancellation()
        guard quartzFrame(window.windowID, pid: pid) == frame else {
            trace?.event(stage: stage, detail: "窗口坐标在识别期间改变，这次结果已丢弃。")
            return nil
        }
        let labels = screen.labels
        let recognizedDaily = labels.contains { $0.name.contains("每日推荐") }
        let recognizedSidebar = screen.recommendationTab != nil
        let recognizedCard = screen.dailyCard != nil
        if player == .netease && !recognizedSidebar && !recognizedCard && !screen.isDaily {
            let controls = ["推荐", "播放", "专辑", "时长", "音乐口味", "精选"]
            let locations = labels.compactMap { label -> String? in
                guard let control = controls.first(where: { label.name.contains($0) }) else { return nil }
                let x = Int(label.bounds.midX * 100)
                let y = Int(label.bounds.midY * 100)
                return "\(control)@\(x),\(y)"
            }.prefix(12).joined(separator: " ")
            musicCaptureLog.notice("No NetEase entry in \(image.width)x\(image.height) frame with \(labels.count) labels; daily text \(recognizedDaily); controls \(locations, privacy: .public)")
        }
        return screen
    }

    static func readFrame(
        stage: String, source: String, frame: CGRect, windowID: CGWindowID, pid: pid_t, trace: MusicWindowTrace?,
        player: PlayerProfile = .netease, capture: () async throws -> CGImage
    ) async throws -> (CGImage, MusicScreen) {
        let base = trace?.next()
        let rasterURL = base?.appendingPathExtension("png")
        var entry = MusicWindowTrace.Entry(stage: stage, source: source, windowID: windowID,
                                           windowBounds: frame, detail: "截图失败")
        defer { if let base { trace?.write(entry, to: base) } }
        do {
            let image = try await capture()
            entry.detail = "取得图像，文字识别失败"
            entry.pixelWidth = image.width
            entry.pixelHeight = image.height
            let labels = try await readLabels(image, traceRaster: rasterURL)
            let search = player == .soda && pid > 0
                ? MusicAgentDesktop.searchFieldBounds(pid: pid, placeholder: sodaSearchPlaceholder) : nil
            let progress = player == .soda
                ? MusicProgress.readSoda(image, windowHeight: frame.height) : MusicProgress.read(image)
            let screen = MusicScreen(pid: pid, windowID: windowID, frame: frame, labels: labels,
                                     progress: progress, player: player, accessibleSearch: search)
            if let rasterURL {
                entry.labels = labels
                entry.targets = [
                    "推荐": player == .netease ? screen.recommendationTab : nil,
                    "每日推荐卡片": player == .netease ? screen.dailyCard : nil,
                    "播放全部": player == .netease ? screen.playAllButton : nil,
                    "搜索框": screen.searchField, "歌曲标签": screen.songsTab
                ].compactMapValues { $0 }
                entry.isDaily = screen.isDaily
                let chrome = hasPlayerChrome(labels, player: player)
                entry.hasPlayerChrome = chrome
                entry.detail = ["窗口快照", "按显示器拼接"].contains(source) && !chrome
                    ? "OCR 已返回，未通过窗口标题校验，尝试后备抓图"
                    : "OCR 已返回，坐标为相对图像左上角的比例"
                entry.image = rasterURL.lastPathComponent
                entry.playing = screen.playback?.trackText
                entry.elapsedSeconds = screen.playback?.elapsed
                entry.progressFraction = screen.playback?.progress
            }
            return (image, screen)
        } catch {
            if let rasterURL, FileManager.default.fileExists(atPath: rasterURL.path) {
                entry.image = rasterURL.lastPathComponent
            }
            if let misaligned = error as? MisalignedMusicCapture {
                if let base {
                    let rejected = base.deletingLastPathComponent().appendingPathComponent(
                        base.lastPathComponent + "-capture-only.png"
                    )
                    if let data = try? Self.encodeForReader(misaligned.image),
                       (try? data.write(to: rejected, options: .withoutOverwriting)) != nil {
                        entry.image = rejected.lastPathComponent
                    }
                }
                entry.pixelWidth = misaligned.image.width
                entry.pixelHeight = misaligned.image.height
                entry.detail = "未送入 OCR。\(misaligned.localizedDescription)"
                throw MusicFrameError.capture
            }
            let failure = error as NSError
            entry.detail += "（\(failure.domain) \(failure.code)）\(failure.localizedDescription)"
            throw error
        }
    }

    private static func hasPlayerChrome(_ labels: [MusicLabel], player: PlayerProfile) -> Bool {
        let title = normalizedMusicText(player.name)
        return labels.contains {
            $0.name.hasSuffix(title) && $0.bounds.midX < 0.20 && $0.bounds.midY < (player == .soda ? 0.18 : 0.13)
        }
    }

    @available(macOS 26.0, *)
    private static func captureWindowSnapshot(window: SCWindow, frame: CGRect) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCScreenshotConfiguration()
        let scale = min(max(CGFloat(filter.pointPixelScale), 1), 2_400 / max(frame.width, frame.height))
        config.width = Int((frame.width * scale).rounded())
        config.height = Int((frame.height * scale).rounded())
        config.ignoreShadows = true
        config.ignoreClipping = true
        config.showsCursor = false
        config.includeChildWindows = false
        let snapshot = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = snapshot.sdrImage else { throw MusicFrameError.capture }
        return try validateCapture(image, frame: frame)
    }

    private static func captureIndependent(window: SCWindow, frame: CGRect) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { throw MusicFrameError.capture }
        let scale = min(max(CGFloat(filter.pointPixelScale), 1), 2_400 / max(size.width, size.height))
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.backgroundColor = paddingColor
        config.showsCursor = false
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        let source = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try validateCapture(MusicWindowPadding.trim(source), frame: frame)
    }

    private static func validateCapture(_ image: CGImage, frame: CGRect) throws -> CGImage {
        let aspect = Double(image.width) / Double(image.height)
        guard abs(aspect / (frame.width / frame.height) - 1) < 0.05 else {
            musicCaptureLog.notice("NetEase window capture \(image.width)x\(image.height) with window \(frame.width)x\(frame.height)")
            throw MisalignedMusicCapture(image: image, frame: frame)
        }
        return image
    }

    private static func capture(window: SCWindow, frame: CGRect, displays: [SCDisplay]) async throws -> CGImage {
        let factor = min(2.0, 2_400 / max(frame.width, frame.height))
        let width = Int((frame.width * factor).rounded())
        let height = Int((frame.height * factor).rounded())
        guard width > 0, height > 0, let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MusicFrameError.capture
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var caughtArea = false
        // Keep the player alone in each screenshot, then crop in pixel space.
        // Capturing an arbitrary screen rect can crop at the display boundary without preserving the requested size.
        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)
            let visible = bounds.intersection(frame)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            let filter = SCContentFilter(display: display, including: [window])
            let config = SCStreamConfiguration()
            let scale = min(CGFloat(filter.pointPixelScale), 3_000 / max(bounds.width, bounds.height))
            guard scale > 0 else { continue }
            config.width = Int((bounds.width * scale).rounded())
            config.height = Int((bounds.height * scale).rounded())
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false
            config.ignoreShadowsDisplay = true
            let fullDisplay = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let xScale = CGFloat(fullDisplay.width) / bounds.width
            let yScale = CGFloat(fullDisplay.height) / bounds.height
            guard abs(xScale / yScale - 1) < 0.035 else {
                musicCaptureLog.notice("Unexpected display capture geometry \(fullDisplay.width)x\(fullDisplay.height) for \(bounds.width)x\(bounds.height)")
                continue
            }
            let crop = CGRect(x: (visible.minX - bounds.minX) * xScale,
                              y: (visible.minY - bounds.minY) * yScale,
                              width: visible.width * xScale, height: visible.height * yScale).integral
            guard let part = fullDisplay.cropping(to: crop) else { continue }
            context.draw(part, in: CGRect(x: (visible.minX - frame.minX) * factor,
                                          y: (frame.maxY - visible.maxY) * factor,
                                          width: visible.width * factor, height: visible.height * factor))
            caughtArea = true
        }
        guard caughtArea, let result = context.makeImage() else { throw MusicFrameError.capture }
        return result
    }

    private static func readLabels(_ image: CGImage, traceRaster: URL?) async throws -> [MusicLabel] {
        if #available(macOS 27.0, *) {
            // On macOS 27.2, Vision can fail to initialize its orientation model again in the same process.
            guard let executable = Bundle.main.executableURL else { throw MusicFrameError.text }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try encodeForReader(image) }.value
                var arguments = [MusicDesktopAgent.ocrWorkerArgument]
                if let traceRaster { arguments += ["--trace-raster", traceRaster.path] }
                let result = try await LocalProcess.run(
                    executable, arguments: arguments, input: data, timeout: 35
                )
                guard result.status == 0 else { throw MusicFrameError.text }
                return try JSONDecoder().decode([MusicLabel].self, from: Data(result.stdout.utf8))
            } catch {
                let issue = error as NSError
                musicCaptureLog.error("Isolated Vision reader error \(issue.domain, privacy: .public) \(issue.code)")
                throw MusicFrameError.text
            }
        }
        return try await Task.detached(priority: .userInitiated) { try recognize(image, traceRaster: traceRaster) }.value
    }

    nonisolated private static func encodeForReader(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw MusicFrameError.text
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MusicFrameError.text }
        return data as Data
    }

    nonisolated fileprivate static func recognize(_ image: CGImage, traceRaster: URL?) throws -> [MusicLabel] {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { throw MusicFrameError.text }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(bounds)
        bitmap.draw(image, in: bounds)
        guard let raster = bitmap.makeImage() else { throw MusicFrameError.text }
        if let traceRaster { try encodeForReader(raster).write(to: traceRaster, options: .withoutOverwriting) }
        do {
            return try recognize(raster, cpu: false)
        } catch {
            let issue = error as NSError
            musicCaptureLog.error("Vision error \(issue.domain, privacy: .public) \(issue.code), window \(image.width)x\(image.height) \(image.bitsPerComponent)bpc; retrying on CPU")
            do { return try recognize(raster, cpu: true) }
            catch {
                let fallback = error as NSError
                musicCaptureLog.error("Vision CPU error \(fallback.domain, privacy: .public) \(fallback.code)")
                throw MusicFrameError.text
            }
        }
    }

    nonisolated private static func recognize(_ image: CGImage, cpu: Bool) throws -> [MusicLabel] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.customWords = ["每日推荐", "推荐歌单", "播放全部", "私人雷达", "网易云音乐"]
        if cpu {
            for (stage, devices) in try request.supportedComputeStageDevices {
                if let device = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                    request.setComputeDevice(device, for: stage)
                }
            }
        }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let controlTitles = Set([
            "网易云音乐", "综合", "单曲", "歌单", "标题",
            "推荐", "精选", "播客", "漫游", "推荐歌单", "每日推荐", "播放全部", "全部播放"
        ])
        func label(_ text: String, _ box: CGRect) -> MusicLabel {
            MusicLabel(text: text, bounds: CGRect(x: box.minX, y: 1 - box.maxY,
                                                  width: box.width, height: box.height))
        }
        return (request.results ?? []).flatMap { observation -> [MusicLabel] in
            guard let recognized = observation.topCandidates(1).first, !recognized.string.isEmpty else { return [] }
            let text = recognized.string
            var results = [label(text, observation.boundingBox)]
            let words = text.split(whereSeparator: \.isWhitespace)
            if words.count > 1 {
                for word in words where controlTitles.contains(String(word)) {
                    let range = word.startIndex..<word.endIndex
                    if let part = try? recognized.boundingBox(for: range) {
                        results.append(label(String(word), part.boundingBox))
                    }
                }
            }
            return results
        }
    }

    private static func quartzFrame(_ window: CGWindowID, pid: pid_t) -> CGRect? {
        guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]],
              let record = records.first,
              (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = record[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    func click(_ label: MusicLabel, count: Int = 1) async throws {
        try Task.checkCancellation()
        try await MusicAgentDesktop.focusExisting(player, pid: pid)
        guard Self.quartzFrame(windowID, pid: pid) == frame else {
            throw AgentIssue("网易云窗口位置已变化，请再试一次。")
        }
        let point = CGPoint(x: frame.minX + label.bounds.midX * frame.width,
                            y: frame.minY + label.bounds.midY * frame.height)
        try await MusicAgentDesktop.click(at: point, pid: pid, count: count)
    }

    func scrollRecommendationUp() async throws {
        guard Self.quartzFrame(windowID, pid: pid) == frame else {
            throw AgentIssue("网易云窗口位置已变化，请再试一次。")
        }
        let contentPoint = CGPoint(x: frame.midX + frame.width * 0.15, y: frame.midY)
        try await MusicAgentDesktop.scrollRecommendationUp(at: contentPoint, pid: pid)
    }

    var recommendationTab: MusicLabel? {
        let sidebar = labels.filter { $0.bounds.midX < 0.2 && $0.bounds.midY < 0.36 }
        if let tab = sidebar.first(where: {
            ($0.name == "推荐" || $0.name.hasSuffix("推荐")) && (0.10...0.19).contains($0.bounds.midY)
        }) { return tab }

        // The active tab can disappear from OCR when the label is white on red.
        guard let featured = sidebar.first(where: { $0.name.hasSuffix("精选") }),
              let podcasts = sidebar.first(where: { $0.name.hasSuffix("播客") }),
              let explore = sidebar.first(where: { $0.name.hasSuffix("漫游") }) else { return nil }
        let spacing = podcasts.bounds.midY - featured.bounds.midY
        let nextSpacing = explore.bounds.midY - podcasts.bounds.midY
        guard (0.025...0.09).contains(spacing), abs(nextSpacing - spacing) < spacing * 0.25,
              abs(featured.bounds.midX - podcasts.bounds.midX) < 0.025,
              abs(featured.bounds.midX - explore.bounds.midX) < 0.025 else { return nil }
        let tab = featured.bounds.offsetBy(dx: 0, dy: -spacing)
        guard (0.09...0.22).contains(tab.midY) else { return nil }
        return MusicLabel(text: "推荐", bounds: tab)
    }

    var dailyCard: MusicLabel? {
        let homeSections = ["推荐歌单", "私人雷达", "心动模式", "私人漫游", "相似歌曲", "精选活动"]
        guard labels.contains(where: { label in
            label.bounds.midX > 0.2 && homeSections.contains(where: { label.name.hasSuffix($0) })
        }) else { return nil }
        let headings = labels.filter {
            $0.name.hasSuffix("每日推荐") &&
            $0.bounds.midX > 0.18 && $0.bounds.midX < 0.48 &&
            $0.bounds.midY > 0.09 && $0.bounds.midY < 0.29
        }
        if !headings.isEmpty { return uniqueHeading(headings) }

        // The card caption may be the only recognized text, with the playlist section just below it.
        let captions = labels.filter { label in
            guard label.name == "每日推荐" || label.name.hasPrefix("每日推荐从"),
                  (0.16...0.48).contains(label.bounds.midX),
                  (0.28...0.40).contains(label.bounds.midY) else { return false }
            return labels.contains { anchor in
                let distance = anchor.bounds.midY - label.bounds.midY
                return anchor.name == "推荐歌单" && (0.03...0.19).contains(distance)
                    && abs(anchor.bounds.midX - label.bounds.midX) < 0.12
            }
        }
        return uniqueHeading(captions)
    }

    var playAllButton: MusicLabel? {
        uniqueHeading(labels.filter {
            ["播放全部", "全部播放"].contains($0.name) && $0.bounds.midX > 0.16 && $0.bounds.midX < 0.57 &&
            $0.bounds.midY > 0.12 && $0.bounds.midY < 0.45
        })
    }

    private func uniqueHeading(_ labels: [MusicLabel]) -> MusicLabel? {
        guard let top = labels.map(\.bounds.midY).min() else { return nil }
        var distinct: [MusicLabel] = []
        for label in labels.sorted(by: { $0.bounds.width < $1.bounds.width })
        where label.bounds.midY < top + 0.025 {
            let isDuplicate = distinct.contains {
                $0.bounds.insetBy(dx: -0.01, dy: -0.006).intersects(label.bounds)
            }
            if !isDuplicate { distinct.append(label) }
        }
        return distinct.count == 1 ? distinct.first : nil
    }

    var isDaily: Bool {
        let heading = labels.contains {
            $0.name.contains("每日推荐") && $0.bounds.midX > 0.18 && $0.bounds.midY < 0.29
        }
        let subtitle = labels.contains {
            $0.name.hasPrefix("根据你的音乐口味生成") && $0.bounds.midX > 0.18 && $0.bounds.midY < 0.32
        }
        return heading && (playAllButton != nil || subtitle)
    }

    var searchField: MusicLabel? {
        if player == .soda {
            if let field = accessibleSearch, frame.contains(field), field.midY < frame.minY + 0.12 * frame.height {
                let bounds = CGRect(x: (field.minX - frame.minX) / frame.width,
                                    y: (field.minY - frame.minY) / frame.height,
                                    width: field.width / frame.width, height: field.height / frame.height)
                return MusicLabel(text: Self.sodaSearchPlaceholder, bounds: bounds)
            }
            return labels.filter {
                $0.bounds.midX > 0.65 && $0.bounds.maxX < 0.86 && $0.bounds.midY < 0.075 &&
                $0.name.count > 1
            }.max { $0.bounds.width < $1.bounds.width }
        }
        // The placeholder changes with the current recommendation. Identify its location in the toolbar.
        guard labels.contains(where: { $0.name == "网易云音乐" && $0.bounds.midX < 0.2 }) else { return nil }
        return labels.filter {
            $0.bounds.minX > 0.17 && $0.bounds.maxX < 0.6 && $0.bounds.midY < 0.11
        }.max { $0.bounds.width < $1.bounds.width }
    }

    func showsSearch(_ query: String) -> Bool {
        let expected = normalizedMusicText(query)
        if player == .soda {
            return labels.contains { label in
                let box = label.bounds
                guard (0.18...0.52).contains(box.midX), (0.065...0.16).contains(box.midY) else { return false }
                if label.name == "搜索" + expected { return true }
                return label.name == expected && labels.contains {
                    $0.name == "搜索" && $0.bounds.midX < box.midX &&
                    abs($0.bounds.midY - box.midY) < 0.015
                }
            }
        }
        return labels.contains {
            $0.name == expected && $0.bounds.minX > 0.14 && $0.bounds.minY > 0.09 &&
            $0.bounds.midY < 0.24
        }
    }

    var songsTab: MusicLabel? {
        let name = player == .soda ? "歌曲" : "单曲"
        let siblings = player == .soda ? ["综合", "音乐人"] : ["综合", "歌单"]
        return labels.first { label in
            label.name == name && label.bounds.midX > 0.18 && label.bounds.midX < 0.52 &&
            label.bounds.midY < 0.34 && labels.contains {
                siblings.contains($0.name) && abs($0.bounds.midY - label.bounds.midY) < 0.018
            }
        }
    }

    func songRows(title: String, artist: String?, query: String) -> [(label: MusicLabel, artist: String?)] {
        guard showsSearch(query), let songsTab else { return [] }
        if player == .soda { return sodaRows(title: title, artist: artist, below: songsTab) }
        guard let tableHeader = labels.first(where: {
                  $0.name == "标题" && $0.bounds.minX > 0.17 && $0.bounds.maxX < 0.57 &&
                  $0.bounds.midY > songsTab.bounds.midY && $0.bounds.midY < songsTab.bounds.midY + 0.17
              }) else { return [] }
        let requestedTitle = normalizedMusicText(title)
        let requestedArtist = artist.map(normalizedMusicText)
        return labels.compactMap { label in
            guard label.name == requestedTitle, label.bounds.midY > tableHeader.bounds.midY + 0.023,
                  label.bounds.midY < 0.88, label.bounds.minX > tableHeader.bounds.minX,
                  label.bounds.minX < tableHeader.bounds.minX + 0.14 else { return nil }
            let sublabels = labels.filter {
                $0.bounds.minX >= label.bounds.minX - 0.014 && $0.bounds.minX < label.bounds.minX + 0.16 &&
                $0.bounds.midY > label.bounds.midY + 0.011 && $0.bounds.midY < label.bounds.midY + 0.047
            }
            let performers = sublabels.map { item in
                var name = item.name
                while let prefix = ["超清母带", "无损", "vip", "原唱", "mv"].first(where: name.hasPrefix) {
                    name.removeFirst(prefix.count)
                }
                return name
            }.filter { !$0.isEmpty }
            if let requestedArtist {
                guard performers.contains(requestedArtist) else { return nil }
                return (label, artist)
            }
            return (label, sublabels.last?.text)
        }.sorted { $0.label.bounds.midY < $1.label.bounds.midY }
    }

    private func sodaRows(title: String, artist: String?, below tab: MusicLabel) -> [(label: MusicLabel, artist: String?)] {
        guard let songs = labels.first(where: {
            $0.name == "歌曲" && (0.025...0.16).contains($0.bounds.midY - tab.bounds.midY)
        }),
        let performers = labels.first(where: {
            $0.name == "歌手" && $0.bounds.minX > songs.bounds.minX &&
            abs($0.bounds.midY - songs.bounds.midY) < 0.018
        }),
        let albums = labels.first(where: {
            $0.name == "专辑" && $0.bounds.minX > performers.bounds.minX &&
            abs($0.bounds.midY - songs.bounds.midY) < 0.018
        }) else { return [] }
        let wantedTitle = normalizedMusicText(title)
        let links = labels.filter {
            $0.bounds.minX >= performers.bounds.minX - 0.018 && $0.bounds.minX < albums.bounds.minX - 0.02
        }
        return labels.compactMap { candidate in
            let box = candidate.bounds
            guard box.minX > songs.bounds.minX - 0.018, box.minX < performers.bounds.minX - 0.035,
                  box.midY > songs.bounds.midY + 0.025, box.midY < 0.87,
                  matchesSodaTitle(candidate.name, title: wantedTitle) else { return nil }
            let credits = links.filter { abs($0.bounds.midY - box.midY) < 0.02 }
            guard credits.count == 1, let credit = credits.first,
                  artist.map({ credit.name == normalizedMusicText($0) }) ?? true else { return nil }
            return (candidate, credit.text)
        }.sorted { $0.label.bounds.midY < $1.label.bounds.midY }
    }

    private func matchesSodaTitle(_ value: String, title: String) -> Bool {
        guard value.hasPrefix(title) else { return false }
        let badges = String(value.dropFirst(title.count))
        return ["", "vip", "svip", "原唱", "vip原唱", "svip原唱"].contains(badges)
    }

    var playback: MusicPlayback? {
        guard let pattern = Self.clockPattern else { return nil }
        let footer = labels.filter { $0.bounds.midY > 0.91 }
        let readings = footer.sorted { $0.bounds.minX < $1.bounds.minX }.flatMap { label in
            let text = label.text
            return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Int? in
                guard let minuteRange = Range(match.range(at: 1), in: text),
                      let secondRange = Range(match.range(at: 2), in: text),
                      let minutes = Int(text[minuteRange]), let seconds = Int(text[secondRange]) else { return nil }
                return minutes * 60 + seconds
            }
        }
        let elapsed: Int?
        if readings.count >= 2, let position = readings.first, let total = readings.last,
           total > 0, position <= total {
            elapsed = position
        } else {
            elapsed = nil
        }
        let trackText = playingLabels.map(\.name).joined()
        guard elapsed != nil || progress != nil || !trackText.isEmpty else { return nil }
        return MusicPlayback(elapsed: elapsed, progress: progress, trackText: trackText)
    }

    private var playingLabels: [MusicLabel] {
        if player == .soda {
            return labels.filter {
                $0.bounds.minX > 0.075 && $0.bounds.minX < 0.30 && (0.89...0.935).contains($0.bounds.midY)
            }.sorted { $0.bounds.minX < $1.bounds.minX }
        }
        return labels.filter { $0.bounds.midX < 0.42 && $0.bounds.midY > 0.91 }
    }

    func matchesPlaying(_ title: String, artist: String?, current: MusicPlayback) -> Bool {
        let expected = normalizedMusicText(title)
        guard artist.map({ current.trackText.contains(normalizedMusicText($0)) }) ?? true else { return false }
        if current.trackText.contains(expected) { return true }
        // On the NetEase mini bar Vision confuses 白 with 自. After an exact row
        // selection, only accept that single glyph error with the artist still matching.
        guard player == .netease, artist != nil, expected.count >= 3 else { return false }
        return playingLabels.contains {
            let actual = $0.name
            guard actual.count == expected.count else { return false }
            let differences = zip(expected, actual).filter { $0 != $1 }
            return differences.count == 1 && differences[0] == ("白", "自")
        }
    }
}

private func normalizedMusicText(_ text: String) -> String {
    let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    return simplified.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init).joined()
}
