import Foundation
import Security
import T1Core
import T1Platform

struct SavedPlayer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

enum ChromecastBaseAction: String, Codable, CaseIterable, Identifiable {
    case none, up, down, left, right, enter, escape, space, tab, homeKey
    case togglePlayback, previousTrack, nextTrack, volumeUp, volumeDown, toggleMute, nextPlayer
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "不执行"
        case .up: "方向 ↑"
        case .down: "方向 ↓"
        case .left: "方向 ←"
        case .right: "方向 →"
        case .enter: "回车"
        case .escape: "Esc／返回"
        case .space: "空格"
        case .tab: "Tab"
        case .homeKey: "Home／行首"
        case .togglePlayback: "所选播放器 · 播放／暂停"
        case .previousTrack: "所选播放器 · 上一曲"
        case .nextTrack: "所选播放器 · 下一曲"
        case .volumeUp: "提高音量"
        case .volumeDown: "降低音量"
        case .toggleMute: "静音"
        case .nextPlayer: "切换播放器"
        }
    }
    var keyCode: UInt16? {
        switch self {
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .enter: 36
        case .escape: 53
        case .space: 49
        case .tab: 48
        case .homeKey: 115
        default: nil
        }
    }
    var action: ControllerAction? {
        switch self {
        case .togglePlayback: .togglePlayback
        case .previousTrack: .previousTrack
        case .nextTrack: .nextTrack
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .toggleMute: .toggleMute
        case .nextPlayer: .nextPlayer
        default: nil
        }
    }
}

struct ChromecastButton: Identifiable {
    let usage: UInt32
    let name: String
    let defaultAction: ChromecastBaseAction
    var id: String { String(format: "hid:000C:%04X:02", usage) }
    static let all: [Self] = [
        .init(usage: 0x42, name: "上", defaultAction: .up),
        .init(usage: 0x43, name: "下", defaultAction: .down),
        .init(usage: 0x44, name: "左", defaultAction: .left),
        .init(usage: 0x45, name: "右", defaultAction: .right),
        .init(usage: 0x41, name: "中间 OK", defaultAction: .enter),
        .init(usage: 0x224, name: "返回", defaultAction: .escape),
        .init(usage: 0x223, name: "主页", defaultAction: .homeKey),
        .init(usage: 0xE9, name: "音量＋", defaultAction: .volumeUp),
        .init(usage: 0xEA, name: "音量−", defaultAction: .volumeDown),
        .init(usage: 0xE2, name: "静音", defaultAction: .toggleMute),
        // Captured from this 0x011B remote: 9E 01 / 89 01, release 00 00.
        // Keep unassigned until the user chooses an action; never power off a Mac on discovery.
        .init(usage: 0x19E, name: "电源键", defaultAction: .none),
        .init(usage: 0x189, name: "信号源键", defaultAction: .none),
        .init(usage: 0xCD, name: "播放／暂停", defaultAction: .togglePlayback),
        .init(usage: 0xB5, name: "下一曲", defaultAction: .nextTrack),
        .init(usage: 0xB6, name: "上一曲", defaultAction: .previousTrack),
        .init(usage: 0x221, name: "搜索（若有 HID 报文）", defaultAction: .none),
        .init(usage: 0x77, name: "YouTube（若有 HID 报文）", defaultAction: .none),
        .init(usage: 0x78, name: "Netflix（若有 HID 报文）", defaultAction: .none)
    ]
}

struct Preferences: Codable, Equatable {
    var schema = 1
    var permissionGuideSeen = false
    var mappingsEnabled = true
    var mediaMode = false
    var remoteMode: RemoteMode?
    var bindings: [String: KeyBinding] = [:]
    var xiaomiBindings: [String: KeyBinding] = [:]
    var chromecastBindings: [String: KeyBinding] = [:]
    var chromecastCompatibility = false
    var chromecastVoiceEnabled = false
    var chromecastPeripheralID = ""
    var chromecastBaseActions: [String: ChromecastBaseAction] = [:]
    var players = [SavedPlayer(id: "com.netease.163music", name: "网易云音乐")]
    var playerID = "com.netease.163music"
    var playerVolumeSteps = false
    var monitorUUID = ""
    var macInput = ""
    var windowsInput = ""
    var toggleWithPeripherals: Bool?
    var kmfuKey: UInt16 = 105
    var kmfuCommand = false
    var kmfuOption = true
    var kmfuControl = true
    var kmfuShift = false
    var kmfuVerified = false
    var routeReceiver = ""
    var routeSpeakerUID = ""
    var routeSpeakerName = ""
    var routeSensorsVerified = false
    var routeAwaitingDeparture = false
    var microphoneUID = ""
    var whisperExecutable = ""
    var whisperModel = ""
    var voiceHotkeyEnabled = false
    var actionHotkeysEnabled = false
    var modeHotkeysEnabled = true
    var xiaoAI = XiaoAIBridge.Settings()

    static let url = URL.applicationSupportDirectory
        .appending(path: "T1Controller/settings.json", directoryHint: .notDirectory)

    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self(remoteMode: .native) }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Older snapshots without newly introduced keys inherit current defaults.
        let initial = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self())) as? [String: Any] ?? [:]
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let merged = initial.merging(saved) { _, newest in newest }
        var result = try decoder.decode(Self.self, from: JSONSerialization.data(withJSONObject: merged))
        guard result.schema == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        if result.bindings[KeyRole.switchHost.rawValue] == nil {
            result.bindings[KeyRole.switchHost.rawValue] = result.bindings[KeyRole.menu.rawValue]
        }
        if result.xiaomiBindings[KeyRole.switchHost.rawValue] == nil {
            result.xiaomiBindings[KeyRole.switchHost.rawValue] = result.xiaomiBindings[KeyRole.menu.rawValue]
        }
        return result
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

enum XiaoAIKeychain {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.t1controller.app.xiaoai",
        kSecAttrAccount as String: "daily-recommendations"
    ]

    struct Failure: Error { let status: OSStatus }

    static func load() throws -> XiaoAIBridge.Credentials? {
        var query = item
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return try JSONDecoder().decode(XiaoAIBridge.Credentials.self, from: data)
    }

    static func save(_ credentials: XiaoAIBridge.Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var entry = item
            entry[kSecValueData as String] = data
            let result = SecItemAdd(entry as CFDictionary, nil)
            guard result == errSecSuccess else { throw Failure(status: result) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
