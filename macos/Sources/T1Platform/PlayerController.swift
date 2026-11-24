import AppKit
import ApplicationServices
import Carbon
import Foundation

public enum PlaybackAction: String, Sendable, Codable {
    case play, pause, toggle, previous, next
}

public struct PlayerProfile: Identifiable, Sendable, Codable, Equatable {
    public let bundleID: String
    public let name: String
    public let controls: [PlaybackAction: [String]]
    public var id: String { bundleID }

    public init(bundleID: String, name: String, controls: [PlaybackAction: [String]] = [:]) {
        self.bundleID = bundleID
        self.name = name
        self.controls = controls
    }

    public static let netease = PlayerProfile(bundleID: "com.netease.163music", name: "网易云音乐")
    public static let soda = PlayerProfile(bundleID: "com.soda.music", name: "汽水音乐")
    public static let songSearchPlayers: [Self] = [.netease, .soda]
}

@MainActor
public final class PlayerController {
    public init() {}

    public static func accessibilityAvailable() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func installedPlayers(_ profiles: [PlayerProfile] = [.netease]) -> [PlayerProfile] {
        profiles.filter { applicationURL(for: $0) != nil }
    }

    public func launch(_ profile: PlayerProfile) async -> PlatformResult {
        do {
            let app = try await application(for: profile, activate: true)
            guard !app.isTerminated else { return .init(.failed, "\(profile.name) 已退出。") }
            return .init(.confirmed, "\(profile.name) 已打开。")
        } catch {
            return .init(.unavailable, error.localizedDescription)
        }
    }

    public func perform(
        _ action: PlaybackAction,
        on profile: PlayerProfile,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> PlatformResult {
        guard isCurrent(), !Task.isCancelled else { return .init(.unavailable, "播放器选择已变更，本次操作已取消。") }
        guard Self.accessibilityAvailable() else {
            return .init(.unavailable, "请开启 Orvio 的辅助功能权限，以定向控制\(profile.name)。")
        }
        do {
            let app = try await application(for: profile, activate: false)
            guard isCurrent(), !Task.isCancelled else { return .init(.unavailable, "播放器选择已变更，本次操作已取消。") }
            if profile.bundleID == PlayerProfile.soda.bundleID {
                return await performSoda(action, in: app, isCurrent: isCurrent)
            }
            let pid = app.processIdentifier
            return await Task.detached(priority: .userInitiated) {
                await PlayerAccessibility(pid: pid).perform(action, on: profile, isCurrent: isCurrent)
            }.value
        } catch {
            return .init(.unavailable, error.localizedDescription)
        }
    }

    public func adjustPlayerVolume(up: Bool, on profile: PlayerProfile,
                                   isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) async -> PlatformResult {
        let usesSodaShortcut = profile.bundleID == PlayerProfile.soda.bundleID
        let permitted = usesSodaShortcut ? CGPreflightPostEventAccess() : Self.accessibilityAvailable()
        guard permitted else {
            return .init(.unavailable, "请在「音乐 → 开启辅助功能权限」允许当前 Orvio控制播放器音量。")
        }
        do {
            let app = try await application(for: profile, activate: false)
            guard isCurrent() else { return .init(.unavailable, "播放器选择已变更，本次操作已取消。") }
            if usesSodaShortcut {
                return await sendSodaShortcut(up ? .volumeUp : .volumeDown, in: app, isCurrent: isCurrent)
            }
            let pid = app.processIdentifier
            return await Task.detached(priority: .userInitiated) {
                await MainActor.run {
                    guard isCurrent() else { return PlatformResult(.unavailable, "播放器选择已变更，本次操作已取消。") }
                    return PlayerAccessibility(pid: pid).adjustVolume(up: up, name: profile.name)
                }
            }.value
        } catch {
            return .init(.unavailable, error.localizedDescription)
        }
    }

    public func setPlayerVolume(_ percent: Int?, on profile: PlayerProfile,
                                isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> PlatformResult {
        guard Self.accessibilityAvailable(), isCurrent() else { return .init(.unavailable, "请确认当前播放器及 Orvio 辅助功能权限。") }
        do {
            let app = try await application(for: profile, activate: false)
            let pid = app.processIdentifier
            return await Task.detached(priority: .userInitiated) {
                await PlayerAccessibility(pid: pid).setVolumeOrMute(percent, name: profile.name, isCurrent: isCurrent)
            }.value
        } catch { return .init(.unavailable, error.localizedDescription) }
    }

    private func performSoda(_ action: PlaybackAction, in app: NSRunningApplication,
                             isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> PlatformResult {
        if let shortcut = SodaPlaybackShortcut(action: action) {
            return await sendSodaShortcut(shortcut, in: app, isCurrent: isCurrent)
        }
        // A toggle cannot safely implement an explicit play/pause request without state.
        let pid = app.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            await PlayerAccessibility(pid: pid).perform(action, on: .soda, isCurrent: isCurrent)
        }.value
    }

    private func sendSodaShortcut(_ shortcut: SodaPlaybackShortcut, in app: NSRunningApplication,
                                  isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> PlatformResult {
        guard CGPreflightPostEventAccess() else { return .init(.unavailable, "请开启 Orvio 辅助功能权限以控制汽水音乐。") }
        let keyCode = CGKeyCode(shortcut.keyCode)
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let release = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return .init(.failed, "无法生成汽水音乐的应用内快捷键。")
        }
        down.flags = shortcut.flags
        release.flags = down.flags

        // Use the player's application shortcut, which needs its window to have focus.
        let previous = NSWorkspace.shared.frontmostApplication
        let needsActivation = !app.isActive
        defer {
            if needsActivation, app.isActive, let previous, !previous.isTerminated,
               previous.processIdentifier != app.processIdentifier {
                _ = previous.activate()
            }
        }
        if needsActivation {
            guard app.activate() else {
                return .init(.unavailable, "无法激活汽水音乐窗口。")
            }
            for _ in 0..<20 where !app.isActive && !app.isTerminated {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        guard !Task.isCancelled, isCurrent(), app.isActive, !app.isTerminated,
              app.bundleIdentifier == PlayerProfile.soda.bundleID else {
            return .init(.unavailable, "播放器选择已变更或汽水音乐窗口未就绪。")
        }
        let accessibility = PlayerAccessibility(pid: app.processIdentifier)
        guard accessibility.focusPlaybackSurface() else {
            return .init(.unavailable, "汽水音乐正在编辑文字，请先离开文字输入框。")
        }
        down.postToPid(app.processIdentifier)
        // The Electron renderer needs a separate key-down and key-up event turn.
        try? await Task.sleep(for: .milliseconds(120))
        release.postToPid(app.processIdentifier)
        if needsActivation {
            // Give the player time to handle the shortcut before returning focus.
            try? await Task.sleep(for: .milliseconds(120))
        }
        return .init(.submitted, "已向汽水音乐发送\(shortcut.title)指令。")
    }

    private func application(for profile: PlayerProfile, activate: Bool) async throws -> NSRunningApplication {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: profile.bundleID)
            .first(where: { !$0.isTerminated }) {
            if activate { _ = app.activate() }
            return app
        }
        guard let url = applicationURL(for: profile) else {
            throw PlayerLaunchError.notInstalled(profile.name)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.createsNewApplicationInstance = false
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func applicationURL(for profile: PlayerProfile) -> URL? {
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleID) {
            return registered
        }
        if profile.bundleID == PlayerProfile.netease.bundleID {
            let standardPath = URL(fileURLWithPath: "/Applications/NeteaseMusic.app", isDirectory: true)
            if Bundle(url: standardPath)?.bundleIdentifier == profile.bundleID {
                return standardPath
            }
        }
        return nil
    }

}

enum SodaPlaybackShortcut {
    case toggle, previous, next, volumeUp, volumeDown

    init?(action: PlaybackAction) {
        switch action {
        case .toggle: self = .toggle
        case .previous: self = .previous
        case .next: self = .next
        case .play, .pause: return nil
        }
    }

    var keyCode: Int {
        switch self {
        case .toggle: kVK_Space
        case .previous: kVK_LeftArrow
        case .next: kVK_RightArrow
        case .volumeUp: kVK_UpArrow
        case .volumeDown: kVK_DownArrow
        }
    }

    var flags: CGEventFlags { self == .toggle ? [] : [.maskCommand, .maskSecondaryFn, .maskNumericPad] }

    var title: String {
        switch self {
        case .toggle: "播放／暂停"
        case .previous: "上一首"
        case .next: "下一首"
        case .volumeUp: "提高音量"
        case .volumeDown: "降低音量"
        }
    }
}

private enum PlayerLaunchError: LocalizedError {
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(name): "未找到已安装的\(name)。"
        }
    }
}

private struct PlayerAccessibility {
    private let pid: pid_t
    private let app: AXUIElement

    private static let defaultControls: [PlaybackAction: [String]] = [
        .play: ["播放", "播放音乐", "继续播放", "Play", "Resume"],
        .pause: ["暂停", "暂停播放", "Pause"],
        .toggle: ["播放/暂停", "播放／暂停", "播放 / 暂停", "Play/Pause", "Play or Pause"],
        .previous: ["上一首", "上一曲", "上一个", "Previous", "Previous Track", "Previous Song"],
        .next: ["下一首", "下一曲", "下一个", "Next", "Next Track", "Next Song"]
    ]
    init(pid: pid_t) {
        self.pid = pid
        self.app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.22)
    }

    func perform(_ action: PlaybackAction, on profile: PlayerProfile,
                 isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> PlatformResult {
        let titles = Self.defaultControls.merging(profile.controls) { _, customized in customized }
        let playing = (action == .previous || action == .next) ? nil : playbackState(titles: titles)
        if action == .play && playing == true { return .init(.confirmed, "\(profile.name) 正在播放。") }
        if action == .pause && playing == false { return .init(.confirmed, "\(profile.name) 已暂停。") }
        let resolved: PlaybackAction
        if action == .toggle, let playing {
            resolved = playing ? .pause : .play
        } else {
            resolved = action
        }

        let labels = titles[resolved, default: []]
        var control = uniqueMatch(in: menuRoots(), titles: labels)
            ?? uniqueMatch(in: windowRoots(), titles: labels)
        if control == nil && action == .toggle && resolved != .toggle {
            let toggle = titles[.toggle, default: []]
            control = uniqueMatch(in: menuRoots(), titles: toggle)
                ?? uniqueMatch(in: windowRoots(), titles: toggle)
        }
        guard let control else {
            return .init(.unavailable, "未找到\(profile.name) 的唯一播放控件。")
        }
        let submitted = await MainActor.run { isCurrent() && submitPress(control) }
        guard submitted else {
            return .init(.failed, "\(profile.name) 拒绝了播放控制。")
        }
        let expected = resolved == .play ? true : (resolved == .pause ? false : nil)
        if let expected {
            try? await Task.sleep(for: .milliseconds(230))
            if playbackState(titles: titles) == expected {
                return .init(.confirmed, expected ? "\(profile.name) 正在播放。" : "\(profile.name) 已暂停。")
            }
        }
        return .init(.submitted, "已向\(profile.name) 发送播放控制。")
    }

    func focusPlaybackSurface() -> Bool {
        guard let focused = element(kAXFocusedUIElementAttribute, of: app),
              let role = attribute(kAXRoleAttribute, of: focused) as? String else { return true }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return true }
        guard let window = windowRoots().first else { return false }
        var queue = [window]
        var index = 0
        while index < queue.count && index < 120 {
            let node = queue[index]
            index += 1
            if attribute(kAXRoleAttribute, of: node) as? String == "AXWebArea" {
                return AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            }
            queue.append(contentsOf: (attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? []).prefix(120))
        }
        return false
    }

    func adjustVolume(up: Bool, name: String) -> PlatformResult {
        let titles = up ? ["升高音量", "提高音量", "增加音量", "Increase Volume"]
                        : ["降低音量", "减小音量", "Decrease Volume"]
        guard let control = uniqueMatch(in: menuRoots(), titles: titles) else {
            return .init(.unavailable, "未找到\(name)的音量菜单。")
        }
        guard submitPress(control) else { return .init(.failed, "\(name)拒绝更改音量。") }
        return .init(.submitted, "已向\(name)发送音量调整。")
    }

    func setVolumeOrMute(_ percent: Int?, name: String,
                         isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> PlatformResult {
        if let percent {
            guard let slider = uniqueMatch(in: windowRoots(), titles: ["音量", "Volume"],
                                           allowedRoles: [kAXSliderRole], requiresPress: false),
                  let minimum = attribute(kAXMinValueAttribute, of: slider) as? NSNumber,
                  let maximum = attribute(kAXMaxValueAttribute, of: slider) as? NSNumber,
                  maximum.doubleValue > minimum.doubleValue else {
                return .init(.unavailable, "未找到\(name)可设置的音量控件。")
            }
            let value = minimum.doubleValue + (maximum.doubleValue - minimum.doubleValue) * Double(max(0, min(100, percent))) / 100
            let accepted = await MainActor.run {
                isCurrent() && AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: value)) == .success
            }
            return .init(accepted ? .submitted : .unavailable, accepted ? "已向\(name)设置音量 \(percent)%。" : "播放器选择已变更或音量控件不可用。")
        }
        guard let control = uniqueMatch(in: menuRoots() + windowRoots(), titles: ["静音", "取消静音", "Mute", "Unmute"]) else {
            return .init(.unavailable, "未找到\(name)的独立静音控件。")
        }
        let accepted = await MainActor.run { isCurrent() && submitPress(control) }
        return .init(accepted ? .submitted : .unavailable, accepted ? "已向\(name)发送静音切换。" : "播放器选择已变更或静音控件不可用。")
    }

    private func playbackState(titles: [PlaybackAction: [String]]) -> Bool? {
        let rootGroups: [([AXUIElement], Set<String>)] = [
            (windowRoots(), [kAXButtonRole, kAXCheckBoxRole]),
            (menuRoots(), [kAXMenuItemRole])
        ]
        for (roots, roles) in rootGroups {
            let play = uniqueMatch(in: roots, titles: titles[.play, default: []], allowedRoles: roles)
            let pause = uniqueMatch(in: roots, titles: titles[.pause, default: []], allowedRoles: roles)
            if play != nil && pause == nil { return false }
            if pause != nil && play == nil { return true }
        }
        return nil
    }

    private func windowRoots() -> [AXUIElement] {
        if let focused = element(kAXFocusedWindowAttribute, of: app) {
            return [focused]
        }
        if let main = element(kAXMainWindowAttribute, of: app) {
            return [main]
        }
        let windows = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
        return windows.count == 1 ? windows : []
    }

    private func menuRoots() -> [AXUIElement] {
        element(kAXMenuBarAttribute, of: app).map { [$0] } ?? []
    }

    private func uniqueMatch(
        in roots: [AXUIElement],
        titles: [String],
        allowedRoles: Set<String>? = nil,
        requiresPress: Bool = true
    ) -> AXUIElement? {
        let wanted = Set(titles.map(normalize))
        guard !wanted.isEmpty, !roots.isEmpty else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.95
        var queue = roots.map { ($0, 0) }
        var visited = Set<AXUIElement>()
        var match: AXUIElement?
        var completed = true
        var index = 0
        while index < queue.count && index < 640 && ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = queue[index]
            index += 1
            guard visited.insert(node).inserted, belongsToApplication(node) else { continue }
            guard let snapshot = snapshot(node) else {
                completed = false
                continue
            }
            let roleMatches = allowedRoles == nil || snapshot.role.map { allowedRoles?.contains($0) == true } == true
            if roleMatches, snapshot.labels.contains(where: { wanted.contains(normalize($0)) }), !requiresPress || canPress(node) {
                if match != nil { return nil }
                match = node
            }
            if depth < 24 {
                queue.append(contentsOf: snapshot.children.prefix(640).map { ($0, depth + 1) })
                if snapshot.children.count > 640 { completed = false }
            } else if !snapshot.children.isEmpty {
                completed = false
            }
        }
        return completed && index == queue.count ? match : nil
    }

    private func snapshot(_ node: AXUIElement) -> (role: String?, labels: [String], children: [AXUIElement])? {
        let keys = [
            kAXRoleAttribute, kAXChildrenAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXHelpAttribute, kAXIdentifierAttribute, kAXValueAttribute
        ]
        AXUIElementSetMessagingTimeout(node, 0.22)
        var response: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(node, keys as CFArray, [], &response)
        guard error == .success, let values = response as? [Any], values.count == keys.count else {
            return nil
        }
        let role = values[0] as? String
        var labels = values[2..<6].compactMap { $0 as? String }
        if role == kAXStaticTextRole, let text = values[6] as? String {
            labels.append(text)
        }
        return (role, labels, values[1] as? [AXUIElement] ?? [])
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private func belongsToApplication(_ element: AXUIElement) -> Bool {
        var elementPID: pid_t = 0
        return AXUIElementGetPid(element, &elementPID) == .success && elementPID == pid
    }

    private func canPress(_ element: AXUIElement) -> Bool {
        guard attribute(kAXEnabledAttribute, of: element) as? Bool != false else { return false }
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success
            && (actions as? [String])?.contains(kAXPressAction) == true
    }

    private func submitPress(_ element: AXUIElement) -> Bool {
        guard belongsToApplication(element), canPress(element) else { return false }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        // An AX timeout may occur after the application received the request.
        return result == .success || result == .cannotComplete
    }

    private func element(_ key: String, of node: AXUIElement) -> AXUIElement? {
        guard let value = attribute(key, of: node), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func attribute(_ key: String, of node: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }
}
