import Foundation
import Security
import T1Core
import T1Platform

struct SavedPlayer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

struct Preferences: Codable, Equatable {
    var schema = 1
    var permissionGuideSeen = false
    var mappingsEnabled = true
    var mediaMode = false
    var remoteMode: RemoteMode?
    var bindings: [String: KeyBinding] = [:]
    var xiaomiBindings: [String: KeyBinding] = [:]
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
