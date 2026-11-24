import Foundation

public enum HostID: String, Codable, CaseIterable, Sendable {
    case mac, windows

    public var other: Self { self == .mac ? .windows : .mac }
    public var title: String { self == .mac ? "Mac" : "Windows" }
}

public enum ControllerAction: Equatable, Sendable {
    case play, pause, togglePlayback, previousTrack, nextTrack
    case volumeUp, volumeDown, setVolume(Int), toggleMute
    case nextPlayer, openPlayer(String)
    case switchHost(HostID), switchOtherHost
    case switchDisplay(HostID)
    case playDailyRecommendations
    case playSong(title: String, artist: String?, player: SongPlayer? = nil)
}

public enum SongPlayer: String, Sendable {
    case netease, soda

    public var bundleID: String {
        switch self {
        case .netease: "com.netease.163music"
        case .soda: "com.soda.music"
        }
    }
}

public enum OutcomeState: String, Sendable {
    case confirmed, submitted, partial, unavailable, failed
}

public struct Outcome: Equatable, Sendable {
    public let state: OutcomeState
    public let detail: String

    public init(_ state: OutcomeState, _ detail: String) {
        self.state = state
        self.detail = detail
    }

    public var mayHaveTakenEffect: Bool { state == .confirmed || state == .submitted }
}

public struct SwitchResult: Sendable {
    public let id: UUID
    public let target: HostID
    public let display: Outcome
    public let hub: Outcome?

    public var outcome: Outcome {
        guard let hub else { return display }
        if display.state == .confirmed && hub.state == .confirmed {
            return Outcome(.confirmed, "已切换至 \(target.title)")
        }
        let detail = "画面：\(display.detail) · 外设：\(hub.detail)"
        if display.state == .confirmed || hub.state == .confirmed ||
            display.mayHaveTakenEffect != hub.mayHaveTakenEffect {
            return Outcome(.partial, detail)
        }
        if display.state == .submitted && hub.state == .submitted {
            return Outcome(.submitted, detail)
        }
        return Outcome(display.state, detail)
    }
}

@MainActor
public final class SwitchCoordinator {
    public typealias Backend = @MainActor (HostID) async -> Outcome
    public private(set) var isSwitching = false

    public init() {}

    public static func alternateTarget(
        visible: HostID?, hubOwner: HostID?, withPeripherals: Bool
    ) -> HostID? {
        guard let visible, !withPeripherals || hubOwner == visible else { return nil }
        return visible.other
    }

    public func run(
        target: HostID,
        display: Backend,
        hub: Backend? = nil
    ) async -> SwitchResult? {
        guard !isSwitching else { return nil }
        isSwitching = true
        defer { isSwitching = false }
        let id = UUID()
        let displayResult = await display(target)
        let hubResult: Outcome?
        if let hub {
            hubResult = displayResult.mayHaveTakenEffect
                ? await hub(target)
                : Outcome(.unavailable, "画面指令未提交，外设未交接")
        } else {
            hubResult = nil
        }
        return SwitchResult(id: id, target: target, display: displayResult, hub: hubResult)
    }
}
