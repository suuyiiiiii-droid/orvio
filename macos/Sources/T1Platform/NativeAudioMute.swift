import AppKit
import CoreAudio
import ApplicationServices
import OSLog
import os

public enum NativeMediaKeys {
    public enum Key: Int { case volumeUp = 0, volumeDown = 1, playPause = 16, next = 17, previous = 18 }

    @MainActor public static func send(_ key: Key) -> PlatformResult {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            return .init(.unavailable, "原生媒体键兼容需要当前 Orvio 的辅助功能权限。")
        }
        for state in [0xA, 0xB] {
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8,
                data1: (key.rawValue << 16) | (state << 8), data2: -1)?.cgEvent else {
                return .init(.failed, "未能创建系统媒体键。")
            }
            event.post(tap: .cghidEventTap)
        }
        return .init(.submitted, "已向 macOS 发送原生媒体键。")
    }
}

/// A process belongs to a player only when its executable is inside that exact
/// application bundle. This includes Electron audio helpers without matching
/// unrelated applications that happen to share a bundle-ID prefix.
struct AudioProcessOwner {
    static func contains(executable: URL, in application: URL) -> Bool {
        let root = application.resolvingSymlinksInPath().standardizedFileURL.path
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }
}

private final class MuteRenderClock: @unchecked Sendable {
    let calls = OSAllocatedUnfairLock(initialState: 0)
}

private func muteIOBlock(_ clock: MuteRenderClock) -> AudioDeviceIOBlock {
    { _, _, _, output, _ in
        // Read buffer metadata only. Silence this aggregate's own contribution
        // without reading or copying any captured audio samples.
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        clock.calls.withLock { $0 += 1 }
    }
}

/// A running, private tap-only aggregate. The IO callback ignores every audio
/// buffer: it neither reads samples nor forwards, records, or saves them.
@available(macOS 14.2, *)
@MainActor
private final class MuteTapSession {
    private let log = Logger(subsystem: "local.t1controller.app", category: "AudioMute")
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var started = false
    private let clock = MuteRenderClock()
    private let description: CATapDescription
    let name: String
    var active: Bool { started && aggregate != 0 && proc != nil }

    init(name: String, processes: [AudioObjectID]?) {
        self.name = name
        description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) } ??
            CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Orvio · " + name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
    }

    isolated deinit { _ = stop() }

    func start() async -> PlatformResult {
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != 0 else { return failure("创建音频 tap", status) }
        guard let uid = AudioHardware.string(tap, AudioHardware.property(kAudioTapPropertyUID)) else {
            return failure("读取 tap 标识", kAudioHardwareBadObjectError)
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orvio · 静音处理",
            kAudioAggregateDeviceUIDKey: "local.orvio.mute." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid,
                                              kAudioSubTapDriftCompensationKey: true]]
        ]
        guard let outputUID = SystemOutput.info()?.uid else { return failure("读取输出设备", kAudioHardwareBadDeviceError) }
        var anchored = config
        anchored[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
        anchored[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        status = AudioHardwareCreateAggregateDevice(anchored as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else { return failure("创建私有音频链路", status) }
        let clock = self.clock
        let device = aggregate
        // IO registration itself can request system audio consent, before
        // AudioDeviceStart. Both calls must leave the main run loop available.
        let registration = await Task.detached(priority: .userInitiated) {
            var callback: AudioDeviceIOProcID?
            let registered = AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil, muteIOBlock(clock))
            guard registered == noErr, let callback else { return (registered, callback, false) }
            let started = AudioDeviceStart(device, callback)
            return (started, Optional(callback), started == noErr)
        }.value
        status = registration.0; proc = registration.1
        guard proc != nil else { return failure("创建静音回调", status) }
        guard status == noErr else { return failure("启动静音链路", status) }
        started = registration.2
        for _ in 0..<40 {
            if Task.isCancelled { return failure("操作已取消", kAudioHardwareIllegalOperationError) }
            if clock.calls.withLock({ $0 }) > 0 {
                log.notice("scope=\(self.name, privacy: .public) running=true callbacks=\(clock.calls.withLock { $0 }) tap=\(self.tap) aggregate=\(self.aggregate) samplesRead=0")
                return .init(.confirmed, "\(name) · 已静音（音频处理链路已运行）。")
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return failure("操作已取消", kAudioHardwareIllegalOperationError) }
        }
        return failure("静音回调未运行，请检查系统音频权限", kAudioHardwareNotRunningError)
    }

    func updateProcesses(_ ids: [AudioObjectID]) -> Bool {
        guard active else { return false }
        if description.processes == ids { return true }
        let old = description.processes
        description.processes = ids
        if AudioHardware.set(tap, AudioHardware.property(kAudioTapPropertyDescription),
                             Optional(Unmanaged.passUnretained(description))) { return true }
        description.processes = old
        return false
    }

    @discardableResult func stop() -> OSStatus {
        var first: OSStatus = noErr
        func record(_ value: OSStatus) { if first == noErr, value != noErr { first = value } }
        if started, aggregate != 0 { record(AudioDeviceStop(aggregate, proc)); started = false }
        if let proc, aggregate != 0 {
            let status = AudioDeviceDestroyIOProcID(aggregate, proc); record(status)
            if status == noErr { self.proc = nil }
        }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate); record(status)
            if status == noErr { aggregate = 0; proc = nil }
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap); record(status)
            if status == noErr { tap = 0 }
        }
        return first
    }

    private func failure(_ stage: String, _ status: OSStatus) -> PlatformResult {
        let cleanup = stop()
        log.error("scope=\(self.name, privacy: .public) stage=\(stage, privacy: .public) HAL=\(status) cleanup=\(cleanup)")
        return .init(.unavailable, "\(name)静音未生效：\(stage)（HAL \(status)）。" +
                     (cleanup == noErr ? "" : " 清理未完成，请退出 Orvio 解除。"))
    }
}

/// Native mute for fixed-level outputs and selected-player mute use the same
/// running HAL implementation, with separate global and application scopes.
@MainActor
public final class NativeAudioMute {
    private var systemSession: AnyObject?
    private var playerSessions: [String: AnyObject] = [:]
    private var playerURLs: [String: URL] = [:]
    private var changing = false
    private var outputUID: String?
    private var termination: (any NSObjectProtocol)?
    private var refreshTask: Task<Void, Never>?
    public var onChange: ((Bool) -> Void)?
    public var onPlayerChange: ((String, Bool) -> Void)?
    public var isSoftwareMuted: Bool {
        if #available(macOS 14.2, *) { return (systemSession as? MuteTapSession)?.active == true }
        return false
    }

    public init() {
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
    }

    isolated deinit {
        if let termination { NotificationCenter.default.removeObserver(termination) }
        releaseAll()
    }

    public func toggle() async -> PlatformResult {
        guard !changing else { return .init(.unavailable, "静音正在切换，请稍候。") }
        changing = true; defer { changing = false }
        if systemSession != nil { return release() }
        if SystemOutput.supportsNativeMute { return SystemOutput.toggleMute() }
        guard #available(macOS 14.2, *), let output = SystemOutput.info() else {
            return .init(.unavailable, "当前输出没有静音接口；软件静音需要 macOS 14.2 或更新版本。")
        }
        let session = MuteTapSession(name: "系统输出", processes: nil)
        systemSession = session; outputUID = output.uid
        let result = await session.start()
        if !session.active { systemSession = nil; outputUID = nil }
        onChange?(isSoftwareMuted)
        return result
    }

    public func handleNativeKeyFallback() async -> PlatformResult? {
        guard systemSession != nil || !SystemOutput.supportsNativeMute else { return nil }
        return await toggle()
    }

    public func togglePlayer(_ profile: PlayerProfile,
                             isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> PlatformResult {
        guard !changing, isCurrent() else { return .init(.unavailable, "播放器选择已变化或静音正在切换。") }
        guard #available(macOS 14.2, *) else { return .init(.unavailable, "播放器音频静音需要 macOS 14.2 或更新版本。") }
        let id = profile.bundleID
        if let session = playerSessions[id] as? MuteTapSession {
            let result = session.stop()
            if result == noErr { playerSessions[id] = nil; playerURLs[id] = nil; onPlayerChange?(id, false) }
            return .init(result == noErr ? .confirmed : .failed, result == noErr ? "\(profile.name) · 已取消静音。" : "取消播放器静音失败（HAL \(result)）。")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return .init(.unavailable, "未找到所选播放器 \(profile.name)。")
        }
        let ids = Self.processes(in: url)
        guard !ids.isEmpty else { return .init(.unavailable, "未找到\(profile.name)的音频会话，请先播放音乐。") }
        changing = true; defer { changing = false }
        let session = MuteTapSession(name: profile.name, processes: ids)
        let result = await session.start()
        guard isCurrent(), !Task.isCancelled else {
            _ = session.stop()
            return .init(.unavailable, "播放器选择已变化，本次静音已撤销。")
        }
        if session.active {
            playerSessions[id] = session; playerURLs[id] = url
            onPlayerChange?(id, true); startRefresh()
        }
        return result
    }

    @discardableResult public func release() -> PlatformResult {
        if #available(macOS 14.2, *), let session = systemSession as? MuteTapSession {
            let status = session.stop()
            guard status == noErr else { return .init(.failed, "解除系统静音失败（HAL \(status)），请重试。") }
        }
        systemSession = nil; outputUID = nil; onChange?(false)
        return .init(.confirmed, "系统软件静音已关闭。")
    }

    public func outputChanged(to uid: String?) {
        if isSoftwareMuted, uid != outputUID { _ = release() }
    }

    private func releaseAll() {
        refreshTask?.cancel(); refreshTask = nil
        _ = release()
        if #available(macOS 14.2, *) {
            for session in playerSessions.values { _ = (session as? MuteTapSession)?.stop() }
        }
        playerSessions.removeAll(); playerURLs.removeAll()
    }

    @available(macOS 14.2, *) private func startRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                for (id, url) in self.playerURLs {
                    let ids = Self.processes(in: url)
                    if ids.isEmpty || (self.playerSessions[id] as? MuteTapSession)?.updateProcesses(ids) != true {
                        _ = (self.playerSessions[id] as? MuteTapSession)?.stop()
                        self.playerSessions[id] = nil; self.playerURLs[id] = nil
                        self.onPlayerChange?(id, false)
                    }
                }
                if self.playerSessions.isEmpty { self.refreshTask = nil; return }
            }
        }
    }

    @available(macOS 14.2, *) private static func processes(in url: URL) -> [AudioObjectID] {
        var address = AudioHardware.property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioHardware.system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioHardware.system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.filter { id in
            guard let pid = AudioHardware.get(id, AudioHardware.property(kAudioProcessPropertyPID), initial: pid_t(0)), pid > 0 else { return false }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { return false }
            return AudioProcessOwner.contains(executable: URL(fileURLWithPath: String(cString: path)), in: url)
        }.sorted()
    }
}
