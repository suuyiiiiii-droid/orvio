import AppKit
import CryptoKit
import IOKit.hid
import OSLog

private let t1ReportLog = Logger(subsystem: "local.t1controller.app", category: "T1VoiceReport")

public enum HIDPermission: String, Sendable {
    case granted, denied, unknown
}

public struct HIDDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let fingerprint: String
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let locationID: UInt32
    public let transport: String
    public let usagePage: Int
    public let usage: Int
    public let isSharedHub: Bool

    public var isDirectT1Receiver: Bool {
        vendorID == 0x1915 && productID == 0x1025 && transport == "USB" &&
            usagePage == 0x01 && (usage == 0x02 || usage == 0x06)
    }

    public var isXiaomiBluetoothRemote: Bool {
        vendorID == 0x2717 && productID == 0x32B8 &&
            (transport == "Bluetooth Low Energy" || transport == "Bluetooth") &&
            usagePage == 0x01 && usage == 0x06
    }

    public var isChromecastRemote: Bool {
        vendorID == 0x18D1 && productID == 0x9450 &&
            (transport == "Bluetooth Low Energy" || transport == "Bluetooth") &&
            usagePage == 0x01 && usage == 0x06
    }

    /// The keyboard and mouse share a USB location. Never combine collections from two receivers.
    public static func directT1LearningGroup(in devices: [Self]) -> Set<String> {
        let receivers = devices.filter(\.isDirectT1Receiver)
        guard receivers.count == 2, let first = receivers.first, first.locationID != 0,
              receivers.allSatisfy({ $0.locationID == first.locationID }),
              Set(receivers.map(\.usage)) == [0x02, 0x06] else { return [] }
        return Set(receivers.map(\.id))
    }
}

public struct HIDControl: Identifiable, Codable, Hashable, Sendable {
    public let usagePage: UInt32
    public let usage: UInt32
    public let reportID: UInt32
    public let elementCookie: UInt32

    public var id: String {
        String(format: "hid:%04X:%04X:%02X", usagePage, usage, reportID)
    }
}

public enum HIDPhase: String, Sendable {
    case down, up, repeatPress
}

public enum HIDEventSource: Sendable { case hid, chromecastCompatibility }

public struct HIDEvent: Sendable {
    public let device: HIDDevice
    public let control: HIDControl
    public let phase: HIDPhase
    public let timestamp: TimeInterval
    public let integerValue: Int
    public let isMonitored: Bool
    public var source: HIDEventSource = .hid
}

public struct HIDReportObservation: Sendable {
    public let device: HIDDevice
    public let reportID: UInt32
    public let byteCount: Int
    /// Nil on the first report for the current diagnostic selection.
    public let changed: Bool?
    public let timestamp: TimeInterval
}

/// Runs its IOKit callbacks on the main run loop. The manager always opens devices in shared mode.
@MainActor
public final class HIDInput {
    public private(set) var permission: HIDPermission = .unknown
    public private(set) var errorMessage: String?

    public var devices: [HIDDevice] {
        connected.values.sorted { ($0.name, $0.usagePage, $0.usage, $0.id) < ($1.name, $1.usagePage, $1.usage, $1.id) }
    }

    public var isHoldingRemoteKey: Bool {
        held.contains { device, controls in
            (device.isDirectT1Receiver || device.isXiaomiBluetoothRemote || device.isChromecastRemote) && !controls.isEmpty
        }
    }

    public var diagnosticDeviceIDs: Set<String> = [] {
        didSet {
            guard diagnosticDeviceIDs != oldValue else { return }
            diagnosticDigest = nil
            let removed = oldValue.subtracting(diagnosticDeviceIDs)
            for device in connected.values where removed.contains(device.id) && !isMonitored(device) {
                resetHeldControls(of: device)
            }
        }
    }

    public var monitoredDeviceFingerprints: Set<String> = [] {
        didSet {
            for device in connected.values where oldValue.contains(device.fingerprint) &&
                !monitoredDeviceFingerprints.contains(device.fingerprint) && !diagnosticDeviceIDs.contains(device.id) {
                resetHeldControls(of: device)
            }
        }
    }

    public var onStateChange: (() -> Void)?
    public var onInput: ((HIDEvent) -> Void)?
    public var onDiagnosticReport: ((HIDReportObservation) -> Void)? {
        didSet { diagnosticDigest = nil }
    }
    public var onDeviceRemoved: ((HIDDevice) -> Void)?
    public var onInputReset: ((HIDDevice) -> Void)?
    public var onCompatibilityStateChange: (() -> Void)?
    public var onCompatibilityRoutingChange: (() -> Void)?
    public private(set) var chromecastCompatibilityStatus = "短报文兼容未开启"
    public var chromecastCompatibilityEnabled = false {
        didSet { if oldValue != chromecastCompatibilityEnabled { refreshChromecastCompatibility() } }
    }

    /// Only affected, uniquely identified report-2 firmware can bypass native
    /// isolation: these reports were rejected before reaching the OS key path.
    public func usesChromecastCompatibility(_ device: HIDDevice, key: HIDKey) -> Bool {
        chromecastCompatibilityEnabled && compatibilityDevice?.id == device.id && key.page == 0x0C &&
            ChromecastInputReport.consumerUsages.contains(key.usage)
    }

    private var manager: IOHIDManager?
    private var connected: [ObjectIdentifier: HIDDevice] = [:]
    private var held: [HIDDevice: Set<HIDControl>] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var reportTaps: [ObjectIdentifier: InputReportTap] = [:]
    private var diagnosticDigest: SHA256.Digest?
    private let chromecastLog = ChromecastLogInput()
    private var compatibilityDevice: HIDDevice?
    private var bleEndpoints: [String: ChromecastLogTopology.Endpoint] = [:]
    private var terminationObserver: (any NSObjectProtocol)?

    public init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }

    isolated deinit {
        closeManager()
        removeWorkspaceObservers()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Shows the system prompt only when called from an explicit authorization control.
    public func start(requestPermission: Bool = false) {
        if requestPermission, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if manager != nil {
            refreshPermission()
            return
        }
        permission = Self.checkPermission()
        openManager()
        refreshChromecastCompatibility()
        observeSleepAndWake()
        onStateChange?()
    }

    public func stop() {
        closeManager()
        removeWorkspaceObservers()
        resetHeldControls()
        connected.removeAll()
        diagnosticDeviceIDs = []
        errorMessage = nil
        onStateChange?()
    }

    public func refreshPermission() {
        let newPermission = Self.checkPermission()
        guard newPermission != permission else { return }
        permission = newPermission
        if manager != nil {
            reconnect()
        } else {
            onStateChange?()
        }
    }

    private static func checkPermission() -> HIDPermission {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .unknown
        }
    }

    private func openManager() {
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = newManager
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(newManager, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            let input = Unmanaged<HIDInput>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { input.deviceArrived(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, device in
            guard let context else { return }
            let input = Unmanaged<HIDInput>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { input.deviceDeparted(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(newManager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let input = Unmanaged<HIDInput>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { input.valueChanged(value) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        errorMessage = nil
        if permission == .granted {
            let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess {
                errorMessage = String(format: "无法打开 HID 输入（0x%08X）", result)
            }
        }
        if let existing = IOHIDManagerCopyDevices(newManager) as? Set<IOHIDDevice> {
            for device in existing { deviceArrived(device, notify: false) }
        }
    }

    private func closeManager() {
        compatibilityDevice = nil
        chromecastLog.stop()
        bleEndpoints.removeAll()
        guard let manager else { return }
        for tap in reportTaps.values { tap.unregister() }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        reportTaps.removeAll()
        diagnosticDigest = nil
    }

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetHeldControls() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.permission = Self.checkPermission()
                    self.reconnect()
                }
            }
        ]
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func reconnect() {
        closeManager()
        resetHeldControls()
        connected.removeAll()
        openManager()
        refreshChromecastCompatibility()
        diagnosticDeviceIDs.formIntersection(connected.values.map(\.id))
        onStateChange?()
    }

    private func deviceArrived(_ device: IOHIDDevice, notify: Bool = true) {
        let objectID = ObjectIdentifier(device)
        guard connected[objectID] == nil else { return }
        let identity = Self.identify(device)
        connected[objectID] = identity
        if identity.transport == "Bluetooth Low Energy" || identity.transport == "Bluetooth" {
            let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
            let version = (IOHIDDeviceGetProperty(device, kIOHIDVersionNumberKey as CFString) as? NSNumber)?.intValue
            bleEndpoints[identity.id] = ChromecastLogTopology.Endpoint(
                id: identity.id, affectedChromecast: identity.isChromecastRemote && version == 0x011B,
                inputReports: descriptor.flatMap(HIDReportDescriptor.inputBitCounts))
        }
        if permission == .granted {
            if identity.isChromecastRemote {
                reportTaps[objectID] = InputReportTap(device: device, identity: identity, layout: .chromecast, input: self)
            } else if identity.isXiaomiBluetoothRemote {
                reportTaps[objectID] = InputReportTap(device: device, identity: identity, layout: .xiaomi, input: self)
            } else if identity.isDirectT1Receiver,
                      let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
                      let layout = T1InputReport.Layout(descriptor: descriptor, primaryUsage: identity.usage) {
                reportTaps[objectID] = InputReportTap(device: device, identity: identity, layout: .t1(layout), input: self)
            }
        }
        resetHeldControls(matching: identity.fingerprint)
        refreshChromecastCompatibility()
        if notify { onStateChange?() }
    }

    private func deviceDeparted(_ device: IOHIDDevice) {
        let objectID = ObjectIdentifier(device)
        guard let identity = connected.removeValue(forKey: objectID) else { return }
        reportTaps.removeValue(forKey: objectID)?.unregister()
        bleEndpoints.removeValue(forKey: identity.id)
        resetHeldControls(matching: identity.fingerprint)
        diagnosticDeviceIDs.remove(identity.id)
        onDeviceRemoved?(identity)
        refreshChromecastCompatibility()
        onStateChange?()
    }

    private func setCompatibilityStatus(_ status: String) {
        guard status != chromecastCompatibilityStatus else { return }
        chromecastCompatibilityStatus = status
        onCompatibilityStateChange?()
    }

    private func refreshChromecastCompatibility() {
        let eligibleID = ChromecastLogTopology.eligibleDevice(in: Array(bleEndpoints.values))
        let candidate = connected.values.first { device in
            device.id == eligibleID && !reportTaps.values.contains {
                $0.identity.id == device.id && $0.receivedReports.contains(2)
            }
        }
        let desired = chromecastCompatibilityEnabled && permission == .granted ? candidate : nil
        if desired?.id != compatibilityDevice?.id {
            chromecastLog.stop()
            if let previous = compatibilityDevice { resetHeldControls(of: previous) }
            compatibilityDevice = desired
            onCompatibilityRoutingChange?()
        }
        guard let device = desired else {
            chromecastLog.stop()
            if !chromecastCompatibilityEnabled { setCompatibilityStatus("短报文兼容未开启") }
            else if permission != .granted { setCompatibilityStatus("短报文兼容等待输入监控授权") }
            else if connected.values.contains(where: \.isChromecastRemote) {
                let native = reportTaps.values.contains { $0.identity.isChromecastRemote && $0.receivedReports.contains(2) }
                setCompatibilityStatus(native ? "原生 HID 已收到报告 · 无需日志兼容" :
                    "兼容已暂停 · 需唯一的 0x011B 遥控器；其他蓝牙 HID 的短报告 2 或未知描述符会暂停兼容")
            } else { setCompatibilityStatus("等待连接 Chromecast Remote") }
            return
        }
        chromecastLog.onStatus = { [weak self] in self?.setCompatibilityStatus($0) }
        chromecastLog.onInterrupted = { [weak self] in
            guard let self, let current = self.compatibilityDevice else { return }
            self.resetHeldControls(of: current)
        }
        chromecastLog.onReport = { [weak self] usages in
            guard let self, self.compatibilityDevice?.id == device.id,
                  self.permission == .granted, self.chromecastCompatibilityEnabled else { return }
            let monitored = self.isMonitored(device)
            guard monitored || self.diagnosticDeviceIDs.contains(device.id) else { return }
            let previous = Set(self.held[device, default: []].filter { $0.reportID == 2 && $0.usagePage == 0x0C })
            let current = Set(usages.map { HIDControl(usagePage: 0x0C, usage: $0, reportID: 2, elementCookie: 0) })
            let tick = mach_absolute_time()
            for control in previous.subtracting(current).sorted(by: { $0.usage < $1.usage }) {
                self.sendButton(control, value: 0, on: device, ticks: tick, monitored: monitored, source: .chromecastCompatibility)
            }
            for control in current.subtracting(previous).sorted(by: { $0.usage < $1.usage }) {
                self.sendButton(control, value: 1, on: device, ticks: tick, monitored: monitored, source: .chromecastCompatibility)
            }
        }
        if !chromecastLog.isRunning { chromecastLog.start() }
    }

    private func isMonitored(_ device: HIDDevice) -> Bool {
        monitoredDeviceFingerprints.contains(device.fingerprint) &&
            Set(connected.values.lazy.filter { $0.fingerprint == device.fingerprint }.map(\.id)).count == 1
    }

    private func resetHeldControls(matching fingerprint: String) {
        for device in Array(held.keys) where device.fingerprint == fingerprint {
            resetHeldControls(of: device)
        }
    }

    private func resetHeldControls(of device: HIDDevice) {
        for tap in reportTaps.values where tap.identity.id == device.id {
            tap.voiceEdges = T1InputReport.VoiceEdges()
        }
        if held.removeValue(forKey: device) != nil { onInputReset?(device) }
    }

    private func resetHeldControls() {
        for device in Array(held.keys) { resetHeldControls(of: device) }
    }

    private func valueChanged(_ value: IOHIDValue) {
        guard permission == .granted, !diagnosticDeviceIDs.isEmpty || !monitoredDeviceFingerprints.isEmpty else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let rawDevice = IOHIDElementGetDevice(element)
        guard Self.isButton(element, page: page, usage: usage),
              let device = connected[ObjectIdentifier(rawDevice)],
              (1...MemoryLayout<CFIndex>.size).contains(IOHIDValueGetLength(value)) else { return }

        let monitored = isMonitored(device)
        guard monitored || diagnosticDeviceIDs.contains(device.id) else { return }
        let integerValue = IOHIDValueGetIntegerValue(value)
        guard integerValue == 0 || integerValue == 1 else { return }
        let reportID = IOHIDElementGetReportID(element)
        let cookie: UInt32
        if let tap = reportTaps[ObjectIdentifier(rawDevice)], tap.layout.covers(page: page, reportID: reportID) {
            if device.isDirectT1Receiver, page == 0x0C, usage == 0xCF, reportID == 0x02 {
                sendT1Voice(pressed: integerValue != 0, from: tap, ticks: IOHIDValueGetTimeStamp(value),
                            monitored: monitored, source: "element")
                return
            }
            // Fall back to IOKit values until a valid report arrives. Both sources share
            // the same control identity so a press spanning that transition can release.
            guard !tap.receivedReports.contains(reportID) else { return }
            cookie = 0
        } else {
            cookie = IOHIDElementGetCookie(element)
        }
        let control = HIDControl(usagePage: page, usage: usage, reportID: reportID,
                                 elementCookie: cookie)
        sendButton(control, value: integerValue, on: device, ticks: IOHIDValueGetTimeStamp(value), monitored: monitored)
    }

    private func sendButton(_ control: HIDControl, value: Int, on device: HIDDevice, ticks: UInt64, monitored: Bool,
                            source: HIDEventSource = .hid) {
        var pressed = held[device, default: []]
        let phase: HIDPhase
        if value == 1 {
            phase = pressed.insert(control).inserted ? .down : .repeatPress
        } else {
            guard pressed.remove(control) != nil else { return }
            phase = .up
        }
        held[device] = pressed.isEmpty ? nil : pressed
        onInput?(HIDEvent(device: device, control: control, phase: phase, timestamp: Self.seconds(ticks),
                          integerValue: value, isMonitored: monitored, source: source))
    }

    private func inputReport(
        _ bytes: UnsafeBufferPointer<UInt8>,
        id: UInt32,
        from tap: InputReportTap,
        ticks: UInt64
    ) {
        guard permission == .granted else { return }
        let device = tap.identity
        let monitored = isMonitored(device)
        guard monitored || diagnosticDeviceIDs.contains(device.id) else { return }
        let layout: T1InputReport.Layout
        switch tap.layout {
        case .chromecast:
            guard let report = ChromecastInputReport.pressedKeys(reportID: id, bytes: Array(bytes)) else { return }
            if id == 2, !tap.receivedReports.contains(id) {
                // A valid native report always wins. Stop compatibility before
                // emitting it so the same physical press cannot execute twice.
                tap.receivedReports.insert(id)
                refreshChromecastCompatibility()
            }
            sendSnapshot(report.usages, page: report.page, id: id, from: tap, ticks: ticks, monitored: monitored)
            return
        case .xiaomi:
            guard let keys = XiaomiInputReport.pressedKeys(reportID: id, bytes: bytes) else { return }
            sendSnapshot(keys, page: 0x07, id: id, from: tap, ticks: ticks, monitored: monitored)
            return
        case .t1(let t1Layout):
            layout = t1Layout
        }
        if id == 0x08 {
            guard diagnosticDeviceIDs.contains(device.id), let callback = onDiagnosticReport,
                  bytes.count == 16 || (bytes.count == 17 && bytes[0] == 0x08) else { return }
            let digest = SHA256.hash(data: bytes)
            let changed = diagnosticDigest.map { $0 != digest }
            diagnosticDigest = digest
            let time = Self.seconds(ticks)
            if time - tap.lastVendorLogAt >= 0.25 {
                tap.lastVendorLogAt = time
                t1ReportLog.notice("Vendor report 08 received at \(time), changed=\(changed ?? true)")
            }
            callback(HIDReportObservation(device: device, reportID: id, byteCount: bytes.count,
                                          changed: changed, timestamp: time))
            return
        }
        if let report = T1InputReport.pressedKeys(layout: layout, reportID: id, bytes: bytes) {
            sendSnapshot(report.usages, page: report.page, id: id, from: tap, ticks: ticks, monitored: monitored)
            return
        }
        guard layout.covers(page: 0x0C, reportID: id), id == 0x02 else { return }
        let offset: Int
        switch bytes.count {
        case 2: offset = 0
        case 3 where bytes[0] == 0x02: offset = 1
        default: return
        }
        let usage = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
        guard usage <= 0x043C else { return }
        if diagnosticDeviceIDs.contains(device.id), usage == 0xCF || usage == 0 {
            t1ReportLog.notice("Consumer report 02 voice=\(usage == 0xCF) at \(Self.seconds(ticks))")
        }
        let firstRawReport = tap.receivedReports.insert(id).inserted
        sendT1Voice(pressed: usage == 0xCF, from: tap, ticks: ticks, monitored: monitored, source: "report")
        if let previous = held[device]?.first(where: {
            $0.reportID == 0x02 && $0.usagePage == 0x0C && $0.usage != 0xCF
        }),
           previous.usage != usage {
            sendButton(previous, value: 0, on: device, ticks: ticks, monitored: monitored)
        }
        if usage != 0 && usage != 0xCF {
            let control = HIDControl(usagePage: 0x0C, usage: usage, reportID: 0x02, elementCookie: 0)
            if firstRawReport && held[device]?.contains(control) == true { return }
            sendButton(control, value: 1, on: device, ticks: ticks, monitored: monitored)
        }
    }

    private func sendT1Voice(
        pressed: Bool, from tap: InputReportTap, ticks: UInt64, monitored: Bool, source: String
    ) {
        let tick = ticks == 0 ? mach_absolute_time() : ticks
        guard tap.voiceEdges.accept(pressed: pressed, tick: tick) else { return }
        let control = HIDControl(usagePage: 0x0C, usage: 0xCF, reportID: 0x02, elementCookie: 0)
        t1ReportLog.notice("T1 voice \(pressed) via \(source, privacy: .public) at \(Self.seconds(tick))")
        sendButton(control, value: pressed ? 1 : 0, on: tap.identity, ticks: tick, monitored: monitored)
    }

    private func sendSnapshot(
        _ usages: Set<UInt32>, page: UInt32, id: UInt32, from tap: InputReportTap,
        ticks: UInt64, monitored: Bool
    ) {
        tap.receivedReports.insert(id)
        let device = tap.identity
        let previous = Set(held[device, default: []].lazy.filter { $0.reportID == id && $0.usagePage == page })
        let current = Set(usages.map { HIDControl(usagePage: page, usage: $0, reportID: id, elementCookie: 0) })
        for control in previous.subtracting(current).sorted(by: { $0.usage < $1.usage }) {
            sendButton(control, value: 0, on: device, ticks: ticks, monitored: monitored)
        }
        for control in current.subtracting(previous).sorted(by: { $0.usage < $1.usage }) {
            sendButton(control, value: 1, on: device, ticks: ticks, monitored: monitored)
        }
    }

    @MainActor
    private final class InputReportTap {
        enum Layout {
            case t1(T1InputReport.Layout), xiaomi, chromecast

            func covers(page: UInt32, reportID: UInt32) -> Bool {
                switch self {
                case .t1(let layout): return layout.covers(page: page, reportID: reportID)
                case .xiaomi: return page == 0x07 && reportID == 0x01
                case .chromecast: return (page == 0x07 && reportID == 1) || (page == 0x0C && reportID == 2)
                }
            }
        }

        let device: IOHIDDevice
        let identity: HIDDevice
        let layout: Layout
        weak var input: HIDInput?
        var receivedReports: Set<UInt32> = []
        var voiceEdges = T1InputReport.VoiceEdges()
        var lastVendorLogAt: TimeInterval = -.infinity
        private let buffer: UnsafeMutablePointer<UInt8>
        private static let capacity = 128

        init(device: IOHIDDevice, identity: HIDDevice, layout: Layout, input: HIDInput) {
            self.device = device
            self.identity = identity
            self.layout = layout
            self.input = input
            buffer = .allocate(capacity: Self.capacity)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.capacity, {
                context, result, _, type, reportID, report, count, ticks in
                guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput,
                      count > 0, count <= InputReportTap.capacity else { return }
                let tap = Unmanaged<InputReportTap>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    tap.input?.inputReport(UnsafeBufferPointer(start: report, count: count),
                                           id: reportID, from: tap, ticks: ticks)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        func unregister() {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.capacity, nil, nil)
        }

        isolated deinit { buffer.deallocate() }
    }

    private static func isButton(_ element: IOHIDElement, page: UInt32, usage: UInt32) -> Bool {
        let type = IOHIDElementGetType(element)
        guard type == kIOHIDElementTypeInput_Button || type == kIOHIDElementTypeInput_ScanCodes ||
                type == kIOHIDElementTypeInput_Misc, usage != 0 else { return false }
        switch page {
        case 0x01: return (0x80...0x8F).contains(usage)
        case 0x07: return usage >= 0x04
        case 0x09, 0x0B, 0x0C: return true
        case 0xFF00...0xFFFF:
            return IOHIDElementGetLogicalMin(element) == 0 && IOHIDElementGetLogicalMax(element) == 1
        default: return false
        }
    }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    private static func seconds(_ ticks: UInt64) -> TimeInterval {
        Double(ticks == 0 ? mach_absolute_time() : ticks) * secondsPerTick
    }

    private static func identify(_ device: IOHIDDevice) -> HIDDevice {
        func property(_ key: String) -> CFTypeRef? {
            IOHIDDeviceGetProperty(device, key as CFString)
        }
        func number(_ key: String) -> Int {
            (property(key) as? NSNumber)?.intValue ?? 0
        }
        func string(_ key: String) -> String {
            property(key) as? String ?? ""
        }

        let product = string(kIOHIDProductKey)
        let vendorID = number(kIOHIDVendorIDKey)
        let productID = number(kIOHIDProductIDKey)
        let locationID = UInt32(exactly: number(kIOHIDLocationIDKey)) ?? 0
        let transport = string(kIOHIDTransportKey)
        let usagePage = number(kIOHIDPrimaryUsagePageKey)
        let usage = number(kIOHIDPrimaryUsageKey)
        let identityFields = [transport, String(vendorID), String(productID), String(usagePage), String(usage),
                              string(kIOHIDManufacturerKey), product, string(kIOHIDSerialNumberKey)]
        let digest = SHA256.hash(data: Data(identityFields.joined(separator: "\u{001F}").utf8))
        let fingerprint = "mac-hid:" + digest.map { String(format: "%02x", $0) }.joined()

        var registryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        let hasRegistryID = service != 0 && IORegistryEntryGetRegistryEntryID(service, &registryID) == kIOReturnSuccess
        let id = hasRegistryID ? "registry:\(registryID)" : "live:\(ObjectIdentifier(device))"
        return HIDDevice(id: id, fingerprint: fingerprint, name: product.isEmpty ? "HID 设备" : product,
                         vendorID: vendorID, productID: productID, locationID: locationID,
                         transport: transport.isEmpty ? "未知" : transport,
                         usagePage: usagePage, usage: usage, isSharedHub: vendorID == 0x1A86 && productID == 0x8022)
    }
}
