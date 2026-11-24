import AppKit
import CoreGraphics
import Foundation

public struct DisplayCalibration: Codable, Sendable {
    public let uuid: UUID

    public init(uuid: UUID) {
        self.uuid = uuid
    }
}

public struct ConnectedDisplay: Identifiable, Sendable {
    public let id: UUID
    public let name: String
}

public struct DisplayReading: Sendable {
    public let value: UInt16?
    public let result: PlatformResult
}

@MainActor
public final class BetterDisplayInput {
    private static let bundleID = "pro.betterdisplay.BetterDisplay"

    public init() {}

    public static func connectedDisplays() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let displayUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let id = UUID(uuidString: CFUUIDCreateString(nil, displayUUID) as String) else { return nil }
            return ConnectedDisplay(id: id, name: screen.localizedName)
        }
    }

    public func read(_ calibration: DisplayCalibration) async -> DisplayReading {
        guard let executable = executableURL() else {
            return DisplayReading(value: nil, result: .init(.unavailable, "请启动 BetterDisplay 并在显示器启用 DDC/CI。"))
        }
        do {
            let response = try await LocalProcess.run(
                executable,
                arguments: arguments("get", calibration: calibration) + ["-value"],
                timeout: 3
            )
            guard response.status == 0, let value = Self.parseInputValue(response.stdout) else {
                return DisplayReading(value: nil, result: .init(.unavailable, "显示器未返回可识别的 DDC/CI 输入值。"))
            }
            return DisplayReading(value: value, result: .init(.confirmed, String(format: "当前显示器输入 0x%02X。", value)))
        } catch {
            return DisplayReading(value: nil, result: .init(.failed, "读取 BetterDisplay 输入失败或超时。"))
        }
    }

    public func set(_ value: UInt16, on calibration: DisplayCalibration) async -> PlatformResult {
        guard (1...255).contains(value) else { return .init(.unavailable, "请填写校准得到的显示器输入值。") }
        guard let executable = executableURL() else {
            return .init(.unavailable, "请启动 BetterDisplay 并在显示器启用 DDC/CI。")
        }
        let before = await read(calibration)
        if before.value == value { return .init(.confirmed, "显示器已经在所选输入。") }
        do {
            let response = try await LocalProcess.run(
                executable,
                arguments: arguments("set", calibration: calibration) + ["-value=\(value)"],
                timeout: 4
            )
            guard response.status == 0, !Self.rejected(response.stdout) else {
                return .init(.failed, "BetterDisplay 拒绝了输入切换。请检查显示器选择、线缆和 DDC/CI。")
            }
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(250))
                if await read(calibration).value == value {
                    return .init(.confirmed, "已读回所选显示器输入。")
                }
            }
            return .init(.submitted, "已发送显示器输入切换，等待画面确认。")
        } catch LocalProcess.Failure.timeout {
            return .init(.failed, "显示器命令超时，输入状态未知。请查看画面确认。")
        } catch {
            return .init(.failed, "无法完成 BetterDisplay 输入切换。")
        }
    }

    private func executableURL() -> URL? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .contains(where: { !$0.isTerminated }),
              let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
              let url = Bundle(url: bundleURL)?.executableURL,
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private func arguments(_ operation: String, calibration: DisplayCalibration) -> [String] {
        [operation, "-UUID=\(calibration.uuid.uuidString)", "-feature=ddc", "-vcp=0x60"]
    }

    static func parseInputValue(_ output: String) -> UInt16? {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var valueText = output
        if let separator = output.firstIndex(where: { $0 == ":" || $0 == "=" }) {
            let label = output[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["value", "current", "current value"].contains(label) else { return nil }
            valueText = output[output.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        let value = valueText.lowercased().hasPrefix("0x")
            ? UInt16(valueText.dropFirst(2), radix: 16)
            : UInt16(valueText)
        return value.flatMap { (1...255).contains($0) ? $0 : nil }
    }

    private static func rejected(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["error", "failed", "failure", "no device", "false", "unsupported"].contains {
            text == $0 || text.hasPrefix("\($0):") || text.hasPrefix("\($0) ")
        }
    }
}

public struct KMFUCalibration: Codable, Sendable {
    public let keyCode: UInt16
    public let command: Bool
    public let option: Bool
    public let control: Bool
    public let shift: Bool
    public let verified: Bool

    public init(
        keyCode: UInt16,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        verified: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.verified = verified
    }
}

@MainActor
public final class KMFURoute {
    private static let bundleID = "cn.wch.USBCrossLink"

    public init() {}

    public func toggle(_ calibration: KMFUCalibration, confirmedSource: Bool) -> PlatformResult {
        guard calibration.verified, confirmedSource else {
            return .init(.unavailable, "请确认当前外设归属并校准 KMFU 快捷键。也可在 KMFU 界面手动交接。")
        }
        guard calibration.keyCode < 128 else {
            return .init(.unavailable, "KMFU 快捷键配置无效。")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .contains(where: { !$0.isTerminated }) else {
            return .init(.unavailable, "请先启动沁恒 KMFU。")
        }
        guard CGPreflightPostEventAccess() else {
            return .init(.unavailable, "请在系统设置中给 Orvio辅助功能权限。")
        }
        var flags: CGEventFlags = []
        if calibration.command { flags.insert(.maskCommand) }
        if calibration.option { flags.insert(.maskAlternate) }
        if calibration.control { flags.insert(.maskControl) }
        if calibration.shift { flags.insert(.maskShift) }
        let source = CGEventSource(stateID: .privateState)
        guard !flags.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: calibration.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: calibration.keyCode, keyDown: false) else {
            return .init(.unavailable, "请校准带修饰键的 KMFU 切换快捷键。")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .init(.submitted, "已发送 KMFU 快捷键。请确认键鼠、音响和接收器的实际归属。")
    }
}
