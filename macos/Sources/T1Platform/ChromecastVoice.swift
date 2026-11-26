import AppKit
@preconcurrency import CoreBluetooth
import Foundation
import OSLog

/// An opt-in, device-scoped ATVV client. Audio stays in bounded memory and is
/// delivered directly to the recognizer; no virtual microphone is installed.
@MainActor
public final class ChromecastVoice: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public private(set) var status = "Chromecast 语音未连接"
    public private(set) var isReady = false
    public private(set) var isRecording = false
    public private(set) var level: Float = 0
    public private(set) var packetCount = 0
    public var onStateChange: (() -> Void)?
    public var onStart: (() -> Bool)?
    public var onFinish: (([Float], Double) -> Void)?
    public var onCancelled: ((String) -> Void)?
    public var onConnected: ((String) -> Void)?
    public static var bluetoothAllowed: Bool { CBManager.authorization == .allowedAlways }

    private let log = Logger(subsystem: "local.t1controller.app", category: "ChromecastVoice")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var control: CBCharacteristic?
    private var protocolState = ATVVProtocol()
    private var enabled = false
    private var cachedID: UUID?
    private var pnpVerified = false
    private var capabilitiesRequested = false
    private var awaitingRequestedStart = false
    private var streamID: UInt8?
    private var samples: [Float] = []
    private var sampleRate: Double = 16_000
    private var startupTimeout: Task<Void, Never>?
    private var captureWatchdog: Task<Void, Never>?
    private var pendingOpen: Task<Void, Never>?
    private var lastAudioAt: TimeInterval = 0
    private var lastUIAt: TimeInterval = 0
    private var captureStartedAt: TimeInterval = 0
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var terminationObserver: (any NSObjectProtocol)?

    private static let service = CBUUID(string: ATVVProtocol.serviceUUID)
    private static let infoService = CBUUID(string: "180A")
    private static let pnp = CBUUID(string: "2A50")

    public override init() {
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }

    isolated deinit {
        stop()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    public func start(cachedPeripheralID: String = "") {
        enabled = true
        cachedID = UUID(uuidString: cachedPeripheralID)
        if workspaceObservers.isEmpty {
            let notifications = NSWorkspace.shared.notificationCenter
            workspaceObservers = [
                notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.disconnect(reason: "电脑休眠，遥控器语音已关闭") }
                },
                notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.enabled == true { self?.discover() } }
                }
            ]
        }
        if central == nil {
            update("正在检查蓝牙权限与语音通道")
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn { discover() }
        else { update("等待蓝牙开启与 Orvio 蓝牙授权") }
    }

    public func stop() {
        enabled = false
        disconnect(reason: "Chromecast 语音已断开")
    }

    /// Explicit UI cancellation, never a fabricated release/transcription.
    public func cancelCapture() {
        pendingOpen?.cancel(); pendingOpen = nil
        let pending = awaitingRequestedStart
        awaitingRequestedStart = false
        if let id = streamID { closeMicrophone(id) }
        else if pending { closeMicrophone(0) }
        clearCapture()
    }

    public func finishCapture() {
        guard streamID != nil else { return }
        let captured = samples, rate = sampleRate
        if let id = streamID { closeMicrophone(id) }
        clearCapture()
        update("遥控器录音已停止，正在转写")
        onFinish?(captured, rate)
    }

    public func recognitionCompleted(_ message: String) {
        guard !isRecording, isReady else { return }
        update(message + " · 遥控器麦克风已停止")
    }

    private func update(_ text: String) {
        guard status != text else { return }
        status = text
        log.notice("\(text, privacy: .public)")
        onStateChange?()
    }

    private func matches(_ device: CBPeripheral, advertisement: [String: Any] = [:]) -> Bool {
        let name = (device.name ?? advertisement[CBAdvertisementDataLocalNameKey] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.caseInsensitiveCompare("Chromecast Remote") == .orderedSame
    }

    private func discover() {
        guard enabled, central?.state == .poweredOn, peripheral == nil, let central else { return }
        startupTimeout?.cancel()
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.service]).filter { matches($0) }
        if connected.count > 1 { update("检测到多只 Chromecast，请仅保留当前要使用的一只"); return }
        if let device = connected.first { connect(device); return }
        if let cachedID, let device = central.retrievePeripherals(withIdentifiers: [cachedID]).first,
           matches(device) { connect(device); return }
        update("正在寻找 Chromecast 的 ATVV 语音服务；普通按键连接不等于语音已连接")
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.update("未找到 Chromecast ATVV 服务。请唤醒遥控器后点重新连接；本次未开启麦克风")
        }
    }

    private func connect(_ device: CBPeripheral) {
        guard enabled, peripheral == nil else { return }
        central?.stopScan()
        peripheral = device
        device.delegate = self
        update("正在连接 Chromecast 独立语音通道")
        central?.connect(device)
        startupTimeout?.cancel()
        startupTimeout = Task { [weak self, weak device] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.peripheral === device, !self.isReady else { return }
            self.disconnect(reason: "语音通道初始化超时；未完成设备身份、通知订阅或能力协商")
        }
    }

    private func disconnect(reason: String) {
        startupTimeout?.cancel(); startupTimeout = nil
        central?.stopScan()
        let wasRecording = isRecording
        cancelCapture()
        isReady = false
        let previous = peripheral
        peripheral = nil
        previous?.delegate = nil
        if let previous { central?.cancelPeripheralConnection(previous) }
        tx = nil; rx = nil; control = nil
        pnpVerified = false; capabilitiesRequested = false
        protocolState = ATVVProtocol()
        update(reason)
        if wasRecording { onCancelled?(reason) }
    }

    private func send(_ data: Data) {
        guard let peripheral, let tx, peripheral.state == .connected else { return }
        if tx.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else {
                failCapture("蓝牙写入暂不可用，已取消本次语音，请松开后重试")
                return
            }
            peripheral.writeValue(data, for: tx, type: .withoutResponse)
        } else if tx.properties.contains(.write) {
            peripheral.writeValue(data, for: tx, type: .withResponse)
        }
    }

    private func closeMicrophone(_ id: UInt8) {
        if let command = try? protocolState.micCloseCommand(streamID: id) { send(command) }
    }

    private func subscribeWhenVerified() {
        guard pnpVerified, let peripheral, let rx, let control, tx != nil else { return }
        for characteristic in [rx, control] where !characteristic.isNotifying {
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                disconnect(reason: "遥控器语音特征不支持通知，未开启麦克风")
                return
            }
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard enabled else { return }
        switch central.state {
        case .poweredOn: discover()
        case .unauthorized: disconnect(reason: "Orvio 蓝牙未授权，请在隐私与安全中开启蓝牙")
        case .poweredOff: disconnect(reason: "系统蓝牙已关闭，语音通道不可用")
        case .unsupported: disconnect(reason: "当前 Mac 不支持所需蓝牙语音通道")
        default: disconnect(reason: "蓝牙状态已变化，语音通道已关闭，请重新连接")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                              advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard matches(device, advertisement: advertisementData) else { return }
        connect(device)
    }

    public func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard enabled, peripheral === device else { return }
        device.discoverServices([Self.service, Self.infoService])
        update("语音通道已连接，正在核对设备身份和能力")
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard peripheral === device else { return }
        disconnect(reason: "Chromecast 语音连接失败：\(error?.localizedDescription ?? "蓝牙连接未建立")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard peripheral === device else { return }
        disconnect(reason: "Chromecast 语音通道已断开，请点重新连接")
    }

    public func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === device else { return }
        guard error == nil, let services = device.services,
              let voice = services.first(where: { $0.uuid == Self.service }),
              let info = services.first(where: { $0.uuid == Self.infoService }) else {
            disconnect(reason: "未找到完整的 ATVV 与设备身份服务，未开启麦克风"); return
        }
        device.discoverCharacteristics([Self.pnp], for: info)
        device.discoverCharacteristics([CBUUID(string: ATVVProtocol.txUUID), CBUUID(string: ATVVProtocol.rxUUID),
                                       CBUUID(string: ATVVProtocol.controlUUID)], for: voice)
    }

    public func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === device else { return }
        guard error == nil else { disconnect(reason: "读取蓝牙语音特征失败"); return }
        let characteristics = service.characteristics ?? []
        if service.uuid == Self.infoService {
            guard let identity = characteristics.first(where: { $0.uuid == Self.pnp }), identity.properties.contains(.read) else {
                disconnect(reason: "遥控器未提供可读的 PnP 身份，语音连接已暂停"); return
            }
            device.readValue(for: identity)
        } else if service.uuid == Self.service {
            tx = characteristics.first { $0.uuid == CBUUID(string: ATVVProtocol.txUUID) }
            rx = characteristics.first { $0.uuid == CBUUID(string: ATVVProtocol.rxUUID) }
            control = characteristics.first { $0.uuid == CBUUID(string: ATVVProtocol.controlUUID) }
            guard let tx, rx != nil, control != nil,
                  tx.properties.contains(.writeWithoutResponse) || tx.properties.contains(.write) else {
                disconnect(reason: "ATVV 缺少必要的音频或控制特征"); return
            }
        }
        subscribeWhenVerified()
    }

    public func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device else { return }
        guard error == nil, characteristic.isNotifying else {
            disconnect(reason: "蓝牙语音通知订阅失败，未开启麦克风"); return
        }
        if rx?.isNotifying == true, control?.isNotifying == true, !capabilitiesRequested {
            capabilitiesRequested = true
            send(protocolState.getCapabilitiesCommand)
            update("通知订阅成功，正在协商按住说话和音频格式")
        }
    }

    public func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === device, error != nil { disconnect(reason: "ATVV 控制指令写入失败") }
    }

    public func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device else { return }
        guard error == nil, let data = characteristic.value else {
            disconnect(reason: "读取遥控器语音通知失败"); return
        }
        if characteristic.uuid == Self.pnp {
            let bytes = Array(data)
            guard bytes.count == 7, bytes[0] == 2,
                  (UInt16(bytes[1]) | UInt16(bytes[2]) << 8) == 0x18D1,
                  (UInt16(bytes[3]) | UInt16(bytes[4]) << 8) == 0x9450 else {
                disconnect(reason: "蓝牙 PnP 身份与 Chromecast 18D1:9450 不符，已拒绝语音连接"); return
            }
            pnpVerified = true
            subscribeWhenVerified()
        } else if characteristic === control {
            receiveControl(data)
        } else if characteristic === rx {
            receiveAudio(data)
        }
    }

    private func receiveControl(_ data: Data) {
        switch protocolState.parseControl(data) {
        case .capabilities(let capabilities):
            guard capabilitiesRequested, (1...2048).contains(capabilities.frameSize) else {
                disconnect(reason: "遥控器音频能力报文异常，语音连接已暂停"); return
            }
            do { try protocolState.acceptCapabilities(capabilities) }
            catch { disconnect(reason: error.localizedDescription); return }
            startupTimeout?.cancel(); startupTimeout = nil
            isReady = true
            onConnected?(peripheral?.identifier.uuidString ?? "")
            let behavior = capabilities.interactionModel == 3 ? "按住语音键说话，松开停止" : "按语音键开始，再按停止"
            update("语音已就绪 · ATVV \(capabilities.version) · \(protocolState.codec?.sampleRate ?? 0) Hz · \(behavior)")
        case .startSearch:
            guard isReady else { return }
            if isRecording {
                if protocolState.capabilities?.interactionModel != 3,
                   ProcessInfo.processInfo.systemUptime - captureStartedAt >= 0.35 { finishCapture() }
                return
            }
            update("已收到语音键 · 等待遥控器启动音频")
            pendingOpen?.cancel()
            pendingOpen = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, self.isReady, self.streamID == nil,
                      let command = try? self.protocolState.micOpenCommand() else { return }
                self.awaitingRequestedStart = true
                self.send(command)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.awaitingRequestedStart, !self.isRecording else { return }
                self.awaitingRequestedStart = false
                self.closeMicrophone(0)
                self.update("遥控器未确认开麦，已发送关闭指令，请松开后重试")
            }
        case .audioStart(let reason, let codec, let id):
            guard isReady else { return }
            guard reason == 1 || reason == 3 || (reason == 0 && awaitingRequestedStart) else {
                closeMicrophone(id)
                update("已忽略非本次语音键请求启动的音频流")
                return
            }
            pendingOpen?.cancel(); pendingOpen = nil
            awaitingRequestedStart = false
            if isRecording { failCapture("收到新的语音流，旧录音已取消，请松开后重试"); return }
            streamID = id
            sampleRate = Double(codec.sampleRate)
            protocolState.resetAudio()
            guard onStart?() == true else {
                closeMicrophone(id); clearCapture(); update("当前语音任务未就绪，遥控器麦克风已关闭"); return
            }
            isRecording = true
            samples.removeAll(keepingCapacity: true)
            packetCount = 0
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            lastAudioAt = captureStartedAt
            update("语音键已按下 · 等待收音就绪，请见到电平后说话")
            captureWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self, self.isRecording else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.captureStartedAt >= 15 { self.failCapture("录音已达 15 秒，麦克风已关闭，本次未执行指令"); return }
                    let gapLimit: TimeInterval = self.packetCount == 0 ? 4 : 2
                    if now - self.lastAudioAt >= gapLimit { self.failCapture("没有收到遥控器音频，麦克风已关闭，请松开后重试"); return }
                }
            }
        case .audioSync(let codec, let sequence, let predictor, let stepIndex):
            guard isRecording else { return }
            guard Double(codec.sampleRate) == sampleRate else {
                failCapture("遥控器录音中改变采样率，本次已取消，避免错误转写"); return
            }
            protocolState.applyAudioSync(codec: codec, sequence: sequence, predictor: predictor, stepIndex: stepIndex)
        case .audioStop(let reason):
            pendingOpen?.cancel(); pendingOpen = nil
            guard isRecording else { return }
            guard reason == 0 || reason == 2 else {
                failCapture("遥控器异常停流（\(reason)），本次录音已取消"); return
            }
            let captured = samples, rate = sampleRate, packets = packetCount
            clearCapture()
            guard !captured.isEmpty else {
                update("已收到松开，但本次没有音频；请按住等收音就绪后再说话")
                onCancelled?(status)
                return
            }
            update("已收到语音松开／停流 · \(packets) 包 · \(String(format: "%.2f", Double(captured.count) / rate)) 秒，正在转写")
            onFinish?(captured, rate)
        case .micOpenError(let code): failCapture(String(format: "遥控器拒绝开麦（0x%04X），请松开后重试", code))
        case .unknown:
            if data.first == 0x0B { disconnect(reason: "遥控器返回了不支持的 ATVV 版本或能力格式") }
        }
    }

    private func receiveAudio(_ data: Data) {
        guard isRecording, data.count <= 4096 else { return }
        guard let decoded = protocolState.decodeAudio(data), !decoded.samples.isEmpty else {
            failCapture("收到无法解码的遥控器音频，本次录音已取消"); return
        }
        guard Double(samples.count + decoded.samples.count) / sampleRate < 15 else {
            failCapture("录音已达 15 秒，麦克风已关闭，本次未执行指令"); return
        }
        let floats = decoded.samples.map { Float($0) / 32768 }
        samples.append(contentsOf: floats)
        packetCount += 1
        lastAudioAt = ProcessInfo.processInfo.systemUptime
        level = floats.reduce(Float(0)) { max($0, abs($1)) }
        if packetCount == 1 { update("收音已就绪 · 正在接收遥控器音频，松开语音键结束") }
        if lastAudioAt - lastUIAt >= 0.1 { lastUIAt = lastAudioAt; onStateChange?() }
    }

    private func clearCapture() {
        captureWatchdog?.cancel(); captureWatchdog = nil
        streamID = nil; isRecording = false; level = 0
        samples.removeAll(keepingCapacity: true)
        onStateChange?()
    }

    private func failCapture(_ reason: String) {
        // Clear before writing MIC_CLOSE so backpressure cannot recursively
        // cancel the same stream through send().
        let id = streamID
        clearCapture()
        if let id { closeMicrophone(id) }
        update(reason)
        onCancelled?(reason)
    }
}
