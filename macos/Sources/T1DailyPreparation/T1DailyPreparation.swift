import AppKit
import Darwin
import T1Core
import T1Platform

@main
enum T1DailyPreparation {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let status = MusicDesktopAgent.runOCRWorker(arguments: arguments) { exit(status) }
        do {
            guard let result = try await run(arguments) else {
                fputs("用法：T1DailyPreparation [--inspect-window | --inspect-soda | --play-daily | --voice-song 转写 | --inspect-image 图片] 取证目录\n", stderr)
                exit(64)
            }
            print(result.message)
            exit(result.status == .confirmed ? 0 : 1)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run(_ arguments: [String]) async throws -> PlatformResult? {
        if arguments.count == 3, arguments[0] == "--voice-song" {
            guard case let .playSong(title, artist, requestedPlayer) = IntentParser.parse(arguments[1]),
                  let player = PlayerProfile.songSearchPlayers.first(where: {
                      $0.bundleID == (requestedPlayer ?? .netease).bundleID
                  }) else {
                return .init(.unavailable, "未识别为指定歌曲的语音指令。")
            }
            let trace = try makeTraceDirectory(arguments[2])
            print("语音解析：\(player.name) · \(artist ?? "未指定歌手") · \(title)")
            _ = NSApplication.shared
            return await MusicDesktopAgent().run(.song(title: title, artist: artist), player: player,
                                                 recordingIn: trace) { print($0) }
        }
        if arguments.count == 3, arguments[0] == "--inspect-image" {
            return await MusicDesktopAgent.inspectImage(
                URL(fileURLWithPath: arguments[1]), recordingIn: try makeTraceDirectory(arguments[2])
            )
        }
        if arguments.count == 2, ["--inspect-window", "--play-daily"].contains(arguments[0]) {
            let trace = try makeTraceDirectory(arguments[1])
            _ = NSApplication.shared
            if arguments[0] == "--inspect-window" {
                return await MusicDesktopAgent().inspectWindow(.netease, recordingIn: trace)
            }
            return await MusicDesktopAgent().run(.daily, recordingIn: trace)
        }
        if arguments.count == 2, arguments[0] == "--inspect-soda" {
            _ = NSApplication.shared
            return await MusicDesktopAgent().inspectWindow(.soda, recordingIn: try makeTraceDirectory(arguments[1]))
        }
        guard arguments.isEmpty else { return nil }
        _ = NSApplication.shared
        return await MusicDesktopAgent().run(.prepareDaily)
    }

    private static func makeTraceDirectory(_ path: String) throws -> URL {
        let requested = URL(fileURLWithPath: path, isDirectory: true)
        let directory = requested.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        print(directory.path)
        return directory
    }
}
