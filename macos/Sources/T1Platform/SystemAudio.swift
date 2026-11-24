import AudioToolbox
import CoreAudio
import Foundation

public struct AudioOutputInfo: Sendable, Equatable {
    public let uid: String?
    public let name: String
    public let volumePercent: Int?
    public let isMuted: Bool?
}

public struct AudioInputInfo: Identifiable, Sendable, Equatable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let isDefault: Bool
}

public enum SystemOutput {
    public static func info() -> AudioOutputInfo? {
        guard let device = AudioHardware.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return info(for: device)
    }

    public static func adjust(by deltaPercent: Int) -> PlatformResult {
        guard let device = AudioHardware.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice) else {
            return .init(.unavailable, "未找到系统音频输出。")
        }
        guard let current = info(for: device).volumePercent else { return unsupported(device) }
        return set(percent: current + min(max(deltaPercent, -100), 100), device: device)
    }

    public static func set(percent: Int) -> PlatformResult {
        guard let device = AudioHardware.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice) else {
            return .init(.unavailable, "未找到系统音频输出。")
        }
        return set(percent: percent, device: device)
    }

    public static func toggleMute() -> PlatformResult {
        guard let device = AudioHardware.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice) else {
            return .init(.unavailable, "未找到系统音频输出。")
        }
        let property = outputProperty(kAudioDevicePropertyMute)
        guard AudioHardware.isSettable(device, property),
              let previous = AudioHardware.get(device, property, initial: UInt32(0)) else {
            return .init(.unavailable, "「\(info(for: device).name)」的静音状态无法由系统控制。")
        }
        let value: UInt32 = previous == 0 ? 1 : 0
        guard AudioHardware.set(device, property, value) else {
            return .init(.failed, "系统未能更改音频输出的静音状态。")
        }
        if AudioHardware.get(device, property, initial: UInt32(0)) == value {
            return .init(.confirmed, value == 1 ? "系统输出已静音。" : "系统输出已取消静音。")
        }
        return .init(.submitted, "已提交静音设置，等待设备确认。")
    }

    public static func observeDefaultOutput(
        _ onChange: @escaping @Sendable (AudioOutputInfo?) -> Void
    ) -> AudioOutputObservation? {
        AudioOutputObservation(onChange: onChange)
    }

    private static func info(for device: AudioDeviceID) -> AudioOutputInfo {
        let uid = AudioHardware.string(device, AudioHardware.property(kAudioDevicePropertyDeviceUID))
        let name = AudioHardware.string(device, AudioHardware.property(kAudioObjectPropertyName)) ?? "系统音频输出"
        let volume = volumeProperty(device)
            .flatMap { AudioHardware.get(device, $0, initial: Float32(0)) }
            .flatMap { $0.isFinite ? Int((100 * min(max($0, 0), 1)).rounded()) : nil }
        let muted = AudioHardware.get(device, outputProperty(kAudioDevicePropertyMute), initial: UInt32(0))
        return AudioOutputInfo(uid: uid, name: name, volumePercent: volume, isMuted: muted.map { $0 != 0 })
    }

    private static func set(percent: Int, device: AudioDeviceID) -> PlatformResult {
        guard let property = volumeProperty(device), AudioHardware.isSettable(device, property) else {
            return unsupported(device)
        }
        let target = min(max(percent, 0), 100)
        guard AudioHardware.set(device, property, Float32(target) / 100) else {
            return .init(.failed, "系统未能更改音频输出的音量。")
        }
        if let volume = info(for: device).volumePercent, abs(volume - target) <= 1 {
            return .init(.confirmed, "系统输出音量 \(volume)%。")
        }
        return .init(.submitted, "已提交系统音量 \(target)%，等待设备确认。")
    }

    private static func unsupported(_ device: AudioDeviceID) -> PlatformResult {
        .init(.unavailable, "「\(info(for: device).name)」未提供可用的系统音量控制。")
    }

    private static func volumeProperty(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        [
            outputProperty(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            outputProperty(kAudioDevicePropertyVolumeScalar)
        ].first(where: { AudioHardware.isSettable(device, $0) })
    }

    private static func outputProperty(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioHardware.property(selector, scope: kAudioDevicePropertyScopeOutput)
    }
}

public final class AudioOutputObservation {
    private let callbackQueue = DispatchQueue(label: "T1Controller.CoreAudio")
    private let listener: AudioObjectPropertyListenerBlock

    fileprivate init?(onChange: @escaping @Sendable (AudioOutputInfo?) -> Void) {
        listener = { _, _ in onChange(SystemOutput.info()) }
        var address = AudioHardware.property(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectAddPropertyListenerBlock(
            AudioHardware.system, &address, callbackQueue, listener
        ) == noErr else { return nil }
    }

    deinit {
        var address = AudioHardware.property(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioHardware.system, &address, callbackQueue, listener)
    }
}

enum AudioHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func defaultDevice(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let id = get(system, property(selector), initial: AudioDeviceID(0)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func inputDevices() -> [(id: AudioDeviceID, info: AudioInputInfo)] {
        let defaultID = defaultDevice(for: kAudioHardwarePropertyDefaultInputDevice)
        var deviceList = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &deviceList, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &deviceList, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return devices.compactMap { id in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0,
                  let uid = string(id, property(kAudioDevicePropertyDeviceUID)),
                  let name = string(id, property(kAudioObjectPropertyName)) else { return nil }
            return (id, AudioInputInfo(uid: uid, name: name, isDefault: id == defaultID))
        }.sorted { lhs, rhs in
            if lhs.info.isDefault != rhs.info.isDefault { return lhs.info.isDefault }
            return lhs.info.name.localizedStandardCompare(rhs.info.name) == .orderedAscending
        }
    }

    static func property(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    static func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    static func get<T>(
        _ id: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T
    ) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    static func set<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        return withUnsafeBytes(of: value) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32($0.count), $0.baseAddress!) == noErr
        }
    }

    static func string(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        get(id, address, initial: Optional<Unmanaged<CFString>>.none)?
            .map { $0.takeRetainedValue() as String }
    }
}
