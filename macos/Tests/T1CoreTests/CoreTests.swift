import Foundation
import XCTest
@testable import T1Core

final class CoreTests: XCTestCase {
    func testNativeModeNeverIsolatesKeysAndKeepsSystemVoiceSeparateFromCommands() {
        XCTAssertFalse(RemoteMode.native.isolatesMappedKeys)
        XCTAssertTrue(RemoteMode.media.isolatesMappedKeys)
        XCTAssertTrue(RemoteMode.host.isolatesMappedKeys)
        XCTAssertEqual(VoiceDestination.resolve(mode: .native, hasSystemVoiceKey: true), .system)
        XCTAssertEqual(VoiceDestination.resolve(mode: .native, hasSystemVoiceKey: false), .focusedText)
        for mode: RemoteMode? in [.media, .host, nil] {
            XCTAssertEqual(VoiceDestination.resolve(mode: mode, hasSystemVoiceKey: true), .command)
            XCTAssertEqual(VoiceDestination.resolve(mode: mode, hasSystemVoiceKey: false), .command)
        }
    }
    func testExclusiveReturnAppliesOnlyToReturnUsagesInMappedPresets() {
        XCTAssertTrue(RemoteMode.isReturnKey(page: 7, usage: 0x28))
        XCTAssertTrue(RemoteMode.isReturnKey(page: 7, usage: 0x58))
        XCTAssertFalse(RemoteMode.isReturnKey(page: 7, usage: 0x65))
        XCTAssertFalse(RemoteMode.isReturnKey(page: 0x0C, usage: 0x28))
        XCTAssertFalse(RemoteMode.native.requiresExclusiveReturn)
        XCTAssertTrue(RemoteMode.media.requiresExclusiveReturn)
        XCTAssertTrue(RemoteMode.host.requiresExclusiveReturn)
    }
    func testModeKeyIsAvailableInEveryPresetAndRequiresAShortMatchedPress() {
        var engine = GestureEngine()
        var mode = RemoteMode.native
        for (index, next) in [RemoteMode.media, .host, .native].enumerated() {
            let time = TimeInterval(index) * 2
            XCTAssertNil(engine.handle(.cycleMode, phase: .up, at: time, mediaMode: false, mode: mode))
            XCTAssertNil(engine.handle(.cycleMode, phase: .down, at: time, mediaMode: false, mode: mode))
            XCTAssertNil(engine.handle(.cycleMode, phase: .repeatPress, at: time + 0.05, mediaMode: false, mode: mode))
            XCTAssertEqual(engine.handle(.cycleMode, phase: .up, at: time + 0.1, mediaMode: false, mode: mode), .cycleMode)
            mode = mode.next
            XCTAssertEqual(mode, next)
        }
        XCTAssertNil(engine.handle(.cycleMode, phase: .down, at: 7, mediaMode: false, mode: mode))
        XCTAssertNil(engine.handle(.cycleMode, phase: .up, at: 8, mediaMode: false, mode: mode))
    }

    func testPresetActionsStayInTheirOwnModes() {
        var engine = GestureEngine()
        func press(_ role: KeyRole, mode: RemoteMode?, from time: TimeInterval, hold: TimeInterval = 0.1) -> GestureOutput? {
            _ = engine.handle(role, phase: .down, at: time, mediaMode: false, mode: mode)
            return engine.handle(role, phase: .up, at: time + hold, mediaMode: false, mode: mode)
        }
        XCTAssertNil(press(.home, mode: .native, from: 0))
        XCTAssertEqual(press(.home, mode: .media, from: 2), .action(.togglePlayback))
        XCTAssertEqual(press(.left, mode: .media, from: 4), .action(.previousTrack))
        XCTAssertNil(press(.switchHost, mode: .media, from: 6))
        XCTAssertNil(press(.home, mode: .host, from: 8))
        XCTAssertEqual(press(.switchHost, mode: .host, from: 10), .action(.switchOtherHost))
        XCTAssertEqual(press(.menu, mode: .media, from: 12, hold: 1), .action(.nextPlayer))
        XCTAssertEqual(press(.menu, mode: nil, from: 14, hold: 1), .action(.switchOtherHost))
        XCTAssertFalse(KeyRole.home.conflicts(with: .switchHost))
        XCTAssertTrue(KeyRole.cycleMode.conflicts(with: .switchHost))
    }

    func testVoiceRemainsAvailableAcrossModesWithoutSharingAMappedKey() {
        for mode in RemoteMode.allCases {
            XCTAssertTrue(RemoteMode.allows(.voice, mode: mode, legacyEnabled: false))
            var engine = GestureEngine()
            XCTAssertEqual(engine.handle(.voice, phase: .down, at: 0, mediaMode: false, mode: mode), .beginVoice)
            XCTAssertEqual(engine.handle(.voice, phase: .up, at: 1, mediaMode: false, mode: mode), .finishVoice)
        }
        XCTAssertTrue(KeyRole.voice.conflicts(with: .switchHost))
        XCTAssertTrue(KeyRole.switchHost.conflicts(with: .voice))
        XCTAssertFalse(RemoteMode.allows(.voice, mode: nil, legacyEnabled: false))
    }
    func testSharedIntentFixtures() throws {
        struct Fixture: Decodable {
            struct WireAction: Decodable {
                var action: String
                var host: HostID?
                var displayOnly: Bool?
                var percent: Int?
                var player: String?
            }
            var text: String
            var expected: WireAction?
        }
        var fixture = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { fixture.deleteLastPathComponent() }
        fixture.append(path: "shared/intent-fixtures.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixture))
        for row in fixtures {
            let expected: ControllerAction?
            switch row.expected?.action {
            case "playDailyRecommendations": expected = .playDailyRecommendations
            case "openPlayer": expected = .openPlayer(try XCTUnwrap(row.expected?.player))
            case "nextPlayer": expected = .nextPlayer
            case "play": expected = .play
            case "pause": expected = .pause
            case "previousTrack": expected = .previousTrack
            case "nextTrack": expected = .nextTrack
            case "setVolume": expected = .setVolume(try XCTUnwrap(row.expected?.percent))
            case "switchHost":
                let host = try XCTUnwrap(row.expected?.host)
                expected = row.expected?.displayOnly == true ? .switchDisplay(host) : .switchHost(host)
            case "switchOtherHost": expected = .switchOtherHost
            case nil: expected = nil
            default:
                XCTFail("Unknown action in the shared fixture")
                continue
            }
            XCTAssertEqual(IntentParser.parse(row.text), expected, row.text)
        }
    }

    func testNamedSongRequestsPreserveTitleAndArtist() {
        XCTAssertEqual(IntentParser.parse("帮我播放周杰伦的晴天"), .playSong(title: "晴天", artist: "周杰伦"))
        XCTAssertEqual(IntentParser.parse("我想听周杰伦的晴天"), .playSong(title: "晴天", artist: "周杰伦"))
        XCTAssertEqual(
            IntentParser.parse("小爱同学，帮我打开网易云音乐，然后播放周杰伦的《晴天》。"),
            .playSong(title: "晴天", artist: "周杰伦", player: .netease)
        )
        XCTAssertEqual(
            IntentParser.parse("用网易云音乐播放一首 Taylor Swift 的 Love Story 吧"),
            .playSong(title: "Love Story", artist: "Taylor Swift", player: .netease)
        )
        XCTAssertEqual(
            IntentParser.parse("用汽水音乐播放周杰伦的《晴天》"),
            .playSong(title: "晴天", artist: "周杰伦", player: .soda)
        )
        XCTAssertEqual(
            IntentParser.parse("播放《夜空中最亮的星》，逃跑计划演唱的。"),
            .playSong(title: "夜空中最亮的星", artist: "逃跑计划")
        )
    }

    func testDirectSongRequestsAndGenericCommands() {
        XCTAssertEqual(IntentParser.parse("播放《暂停》"), .playSong(title: "暂停", artist: nil))
        XCTAssertEqual(IntentParser.parse("播放“周杰伦”的《晴天》"), .playSong(title: "晴天", artist: "周杰伦"))
        XCTAssertEqual(IntentParser.parse("播放《夜空中最亮的星》"), .playSong(title: "夜空中最亮的星", artist: nil))
        XCTAssertEqual(IntentParser.parse("播放七里香这首歌"), .playSong(title: "七里香", artist: nil))
        XCTAssertEqual(IntentParser.parse("帮我播放"), .play)
        XCTAssertEqual(IntentParser.parse("打开网易云音乐，然后播放今日推荐"), .playDailyRecommendations)
        XCTAssertNil(IntentParser.parse("不要播放周杰伦的晴天"))
        XCTAssertNil(IntentParser.parse("播放周杰伦的歌"))
        XCTAssertNil(IntentParser.parse("播放一首歌"))
    }

    func testXiaoAIDailyVoicePhrases() {
        for phrase in ["小爱同学，打开网易云音乐，播放今日推荐。",
                       "小爱同学，帮我打开网易云，然后打开今日推荐播放。",
                       "打开网易云音乐并开始播放每日推荐", "播放今日推荐"] {
            XCTAssertEqual(IntentParser.parse(phrase), .playDailyRecommendations, phrase)
        }
        XCTAssertEqual(IntentParser.parse("打开网易云"), .openPlayer("netease"))
        XCTAssertNil(IntentParser.parse("打开网易云但不要播放今日推荐"))
    }

    func testMenuShortPressAndHoldAreMutuallyExclusive() {
        var engine = GestureEngine()
        XCTAssertNil(engine.handle(.menu, phase: .down, at: 1, mediaMode: false))
        XCTAssertNil(engine.handle(.menu, phase: .repeatPress, at: 2, mediaMode: false))
        XCTAssertEqual(engine.handle(.menu, phase: .up, at: 3, mediaMode: false), .action(.switchOtherHost))
        XCTAssertNil(engine.handle(.menu, phase: .up, at: 3.01, mediaMode: false))
        XCTAssertNil(engine.handle(.menu, phase: .down, at: 4, mediaMode: false))
        XCTAssertEqual(engine.handle(.menu, phase: .up, at: 4.15, mediaMode: false), .action(.nextPlayer))
    }

    func testDisconnectClearsPushToTalkWithoutExecuting() {
        var engine = GestureEngine()
        XCTAssertEqual(engine.handle(.voice, phase: .down, at: 1, mediaMode: false), .beginVoice)
        XCTAssertEqual(engine.reset(), .cancelVoice)
        XCTAssertNil(engine.handle(.voice, phase: .up, at: 2, mediaMode: false))
    }

    func testVoiceDistinguishesReceiverPulseFromHoldAndTimeout() {
        var engine = GestureEngine()
        XCTAssertEqual(engine.handle(.voice, phase: .down, at: 1, mediaMode: false), .beginVoice)
        XCTAssertEqual(engine.handle(.voice, phase: .up, at: 1.118, mediaMode: false), .shortVoiceRelease)
        XCTAssertEqual(engine.handle(.voice, phase: .down, at: 2, mediaMode: false), .beginVoice)
        XCTAssertEqual(engine.handle(.voice, phase: .up, at: 7, mediaMode: false), .finishVoice)
        XCTAssertEqual(engine.handle(.voice, phase: .down, at: 8, mediaMode: false), .beginVoice)
        XCTAssertEqual(engine.handle(.voice, phase: .up, at: 24, mediaMode: false), .cancelVoice)
    }

    func testT1VoicePulseEndsOnAudioLossOrTrailingSilence() {
        XCTAssertFalse(VoicePulseEndPolicy.shouldFinish(silence: nil, audioGap: 2))
        XCTAssertFalse(VoicePulseEndPolicy.shouldFinish(silence: 0.39, audioGap: 0.5))
        XCTAssertFalse(VoicePulseEndPolicy.shouldFinish(silence: 0.6, audioGap: 0.05))
        XCTAssertTrue(VoicePulseEndPolicy.shouldFinish(silence: 0.4, audioGap: 0.4))
        XCTAssertTrue(VoicePulseEndPolicy.shouldFinish(silence: 0.8, audioGap: 0.04))
        XCTAssertTrue(VoicePulseEndPolicy.shouldFinish(silence: 0.03, audioGap: 0.02, classifiedSilence: 0.9))
        XCTAssertFalse(VoicePulseEndPolicy.shouldFinish(silence: 0.03, audioGap: 0.02, classifiedSilence: 0.6))
        XCTAssertLessThan(VoicePulseEndPolicy.maximumWait, 15)
    }

    func testOnlyExplicitXiaoAIGreetingSelectsBridge() {
        XCTAssertFalse(IntentParser.addressesXiaoAI("播放今日推荐"))
        XCTAssertFalse(IntentParser.addressesXiaoAI("播放小爱同学的歌"))
        XCTAssertTrue(IntentParser.addressesXiaoAI("，小愛同學，播放今日推薦"))
    }

    func testT1VoicePulseTreatsOnlyASeparatePressAsStop() {
        XCTAssertFalse(VoicePulseEndPolicy.isSecondPress(firstRelease: 1, nextPress: 1.02))
        XCTAssertFalse(VoicePulseEndPolicy.isSecondPress(firstRelease: 1, nextPress: 0.9))
        XCTAssertTrue(VoicePulseEndPolicy.isSecondPress(firstRelease: 1, nextPress: 1.4))
    }

    func testOrdinaryDirectionKeysPassThrough() {
        var engine = GestureEngine()
        XCTAssertNil(engine.handle(.left, phase: .down, at: 1, mediaMode: false))
        XCTAssertNil(engine.handle(.left, phase: .up, at: 1.1, mediaMode: false))
        XCTAssertNil(engine.handle(.left, phase: .down, at: 2, mediaMode: true))
        XCTAssertEqual(engine.handle(.left, phase: .up, at: 2.1, mediaMode: true), .action(.previousTrack))
    }

    func testRemappedPlaybackButtonsFireOnceOnRelease() {
        var engine = GestureEngine()
        for (role, action): (KeyRole, ControllerAction) in [(.right, .nextTrack), (.home, .togglePlayback)] {
            let mode = role == .right
            XCTAssertNil(engine.handle(role, phase: .down, at: 1, mediaMode: mode))
            XCTAssertNil(engine.handle(role, phase: .repeatPress, at: 1.2, mediaMode: mode))
            XCTAssertEqual(engine.handle(role, phase: .up, at: 1.3, mediaMode: mode), .action(action))
            XCTAssertNil(engine.handle(role, phase: .up, at: 1.4, mediaMode: mode))
        }
        XCTAssertTrue(KeyRole.home.matchesStandardPlaybackKey(page: 0x07, usage: 0x28))
        XCTAssertFalse(KeyRole.home.matchesStandardPlaybackKey(page: 0x09, usage: 1))
        XCTAssertFalse(KeyRole.right.matchesStandardPlaybackKey(page: 0x0C, usage: 0xB5))
    }

    func testOKIgnoresDuplicatePressAfterRelease() {
        var engine = GestureEngine()
        XCTAssertNil(engine.handle(.home, phase: .down, at: 1, mediaMode: true))
        XCTAssertEqual(engine.handle(.home, phase: .up, at: 1.20, mediaMode: true), .action(.togglePlayback))
        XCTAssertNil(engine.handle(.home, phase: .down, at: 1.21, mediaMode: true))
        XCTAssertNil(engine.handle(.home, phase: .up, at: 1.30, mediaMode: true))

        // Switching tracks and intentionally pressing OK again still work.
        XCTAssertNil(engine.handle(.right, phase: .down, at: 1.31, mediaMode: true))
        XCTAssertEqual(engine.handle(.right, phase: .up, at: 1.42, mediaMode: true), .action(.nextTrack))
        XCTAssertNil(engine.handle(.home, phase: .down, at: 1.43, mediaMode: true))
        XCTAssertEqual(engine.handle(.home, phase: .up, at: 1.55, mediaMode: true), .action(.togglePlayback))

        _ = engine.reset()
        XCTAssertNil(engine.handle(.home, phase: .down, at: 1.56, mediaMode: true))
        XCTAssertEqual(engine.handle(.home, phase: .up, at: 1.66, mediaMode: true), .action(.togglePlayback))
    }

    @MainActor
    func testDisplayOnlyToggleUsesCurrentInputRegardlessOfPeripherals() {
        XCTAssertEqual(SwitchCoordinator.alternateTarget(
            visible: .windows, hubOwner: .mac, withPeripherals: false
        ), .mac)
        XCTAssertEqual(SwitchCoordinator.alternateTarget(
            visible: .mac, hubOwner: nil, withPeripherals: false
        ), .windows)
        XCTAssertNil(SwitchCoordinator.alternateTarget(
            visible: .windows, hubOwner: .mac, withPeripherals: true
        ))
        XCTAssertNil(SwitchCoordinator.alternateTarget(
            visible: nil, hubOwner: .mac, withPeripherals: false
        ))
    }

    @MainActor
    func testSwitchDoesNotSendHubToggleWhenDisplayFails() async throws {
        let coordinator = SwitchCoordinator()
        let result = await coordinator.run(
            target: .windows,
            display: { _ in Outcome(.failed, "DDC write failed") },
            hub: { _ in
                XCTFail("A failed display change must not trigger the hub toggle")
                return Outcome(.submitted, "hub toggled")
            }
        )
        XCTAssertEqual(try XCTUnwrap(result).outcome.state, .failed)
    }

    @MainActor
    func testSwitchReportsPartialWhenHubConfirmationIsMissing() async throws {
        let coordinator = SwitchCoordinator()
        let result = await coordinator.run(
            target: .windows,
            display: { _ in Outcome(.confirmed, "DDC read-back matched") },
            hub: { _ in Outcome(.submitted, "hub command submitted") }
        )
        XCTAssertEqual(try XCTUnwrap(result).outcome.state, .partial)
    }
}
