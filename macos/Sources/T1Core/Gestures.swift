import Foundation

public enum KeyRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case cycleMode, menu, home, left, right, volumeUp, volumeDown, mute, voice, switchHost
    public var id: Self { self }

    public var title: String {
        switch self {
        case .cycleMode: return "模式键 · 循环切换"
        case .menu: return "切换播放器"
        case .home: return "播放 / 暂停 · 可改用 OK"
        case .left: return "左方向 · 上一曲"
        case .right: return "右方向 · 下一曲"
        case .volumeUp: return "音量＋"
        case .volumeDown: return "音量−"
        case .mute: return "静音"
        case .voice: return "语音 · 按住说话"
        case .switchHost: return "切换到另一台主机"
        }
    }

    public func conflicts(with other: Self) -> Bool {
        self == .cycleMode || other == .cycleMode || self == .voice || other == .voice ||
            (self == .switchHost) == (other == .switchHost)
    }

    /// Only known keyboard controls are enabled on learning; a native media
    /// control or pointer click could otherwise trigger twice.
    public func matchesStandardPlaybackKey(page: UInt32, usage: UInt32) -> Bool {
        guard page == 0x07 else { return false }
        switch self {
        case .left: return usage == 0x50
        case .right: return usage == 0x4F
        case .home: return usage == 0x28 || usage == 0x58
        default: return false
        }
    }
}

public enum RemoteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case native, media, host

    public var id: Self { self }

    public var title: String {
        switch self {
        case .native: "原生"
        case .media: "媒体"
        case .host: "主机切换"
        }
    }

    public var next: Self {
        switch self {
        case .native: .media
        case .media: .host
        case .host: .native
        }
    }

    public static func allows(_ role: KeyRole, mode: Self?, legacyEnabled: Bool) -> Bool {
        if role == .cycleMode || (role == .voice && mode != nil) { return true }
        switch mode {
        case .native: return false
        case .media: return role != .switchHost
        case .host: return role == .switchHost
        case nil: return legacyEnabled && role != .switchHost
        }
    }

    public static func isReturnKey(page: UInt32, usage: UInt32) -> Bool {
        page == 0x07 && (usage == 0x28 || usage == 0x58)
    }

    public var requiresExclusiveReturn: Bool { self != .native }

    /// Native mode never owns or suppresses a hardware key, including mode/voice keys.
    public var isolatesMappedKeys: Bool { self != .native }
}

public enum VoiceDestination: Equatable, Sendable {
    case system, focusedText, command

    public static func resolve(mode: RemoteMode?, hasSystemVoiceKey: Bool) -> Self {
        guard mode == .native else { return .command }
        return hasSystemVoiceKey ? .system : .focusedText
    }
}

public struct KeyBinding: Codable, Equatable, Sendable {
    public var device: String
    public var control: String
    public var enabled: Bool

    public init(device: String, control: String, enabled: Bool = false) {
        self.device = device
        self.control = control
        self.enabled = enabled
    }
}

public enum KeyPhase: Sendable { case down, up, repeatPress }

public enum GestureOutput: Equatable, Sendable {
    case action(ControllerAction)
    case beginVoice
    case finishVoice
    case shortVoiceRelease
    case cancelVoice
    case cycleMode
}

public enum VoicePulseEndPolicy {
    public static let maximumWait: TimeInterval = 7

    public static func shouldFinish(
        silence: TimeInterval?, audioGap: TimeInterval?, classifiedSilence: TimeInterval? = nil
    ) -> Bool {
        if (classifiedSilence ?? 0) >= 0.8 { return true }
        guard let silence else { return false }
        return silence >= 0.8 || (silence >= 0.4 && (audioGap ?? 0) >= 0.4)
    }

    public static func isSecondPress(firstRelease: TimeInterval, nextPress: TimeInterval) -> Bool {
        nextPress - firstRelease >= 0.35
    }
}

public struct GestureEngine {
    private static let playbackBounceInterval: TimeInterval = 0.075

    private var pressedAt: [KeyRole: TimeInterval] = [:]
    private var lastRepeatAt: [KeyRole: TimeInterval] = [:]
    private var lastPlaybackRelease: TimeInterval?
    private let longPress: TimeInterval

    public init(longPress: TimeInterval = 0.8) {
        self.longPress = longPress
    }

    public mutating func handle(
        _ role: KeyRole,
        phase: KeyPhase,
        at time: TimeInterval,
        mediaMode: Bool,
        mode: RemoteMode? = nil
    ) -> GestureOutput? {
        guard RemoteMode.allows(role, mode: mode, legacyEnabled: true) else { return nil }
        switch phase {
        case .down:
            guard pressedAt[role] == nil else { return nil }
            pressedAt[role] = time
            if role == .voice { return .beginVoice }
            if let action = volumeAction(for: role) {
                lastRepeatAt[role] = time
                return .action(action)
            }
        case .repeatPress:
            if let previous = lastRepeatAt[role], time - previous >= 0.12,
               let action = volumeAction(for: role) {
                lastRepeatAt[role] = time
                return .action(action)
            }
        case .up:
            guard let start = pressedAt.removeValue(forKey: role) else { return nil }
            lastRepeatAt.removeValue(forKey: role)
            let duration = time - start
            guard duration >= 0 else { return nil }
            if role == .voice {
                if duration < 0.18 { return .shortVoiceRelease }
                return duration <= 15 ? .finishVoice : .cancelVoice
            }
            guard duration <= 10 else { return nil }
            switch role {
            case .cycleMode: return duration < longPress ? .cycleMode : nil
            case .switchHost: return duration < longPress ? .action(.switchOtherHost) : nil
            case .menu:
                return .action(mode == nil && duration >= longPress ? .switchOtherHost : .nextPlayer)
            case .home:
                // A second down/up pair immediately after release can be contact bounce.
                if let lastPlaybackRelease, start - lastPlaybackRelease < Self.playbackBounceInterval {
                    return nil
                }
                lastPlaybackRelease = time
                return .action(.togglePlayback)
            case .left: return mode == .media || mediaMode ? .action(.previousTrack) : nil
            case .right: return mode == .media || mediaMode ? .action(.nextTrack) : nil
            case .mute: return .action(.toggleMute)
            case .voice, .volumeUp, .volumeDown: return nil
            }
        }
        return nil
    }

    public mutating func reset() -> GestureOutput? {
        let wasRecording = pressedAt[.voice] != nil
        pressedAt.removeAll()
        lastRepeatAt.removeAll()
        lastPlaybackRelease = nil
        return wasRecording ? .cancelVoice : nil
    }

    private func volumeAction(for role: KeyRole) -> ControllerAction? {
        switch role {
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        default: return nil
        }
    }
}
