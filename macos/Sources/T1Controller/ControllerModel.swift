import AppKit
import ApplicationServices
import Combine
import Foundation
import OSLog
import T1Core
import T1Platform
import UniformTypeIdentifiers

private let voiceKeyLog = Logger(subsystem: "local.t1controller.app", category: "VoiceKey")

enum RemoteProfile: String, CaseIterable, Identifiable {
    case t1 = "T1 飞鼠"
    case xiaomi = "小米蓝牙遥控器"
    case chromecast = "Chromecast"

    var id: Self { self }
}

@MainActor
final class ControllerModel: ObservableObject {
    static let directT1Selection = "t1-direct-receiver"

    @Published var prefs = Preferences() {
        didSet {
            guard prefs != oldValue else { return }
            if prefs.playerID != oldValue.playerID {
                playerSelectionRevision &+= 1
                musicAgentTask?.cancel()
            }
            let bindingsChanged = prefs.bindings != oldValue.bindings || prefs.xiaomiBindings != oldValue.xiaomiBindings ||
                prefs.chromecastBindings != oldValue.chromecastBindings
            if prefs.chromecastCompatibility != oldValue.chromecastCompatibility {
                hid.chromecastCompatibilityEnabled = prefs.chromecastCompatibility
                refreshNativeIsolation()
            }
            if prefs.chromecastVoiceEnabled != oldValue.chromecastVoiceEnabled {
                if prefs.chromecastVoiceEnabled { chromecastVoice.start(cachedPeripheralID: prefs.chromecastPeripheralID) }
                else { chromecastVoice.stop() }
            }
            if prefs.mappingsEnabled != oldValue.mappingsEnabled || prefs.mediaMode != oldValue.mediaMode ||
                prefs.remoteMode != oldValue.remoteMode || bindingsChanged {
                resetInput()
            }
            if prefs.remoteMode != oldValue.remoteMode { cancelVoice() }
            if bindingsChanged || (prefs.remoteMode == nil && prefs.mappingsEnabled != oldValue.mappingsEnabled) ||
                (prefs.remoteMode == nil) != (oldValue.remoteMode == nil) {
                updateMonitoredDevices()
            }
            if bindingsChanged || prefs.remoteMode != oldValue.remoteMode { refreshNativeIsolation() }
            if prefs.voiceHotkeyEnabled != oldValue.voiceHotkeyEnabled { updateVoiceHotkey() }
            if prefs.microphoneUID != oldValue.microphoneUID { cancelVoice() }
            if prefs.actionHotkeysEnabled != oldValue.actionHotkeysEnabled || prefs.modeHotkeysEnabled != oldValue.modeHotkeysEnabled { updateActionHotkeys() }
            if prefs.kmfuVerified != oldValue.kmfuVerified ||
                prefs.kmfuKey != oldValue.kmfuKey ||
                prefs.kmfuCommand != oldValue.kmfuCommand ||
                prefs.kmfuOption != oldValue.kmfuOption ||
                prefs.kmfuControl != oldValue.kmfuControl ||
                prefs.kmfuShift != oldValue.kmfuShift ||
                prefs.routeReceiver != oldValue.routeReceiver ||
                prefs.routeSpeakerUID != oldValue.routeSpeakerUID ||
                prefs.routeSensorsVerified != oldValue.routeSensorsVerified {
                manualHubOwner = nil
            }
            if prefs.monitorUUID != oldValue.monitorUUID || prefs.macInput != oldValue.macInput ||
                prefs.windowsInput != oldValue.windowsInput {
                visibleHost = nil
            }
            save()
        }
    }
    @Published private(set) var notice = Outcome(.confirmed, "选择功能，或先学习飞鼠按键")
    @Published private(set) var devices: [HIDDevice] = []
    @Published private(set) var permission: HIDPermission = .unknown
    @Published private(set) var nativeIsolationStatus = ""
    @Published private(set) var nativeSoftwareMuted = false
    @Published private(set) var mutedPlayers: Set<String> = []
    @Published private(set) var audioInputs: [AudioInputInfo] = []
    @Published private(set) var microphoneAllowed = PushToTalk.microphoneAllowed
    @Published private(set) var audioOutput: AudioOutputInfo?
    @Published private(set) var displays: [ConnectedDisplay] = []
    @Published private(set) var inputLog: [String] = []
    @Published private(set) var vendorReportSummary: String?
    @Published private(set) var learningRole: KeyRole?
    private var lastModeRelease: TimeInterval?
    @Published private(set) var activeKeyRole: KeyRole?
    @Published private(set) var activeXiaomiKeyRole: KeyRole?
    @Published private(set) var activeChromecastKeyRole: KeyRole?
    @Published private(set) var activeChromecastControl: String?
    @Published private(set) var chromecastCompatibilityStatus = "短报文兼容未开启"
    @Published private(set) var lastChromecastControl = ""
    @Published private(set) var chromecastVoiceStatus = "Chromecast 语音未连接 · 需连接独立蓝牙语音通道"
    @Published private(set) var chromecastVoiceReady = false
    @Published private(set) var chromecastVoiceRecording = false
    @Published private(set) var chromecastVoicePackets = 0
    @Published var mappingProfile: RemoteProfile = .t1 {
        didSet {
            guard mappingProfile != oldValue else { return }
            selectedDevice = isProbing ? preferredDiagnosticDevice : ""
        }
    }
    @Published var selectedDevice = "" {
        didSet {
            guard selectedDevice != oldValue else { return }
            inputLog.removeAll()
            probePressTimes.removeAll()
            cancelLearning()
            vendorReportSummary = nil
            vendorReportCount = 0
            lastVendorReportUpdate = nil
            updateDiagnosticDevices()
        }
    }
    @Published private(set) var isProbing = false
    @Published private(set) var isRecording = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastVoiceDelivery = ""
    @Published private(set) var isRunningMusicAgent = false
    @Published private(set) var isRunningXiaoAI = false
    @Published private(set) var xiaoAIStatus = ""
    @Published private(set) var musicScreenCaptureAvailable = MusicDesktopAgent.screenCaptureAvailable()
    @Published private(set) var musicModelAvailability = MusicAgentPlanner.availability()
    @Published private var manualHubOwner: HostID?
    @Published private(set) var visibleHost: HostID?
    @Published private(set) var isSwitching = false
    @Published private(set) var settingsError: String?

    private let hid = HIDInput()
    private let nativeIsolation = NativeKeyIsolation()
    private let nativeAudio = NativeAudioMute()
    private var nativeGestures: [String: GestureEngine] = [:]
    private var nativeIsolationPending = false
    private var lastIsolationRequest: [HIDDevice: Set<HIDKey>] = [:]
    private var isolationRefreshJob: Task<Void, Never>?
    private let players = PlayerController()
    private let musicAgent = MusicDesktopAgent()
    private let xiaoAI = XiaoAIBridge()
    private let display = BetterDisplayInput()
    private let hub = KMFURoute()
    private let voice = PushToTalk()
    private let voiceHotkey = VoiceHotkey()
    private let actionHotkeys = ActionHotkeys()
    private let switcher = SwitchCoordinator()
    private let chromecastVoice = ChromecastVoice()
    private var gestures: [RemoteProfile: GestureEngine] = [:]
    private var candidate: HIDEvent?
    private var chromecastBasePresses: [HIDControl: (ChromecastBaseAction, pid_t, TimeInterval)] = [:]
    private var chromecastLastRelease: [HIDControl: TimeInterval] = [:]
    private var probePressTimes: [String: [HIDControl: TimeInterval]] = [:]
    private var vendorReportCount = 0
    private var lastVendorReportUpdate: TimeInterval?
    private var voiceOrigin: VoiceOrigin?
    private var voiceJob: Task<Void, Never>?
    private var voiceSilenceJob: Task<Void, Never>?
    private var t1PulseReleaseAt: TimeInterval?
    private var voiceSession: UUID?
    private var voiceDestination = VoiceDestination.command
    private var voiceTextTarget: NativeTextInput?
    private var textFocusObservation: NativeTextFocusObservation?
    private var audioObservation: AudioOutputObservation?
    private var storedPreferencesReadable = true
    private var playerActionInProgress = false
    private var playerSelectionRevision: UInt64 = 0
    private var musicAgentTask: Task<PlatformResult, Never>?

    private enum VoiceOrigin: Equatable { case panel, keyboard, remote(String), chromecast }

    init() {
        do {
            prefs = try Preferences.load()
        } catch {
            storedPreferencesReadable = false
            settingsError = "设置文件读取失败。可以在按键页恢复设置。"
        }
        hid.onInput = { [weak self] in self?.receive($0) }
        hid.onCompatibilityStateChange = { [weak self] in
            guard let self else { return }
            self.chromecastCompatibilityStatus = self.hid.chromecastCompatibilityStatus
        }
        hid.onCompatibilityRoutingChange = { [weak self] in self?.scheduleIsolationRefresh() }
        hid.onStateChange = { [weak self] in self?.refreshDevices() }
        chromecastVoice.onStateChange = { [weak self] in
            guard let self else { return }
            if self.chromecastVoicePackets == 0, self.chromecastVoice.packetCount > 0,
               self.voiceDestination == .focusedText {
                RemoteModeHUD.shared.showVoice(title: "可以说话", detail: "原生转文字 · 松开语音键结束")
            }
            self.chromecastVoiceStatus = self.chromecastVoice.status
            self.chromecastVoiceReady = self.chromecastVoice.isReady
            self.chromecastVoiceRecording = self.chromecastVoice.isRecording
            self.chromecastVoicePackets = self.chromecastVoice.packetCount
        }
        chromecastVoice.onStart = { [weak self] in self?.beginChromecastVoice() ?? false }
        chromecastVoice.onFinish = { [weak self] samples, rate in self?.finishChromecastVoice(samples, sampleRate: rate) }
        chromecastVoice.onCancelled = { [weak self] reason in
            guard let self, self.voiceOrigin == .chromecast else { return }
            self.cancelVoice()
            self.notice = Outcome(.unavailable, reason)
        }
        chromecastVoice.onConnected = { [weak self] id in self?.prefs.chromecastPeripheralID = id }
        hid.onInputReset = { [weak self] device in
            guard let self else { return }
            if self.candidate?.device.id == device.id { self.candidate = nil }
            self.probePressTimes.removeValue(forKey: device.id)
            for profile in RemoteProfile.allCases where self.uses(device, in: profile) {
                self.resetInput(in: profile)
            }
            if self.nativeIsolationPending { self.scheduleIsolationRefresh() }
        }
        hid.onDeviceRemoved = { [weak self] device in
            guard let self else { return }
            if self.voiceOrigin == .remote(device.fingerprint) { self.resetInput() }
            if device.isSharedHub || self.uses(device, in: .t1) {
                self.manualHubOwner = nil
            }
        }
        audioOutput = SystemOutput.info()
        nativeAudio.onChange = { [weak self] in self?.nativeSoftwareMuted = $0 }
        nativeAudio.onPlayerChange = { [weak self] id, muted in
            guard let self else { return }
            if muted { self.mutedPlayers.insert(id) } else { self.mutedPlayers.remove(id) }
        }
        updateMonitoredDevices()
        hid.chromecastCompatibilityEnabled = prefs.chromecastCompatibility
        hid.start()
        if prefs.chromecastVoiceEnabled { chromecastVoice.start(cachedPeripheralID: prefs.chromecastPeripheralID) }
        refreshDevices()
        refreshAudioInputs()
        audioObservation = SystemOutput.observeDefaultOutput { [weak self] output in
            Task { @MainActor [weak self] in
                self?.audioOutput = output
                self?.nativeAudio.outputChanged(to: output?.uid)
                self?.updateOwnership()
            }
        }
        voice.onCancellation = { [weak self] result in
            guard let self, self.voiceSession != nil else { return }
            self.cancelVoice()
            self.notice = self.outcome(result)
        }
        updateVoiceHotkey()
        updateActionHotkeys()
        textFocusObservation = NativeTextFocusObservation { [weak self] in self?.prefs.remoteMode == .native }
        if prefs.remoteMode == .native { NativeTextInput.prepareForeground() }
    }

    var recordingLevel: Float { voiceOrigin == .chromecast ? chromecastVoice.level : voice.level }
    var currentPlayerName: String {
        prefs.players.first(where: { $0.id == prefs.playerID })?.name ?? "未选择"
    }
    var microphoneName: String {
        if voiceOrigin == .chromecast { return "Chromecast 遥控器麦克风（蓝牙）" }
        if let live = voice.inputName { return live }
        if let input = audioInputs.first(where: { $0.uid == prefs.microphoneUID }) {
            return input.name
        }
        if !prefs.microphoneUID.isEmpty { return "所选麦克风未连接" }
        return audioInputs.first(where: \.isDefault)?.name ?? "系统默认输入"
    }
    var deviceSummary: String {
        let learned = Set(prefs.bindings.values.map(\.device))
        let live = devices.filter { learned.contains($0.fingerprint) }
        if let item = live.first { return "\(item.name) · \(item.transport)" }
        return learned.isEmpty ? "等待学习" : "飞鼠未连接"
    }
    var hubOwner: HostID? {
        if prefs.routeAwaitingDeparture { return nil }
        if localPeripheralsPresent { return .mac }
        return manualHubOwner
    }

    var toggleWithPeripherals: Bool {
        get { prefs.toggleWithPeripherals ?? prefs.kmfuVerified }
        set { prefs.toggleWithPeripherals = newValue }
    }

    private var localPeripheralsPresent: Bool {
        prefs.routeSensorsVerified && routeReceiverCount == 1 && routeSpeakerPresent
    }

    private var routeReceiverCount: Int {
        guard !prefs.routeReceiver.isEmpty else { return 0 }
        return devices.filter { $0.fingerprint == prefs.routeReceiver && !$0.isSharedHub }.count
    }

    private var routeSpeakerPresent: Bool {
        !prefs.routeSpeakerUID.isEmpty && audioOutput?.uid == prefs.routeSpeakerUID
    }

    func requestInputPermission() {
        hid.start(requestPermission: true)
        refreshPermission()
        guard permission != .granted else { return }

        notice = Outcome(.unavailable, "请在「系统设置 → 隐私与安全 → 输入监控」允许当前的 Orvio 应用")
        openPrivacySettings("Privacy_ListenEvent")
    }

    func openPrivacySettings(_ anchor: String) {
        let settings = NSWorkspace.shared
        for pane in ["com.apple.settings.PrivacySecurity.extension", "com.apple.preference.security"] {
            if let url = URL(string: "x-apple.systempreferences:\(pane)?\(anchor)"), settings.open(url) {
                return
            }
        }
        if let settingsApp = settings.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            settings.open(settingsApp)
        }
    }

    func requestMusicScreenCapture() {
        let permitted = MusicDesktopAgent.requestScreenCapture()
        refreshMusicAgentStatus()
        if permitted || musicScreenCaptureAvailable {
            notice = Outcome(.confirmed, "录屏权限已开启")
        } else {
            notice = Outcome(.unavailable, "请在「系统设置 → 隐私与安全 → 录屏与系统录音」允许 Orvio，按系统提示重开应用")
            openPrivacySettings("Privacy_ScreenCapture")
        }
    }

    func refreshMusicAgentStatus() {
        musicScreenCaptureAvailable = MusicDesktopAgent.screenCaptureAvailable()
        musicModelAvailability = MusicAgentPlanner.availability()
    }

    func requestAutomationPermission() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            notice = Outcome(.confirmed, "辅助功能权限已开启")
        } else {
            notice = Outcome(.unavailable, "请在「系统设置 → 隐私与安全性 → 辅助功能」允许当前版本的 Orvio")
            openPrivacySettings("Privacy_Accessibility")
        }
    }

    func refreshDevices() {
        devices = hid.devices
        permission = hid.permission
        updateMonitoredDevices()
        refreshNativeIsolation()
        updateOwnership()
        if selectedDevice == Self.directT1Selection {
            if directT1Devices.isEmpty { selectedDevice = "" }
        } else if !selectedDevice.isEmpty && !diagnosticDevices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = ""
        }
        if isProbing && selectedDevice.isEmpty { selectedDevice = preferredDiagnosticDevice }
        updateDiagnosticDevices()
    }

    var directT1Devices: Set<String> { HIDDevice.directT1LearningGroup(in: devices) }

    var xiaomiDevices: [HIDDevice] { devices.filter(\.isXiaomiBluetoothRemote) }
    var chromecastDevices: [HIDDevice] { devices.filter(\.isChromecastRemote) }

    var diagnosticDevices: [HIDDevice] {
        switch mappingProfile {
        case .xiaomi: xiaomiDevices
        case .chromecast: chromecastDevices
        case .t1: devices.filter { !$0.isXiaomiBluetoothRemote && !$0.isChromecastRemote }
        }
    }

    private var preferredDiagnosticDevice: String {
        if mappingProfile == .t1 { return directT1Devices.isEmpty ? "" : Self.directT1Selection }
        let candidates = mappingProfile == .chromecast ? chromecastDevices : xiaomiDevices
        return candidates.count == 1 ? candidates[0].id : ""
    }

    var canLearnKey: Bool {
        permission == .granted && ((isProbing && !selectedDevice.isEmpty) || !preferredDiagnosticDevice.isEmpty)
    }

    private func updateDiagnosticDevices() {
        let ids: Set<String>
        if !isProbing || selectedDevice.isEmpty { ids = [] }
        else if selectedDevice == Self.directT1Selection { ids = directT1Devices }
        else { ids = [selectedDevice] }
        if ids != hid.diagnosticDeviceIDs {
            candidate = nil
            hid.diagnosticDeviceIDs = ids
        }
    }

    func refreshPermission() {
        let previouslyGranted = permission == .granted
        hid.refreshPermission()
        refreshDevices()
        if !previouslyGranted, permission == .granted {
            notice = Outcome(.confirmed, "输入监控可用")
        }
    }

    func refreshAudioInputs() {
        audioInputs = PushToTalk.inputDevices()
        microphoneAllowed = PushToTalk.microphoneAllowed
    }
    func refreshDisplays() { displays = BetterDisplayInput.connectedDisplays() }

    func requestMicrophonePermission() {
        Task {
            let permitted = await PushToTalk.requestPermission()
            refreshAudioInputs()
            notice = permitted
                ? Outcome(.confirmed, "麦克风权限已开启")
                : Outcome(.unavailable, "请在「系统设置 → 隐私与安全性 → 麦克风」允许 Orvio")
        }
    }

    func beginProbe() {
        isProbing = true
        hid.onDiagnosticReport = { [weak self] observation in
            self?.showDiagnosticReport(observation)
        }
        hid.refreshPermission()
        refreshDevices()
    }

    func endProbe() {
        isProbing = false
        hid.onDiagnosticReport = nil
        cancelLearning()
        selectedDevice = ""
    }

    private func showDiagnosticReport(_ observation: HIDReportObservation) {
        guard isProbing, hid.diagnosticDeviceIDs.contains(observation.device.id) else { return }
        vendorReportCount += 1
        if let previous = lastVendorReportUpdate, observation.timestamp - previous < 0.2 { return }
        lastVendorReportUpdate = observation.timestamp
        let state = observation.changed.map { $0 ? "有变化" : "重复" } ?? "首次"
        vendorReportSummary = "厂商报表 0x\(String(observation.reportID, radix: 16)) · \(observation.byteCount) 字节 · \(vendorReportCount) 次 · \(state)"
    }

    func learn(_ role: KeyRole) -> Bool {
        if mappingProfile == .chromecast, role == .voice {
            connectChromecastVoice()
            notice = Outcome(.submitted, "Chromecast 语音键通过独立 ATVV 通道接入，无需 HID 学习。请查看语音连接状态。")
            return false
        }
        guard permission == .granted else {
            notice = Outcome(.unavailable, "先在系统设置开启当前版本的输入监控")
            return false
        }
        if !isProbing { beginProbe() }
        guard !hid.diagnosticDeviceIDs.isEmpty else {
            notice = Outcome(.unavailable, "先选择要学习的 HID 设备")
            return false
        }
        resetInput()
        learningRole = role
        candidate = nil
        notice = Outcome(.submitted, "请按下并松开飞鼠上的目标按键")
        return true
    }

    func cancelLearning() {
        if learningRole != nil { notice = Outcome(.unavailable, "已退出按键学习") }
        learningRole = nil
        candidate = nil
    }

    private func bindings(for profile: RemoteProfile) -> [String: KeyBinding] {
        switch profile {
        case .t1: prefs.bindings
        case .xiaomi: prefs.xiaomiBindings
        case .chromecast: prefs.chromecastBindings
        }
    }

    private func uses(_ device: HIDDevice, in profile: RemoteProfile) -> Bool {
        bindings(for: profile).values.contains { $0.device == device.fingerprint }
    }

    var editedBindings: [String: KeyBinding] {
        get { bindings(for: mappingProfile) }
        set {
            switch mappingProfile {
            case .t1: prefs.bindings = newValue
            case .xiaomi: prefs.xiaomiBindings = newValue
            case .chromecast: prefs.chromecastBindings = newValue
            }
        }
    }

    var remoteModeTitle: String { prefs.remoteMode?.title ?? "现有映射" }

    func allowsRemoteRole(_ role: KeyRole) -> Bool {
        RemoteMode.allows(role, mode: prefs.remoteMode, legacyEnabled: prefs.mappingsEnabled)
    }

    func needsNativeIsolation(_ binding: KeyBinding) -> Bool {
        guard prefs.remoteMode?.isolatesMappedKeys == true else { return false }
        if let key = HIDKey(controlID: binding.control), let device = isolationDevice(for: binding),
           hid.usesChromecastCompatibility(device, key: key) { return false }
        guard !nativeIsolationPending, let key = HIDKey(controlID: binding.control),
              let device = isolationDevice(for: binding) else { return true }
        return !nativeIsolation.isIsolated(device, key: key)
    }

    func nativeBindingStatus(_ binding: KeyBinding) -> String {
        if isolationDevice(for: binding) == nil { return "设备未连接或无法独立识别" }
        if let key = HIDKey(controlID: binding.control), let device = isolationDevice(for: binding),
           hid.usesChromecastCompatibility(device, key: key) { return "短报文兼容 · 不产生系统原生按键" }
        return needsNativeIsolation(binding) ? "原生未隔离 · 映射暂停" : "原生已隔离"
    }

    private func isolationDevice(for binding: KeyBinding) -> HIDDevice? {
        let matches = devices.filter { $0.fingerprint == binding.device }
        guard matches.count == 1, let device = matches.first,
              device.isDirectT1Receiver || device.isXiaomiBluetoothRemote || device.isChromecastRemote else { return nil }
        return device
    }

    private func refreshNativeIsolation(retry: Int = 0) {
        isolationRefreshJob?.cancel()
        isolationRefreshJob = nil
        let activeBindings = [prefs.bindings, prefs.xiaomiBindings, prefs.chromecastBindings].flatMap { profile in
            profile.compactMap { key, binding -> KeyBinding? in
                guard binding.enabled, let role = KeyRole(rawValue: key), allowsRemoteRole(role) else { return nil }
                return binding
            }
        }
        var requested: [HIDDevice: Set<HIDKey>] = [:]
        if permission == .granted, prefs.remoteMode?.isolatesMappedKeys == true {
            for binding in activeBindings {
                guard let key = HIDKey(controlID: binding.control), key.supportsNativeIsolation,
                      let device = isolationDevice(for: binding),
                      !hid.usesChromecastCompatibility(device, key: key) else { continue }
                requested[device, default: []].insert(key)
            }
        }
        if hid.isHoldingRemoteKey {
            if requested != lastIsolationRequest {
                nativeIsolationPending = true
                nativeIsolationStatus = "松开遥控器按键后应用新的功能组合。"
            }
            return
        }
        nativeIsolationPending = false
        lastIsolationRequest = requested
        nativeIsolation.refresh(requested)
        if !nativeIsolation.canManage {
            nativeIsolationStatus = "无法接管按键隔离，请退出其他 T1 实例后重开。"
        } else if nativeIsolation.restoreFailed {
            nativeIsolationStatus = "macOS 未确认原生按键已恢复。请重新接入遥控器。"
        } else if prefs.remoteMode == .native {
            nativeIsolationStatus = "T1／小米原生按键直通系统，语音使用系统听写；Chromecast 使用兼容输入。"
        } else if prefs.remoteMode == nil {
            nativeIsolationStatus = "现有映射沿用系统按键行为。"
        } else if activeBindings.isEmpty {
            nativeIsolationStatus = "本组合尚无已启用的按键绑定。"
        } else {
            let connected = activeBindings.filter { isolationDevice(for: $0) != nil }
            let isolated = connected.filter { !needsNativeIsolation($0) }.count
            let pending = connected.count - isolated
            nativeIsolationStatus = "已隔离 \(isolated) 个按键。"
            if pending > 0 { nativeIsolationStatus += "\(pending) 个按键隔离未生效，映射已暂停。" }
            let absent = activeBindings.count - connected.count
            if absent > 0 { nativeIsolationStatus += "\(absent) 个绑定等待设备连接或独立识别。" }
        }
        // IOHIDManager can announce a reconnected device before its event service
        // is ready. Retry discovery after that race instead of leaving mappings
        // paused until the next mode change or application restart.
        let delays = [100, 250, 500, 1_000, 2_000]
        let incomplete = nativeIsolation.restoreFailed || requested.contains { device, keys in
            keys.contains { !nativeIsolation.isIsolated(device, key: $0) }
        }
        if permission == .granted, nativeIsolation.canManage, incomplete, retry < delays.count {
            isolationRefreshJob = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(delays[retry])) } catch { return }
                self?.refreshNativeIsolation(retry: retry + 1)
            }
        }
    }

    private func scheduleIsolationRefresh() {
        isolationRefreshJob?.cancel()
        isolationRefreshJob = Task { @MainActor [weak self] in
            // Let the system finish the old key-up before changing its mapping.
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            self?.refreshNativeIsolation()
        }
    }

    func selectRemoteMode(_ mode: RemoteMode) {
        guard prefs.remoteMode != mode else { return }
        prefs.remoteMode = mode
        notice = Outcome(.confirmed, "遥控器已切到「\(mode.title)」模式")
        RemoteModeHUD.shared.show(mode, player: currentPlayerName)
    }

    func restoreBindings() {
        if !storedPreferencesReadable {
            storedPreferencesReadable = true
            prefs = Preferences(remoteMode: .native)
            save()
        } else {
            editedBindings = [:]
            if mappingProfile == .t1 { prefs.mediaMode = false }
            if mappingProfile == .chromecast { prefs.chromecastBaseActions = [:] }
        }
        resetInput()
        notice = Outcome(.confirmed, "已恢复按键设置")
    }

    func installChromecastPreset() {
        guard chromecastDevices.count == 1, let device = chromecastDevices.first else {
            notice = Outcome(.unavailable, "请只连接一只 Chromecast Remote 后应用预设")
            return
        }
        let usages: [(KeyRole, UInt32)] = [(.cycleMode, 0x223), (.home, 0x41), (.left, 0x44), (.right, 0x45),
            (.volumeUp, 0xE9), (.volumeDown, 0xEA), (.mute, 0xE2), (.switchHost, 0x224)]
        prefs.chromecastBindings = Dictionary(uniqueKeysWithValues: usages.map { role, usage in
            (role.rawValue, KeyBinding(device: device.fingerprint,
                control: String(format: "hid:000C:%04X:02", usage), enabled: true))
        })
        selectRemoteMode(.media)
        notice = Outcome(.confirmed, "Chromecast 媒体预设已应用：OK 播放暂停、左右切歌、主页切组合；主机模式用返回切主机。")
    }

    private func processChromecastBase(_ event: HIDEvent) {
        // A key reserved by a mapped preset must not regain Return (or another
        // native action) just because its role is inactive in the current mode.
        if prefs.remoteMode != .native, prefs.chromecastBindings.values.contains(where: {
            $0.enabled && $0.device == event.device.fingerprint && $0.control == event.control.id
        }) { return }
        switch event.phase {
        case .down:
            guard chromecastBasePresses[event.control] == nil,
                  let button = ChromecastButton.all.first(where: { $0.id == event.control.id }) else { return }
            let action = prefs.chromecastBaseActions[button.id] ?? button.defaultAction
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            chromecastBasePresses[event.control] = (action, pid, event.timestamp)
        case .repeatPress: break
        case .up:
            guard let (action, pid, start) = chromecastBasePresses.removeValue(forKey: event.control),
                  (0...10).contains(event.timestamp - start),
                  chromecastLastRelease[event.control].map({ start - $0 >= 0.075 }) ?? true else { return }
            chromecastLastRelease[event.control] = event.timestamp
            if let media = action.action {
                if prefs.remoteMode == .native { handleNativeChromecastMedia(media) }
                else { submit(media) }
                return
            }
            guard let key = action.keyCode else { return }
            guard AXIsProcessTrusted() else {
                notice = Outcome(.unavailable, "方向键与回车修复需要 Orvio 的辅助功能权限")
                return
            }
            // Keep a press attached to its original foreground app. A focus
            // change while the remote is held must not click the new window.
            guard pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
            down.flags = []; up.flags = []
            down.postToPid(pid); up.postToPid(pid)
        }
    }

    func addPlayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "添加"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if !self.prefs.players.contains(where: { $0.id == id }) {
                self.prefs.players.append(SavedPlayer(id: id, name: name))
            }
            self.prefs.playerID = id
        }
    }

    func removePlayer(_ id: String) {
        prefs.players.removeAll(where: { $0.id == id })
        if prefs.playerID == id { prefs.playerID = prefs.players.first?.id ?? "" }
    }

    func selectPlayer(_ id: String) {
        guard prefs.players.contains(where: { $0.id == id }) else { return }
        prefs.playerID = id
        notice = Outcome(.confirmed, "音乐控制目标已切换到\(currentPlayerName)")
    }

    func submit(_ action: ControllerAction) {
        let selected = prefs.playerID
        let revision = playerSelectionRevision
        Task {
            guard selected == prefs.playerID, revision == playerSelectionRevision else { return }
            await dispatch(action)
        }
    }

    func submitText(_ text: String) {
        Task {
            guard let action = await commandAction(text) else {
                notice = Outcome(.unavailable, "没有识别到明确指令「\(text)」")
                return
            }
            await dispatchSpeechAction(action, transcript: text)
        }
    }

    func saveXiaoAICredentials(uid: String, token: String) -> Bool {
        let uid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, !token.isEmpty else {
            xiaoAIStatus = "请同时填写巴法 UID 和 Home Assistant 令牌。"
            return false
        }
        do {
            try XiaoAIKeychain.save(.init(bemfaUID: uid, homeAssistantToken: token))
            xiaoAIStatus = "凭据已存入 macOS 钥匙串。"
            return true
        } catch {
            xiaoAIStatus = "未能保存凭据。请确认 macOS 钥匙串已解锁。"
            return false
        }
    }

    func clearXiaoAICredentials() {
        do {
            try XiaoAIKeychain.clear()
            xiaoAIStatus = "已清除钥匙串中的小爱链路凭据。"
        } catch {
            xiaoAIStatus = "未能清除凭据。请确认 macOS 钥匙串已解锁。"
        }
    }

    func testXiaoAIDaily() { Task { _ = await runXiaoAIDaily() } }

    private func dispatchSpeechAction(_ action: ControllerAction, transcript: String) async {
        if action == .playDailyRecommendations && prefs.xiaoAI.enabled && IntentParser.addressesXiaoAI(transcript) {
            let settings = prefs.xiaoAI
            if await runXiaoAIDaily() || prefs.xiaoAI != settings { return }
        }
        await dispatch(action)
    }

    private func runXiaoAIDaily() async -> Bool {
        guard prefs.playerID == PlayerProfile.netease.bundleID else {
            notice = Outcome(.unavailable, "当前选择\(currentPlayerName)，每日推荐需要先选择网易云音乐。")
            return true
        }
        let selection = playerSelectionRevision
        let settings = prefs.xiaoAI
        guard settings.enabled, !isRunningXiaoAI else { return false }
        guard !playerActionInProgress else {
            notice = Outcome(.unavailable, "播放器正在执行另一项操作，请稍后再试。")
            return false
        }
        func report(_ status: OutcomeState, _ message: String) {
            xiaoAIStatus = message
            notice = Outcome(status, message)
        }
        let credentials: XiaoAIBridge.Credentials
        do {
            guard let saved = try XiaoAIKeychain.load() else {
                report(.unavailable, "请在语音页保存巴法 UID 和 Home Assistant 令牌。")
                return false
            }
            credentials = saved
        } catch {
            report(.failed, "未能读取钥匙串中的小爱链路凭据。")
            return false
        }

        isRunningXiaoAI = true
        playerActionInProgress = true
        defer {
            isRunningXiaoAI = false
            playerActionInProgress = false
        }
        report(.submitted, "正在连接巴法并调用小爱音箱，等待开关信号。")
        let result = await xiaoAI.requestDailyPlayback(using: settings, credentials: credentials)
        guard prefs.xiaoAI == settings, playerSelectionRevision == selection else {
            report(.unavailable, "小爱链路设置已变更，本次不会打开网易云。")
            return false
        }
        report(outcome(result).state, result.message)
        guard result.status == .confirmed else { return false }
        await runMusicAgent(.daily, player: .netease, opening: result.message)
        xiaoAIStatus = "已收到巴法信号。\(notice.detail)"
        return true
    }

    private func commandAction(_ text: String) async -> ControllerAction? {
        if let action = IntentParser.parse(text) { return action }
        guard let plan = await MusicAgentPlanner.interpret(text) else { return nil }
        switch plan.intent {
        case .dailyRecommendations: return .playDailyRecommendations
        case .searchAndPlay(let title, let artist): return .playSong(title: title, artist: artist)
        }
    }

    func switchTo(_ host: HostID, displayOnly: Bool) {
        Task { await performSwitch(host, displayOnly: displayOnly) }
    }

    func handOffPeripherals(to target: HostID) {
        guard !isSwitching else { return }
        notice = routePeripherals(to: target, using: hubCalibration)
    }

    func verifyHubAt(_ host: HostID) {
        prefs.routeAwaitingDeparture = false
        manualHubOwner = host
        notice = Outcome(.confirmed, "已记录你确认的外设归属：\(host.title)")
    }

    func selectRouteReceiver(_ fingerprint: String) {
        guard fingerprint != prefs.routeReceiver else { return }
        prefs.routeSensorsVerified = false
        prefs.routeReceiver = fingerprint
    }

    func captureRouteSpeaker() {
        guard let output = SystemOutput.info(), let uid = output.uid else {
            notice = Outcome(.unavailable, "系统未找到可识别的当前输出设备")
            return
        }
        if prefs.routeSpeakerUID != uid { prefs.routeSensorsVerified = false }
        prefs.routeSpeakerUID = uid
        prefs.routeSpeakerName = output.name
    }

    private func updateOwnership() {
        if prefs.routeAwaitingDeparture && prefs.routeSensorsVerified &&
            permission == .granted && routeReceiverCount == 0 && !routeSpeakerPresent {
            prefs.routeAwaitingDeparture = false
        }
        if prefs.routeSensorsVerified && !localPeripheralsPresent && manualHubOwner == .mac {
            manualHubOwner = nil
        }
    }

    func readDisplay() {
        Task {
            guard let calibration else {
                notice = Outcome(.unavailable, "请先选择显示器或填写 BetterDisplay UUID")
                return
            }
            let reading = await display.read(calibration)
            visibleHost = host(for: reading.value)
            notice = outcome(reading.result)
            if let value = reading.value {
                notice = Outcome(.confirmed, "当前输入值 \(value)\(visibleHost.map { " · \($0.title)" } ?? "")")
            }
        }
    }

    func captureDisplayValue(_ host: HostID) {
        Task {
            guard let calibration else {
                notice = Outcome(.unavailable, "请先选择显示器或填写 BetterDisplay UUID")
                return
            }
            let reading = await display.read(calibration)
            if let value = reading.value {
                if host == .mac { prefs.macInput = String(value) }
                else { prefs.windowsInput = String(value) }
                visibleHost = self.host(for: value)
                notice = Outcome(.confirmed, "\(host.title) 输入已保存：\(value)")
            } else {
                notice = outcome(reading.result)
            }
        }
    }

    func beginPanelRecording() { beginVoice(.panel) }
    func finishPanelRecording() { finishVoice(.panel) }
    var isWaitingForT1Silence: Bool { t1PulseReleaseAt != nil }
    func stopRecording() {
        if let voiceOrigin { finishVoice(voiceOrigin) }
    }
    func cancelPanelRecording() {
        if voiceOrigin == .panel { cancelVoice() }
    }

    func cancelVoice() {
        let cancelBluetooth = voiceOrigin == .chromecast
        let wasActive = voiceSession != nil
        voiceSilenceJob?.cancel()
        voiceSilenceJob = nil
        t1PulseReleaseAt = nil
        voiceJob?.cancel()
        voiceJob = nil
        voiceSession = nil
        voiceTextTarget = nil
        voiceOrigin = nil
        if cancelBluetooth { chromecastVoice.cancelCapture() }
        voice.cancel()
        isRecording = false
        isRecognizing = false
        if wasActive { notice = Outcome(.unavailable, "语音已取消") }
    }

    func connectChromecastVoice() {
        guard chromecastDevices.count == 1 else {
            notice = Outcome(.unavailable, "请先在系统蓝牙中连接唯一的一只 Chromecast Remote")
            return
        }
        if prefs.chromecastVoiceEnabled {
            chromecastVoice.stop()
            chromecastVoice.start(cachedPeripheralID: prefs.chromecastPeripheralID)
        } else { prefs.chromecastVoiceEnabled = true }
    }

    private func beginChromecastVoice() -> Bool {
        guard voiceOrigin == nil else { return false }
        if isRecognizing { cancelVoice() }
        voiceOrigin = .chromecast
        voiceSession = UUID()
        prepareVoiceDestination()
        lastTranscript = ""
        isRecording = true
        notice = Outcome(.submitted, "Chromecast 语音键已按下，正在接收遥控器音频")
        return true
    }

    private func finishChromecastVoice(_ samples: [Float], sampleRate: Double) {
        guard voiceOrigin == .chromecast, let token = voiceSession else { return }
        voiceOrigin = nil
        isRecording = false
        isRecognizing = true
        notice = Outcome(.submitted, "遥控器麦克风已停止，正在本地转写")
        let config = whisperConfiguration
        voiceJob = Task {
            let result = await voice.recognizePCM(samples, sampleRate: sampleRate, using: config)
            await completeVoiceRecognition(result, token: token, bluetooth: true)
        }
    }

    private var whisperConfiguration: WhisperConfiguration? {
        prefs.whisperExecutable.isEmpty && prefs.whisperModel.isEmpty ? nil :
            WhisperConfiguration(executablePath: prefs.whisperExecutable, modelPath: prefs.whisperModel)
    }

    private func save() {
        guard storedPreferencesReadable else { return }
        do {
            try prefs.save()
            settingsError = nil
        } catch {
            settingsError = "无法保存设置：\(error.localizedDescription)"
        }
    }

    private func updateMonitoredDevices() {
        // Follow releases across presets so a held key cannot become a fresh press at a mode change.
        let bound = [prefs.bindings, prefs.xiaomiBindings, prefs.chromecastBindings].flatMap { profile in
            profile.compactMap { key, binding -> String? in
                guard binding.enabled, let role = KeyRole(rawValue: key),
                      prefs.remoteMode != nil || RemoteMode.allows(role, mode: nil, legacyEnabled: prefs.mappingsEnabled)
                else { return nil }
                return binding.device
            }
        }
        hid.monitoredDeviceFingerprints = Set(bound).union(devices.filter {
            $0.isDirectT1Receiver || $0.isXiaomiBluetoothRemote || $0.isChromecastRemote
        }.map(\.fingerprint))
    }

    private func updateVoiceHotkey() {
        voiceHotkey.stop()
        guard prefs.voiceHotkeyEnabled else {
            if voiceOrigin == .keyboard { cancelVoice() }
            return
        }
        if !voiceHotkey.start(
            down: { [weak self] in self?.beginVoice(.keyboard) },
            up: { [weak self] in self?.finishVoice(.keyboard) }
        ) {
            notice = Outcome(.unavailable, "语音快捷键已被占用，仍可在界面按住录音")
        }
    }

    private func updateActionHotkeys() {
        actionHotkeys.stop()
        let actions: [ControllerAction] = [
            .previousTrack, .togglePlayback, .nextTrack, .volumeDown,
            .toggleMute, .volumeUp, .nextPlayer, .switchOtherHost
        ]
        let unavailable = actionHotkeys.start(actionsEnabled: prefs.actionHotkeysEnabled, modesEnabled: prefs.modeHotkeysEnabled) { [weak self] index in
            guard let self else { return }
            switch index {
            case 10: self.selectRemoteMode((self.prefs.remoteMode ?? .native).next)
            case 11: self.selectRemoteMode(.native)
            case 12: self.selectRemoteMode(.media)
            case 13: self.selectRemoteMode(.host)
            case 1...actions.count: self.submit(actions[index - 1])
            default: break
            }
        }
        if !unavailable.isEmpty {
            notice = Outcome(.unavailable, "这些 ⌃⌥⇧ 快捷键无法注册：" + unavailable.map(ActionHotkeys.label).joined(separator: "、"))
        }
    }

    private func resetInput(in profile: RemoteProfile? = nil) {
        nativeGestures.removeAll()
        if let profile { gestures[profile] = nil }
        else { gestures.removeAll() }
        if profile == nil || profile == .t1 { activeKeyRole = nil }
        if profile == nil || profile == .xiaomi { activeXiaomiKeyRole = nil }
        if profile == nil || profile == .chromecast {
            activeChromecastKeyRole = nil
            activeChromecastControl = nil
            chromecastBasePresses.removeAll()
        }
        guard case .remote(let fingerprint) = voiceOrigin else { return }
        if let profile, !bindings(for: profile).values.contains(where: { $0.device == fingerprint }) { return }
        cancelVoice()
        notice = Outcome(.unavailable, "语音键状态已重置，录音已取消")
    }

    private func receive(_ event: HIDEvent) {
        if event.device.isChromecastRemote {
            if event.phase == .down { activeChromecastControl = event.control.id }
            else if event.phase == .up && activeChromecastControl == event.control.id { activeChromecastControl = nil }
        }
        if event.device.isChromecastRemote {
            let name = ChromecastButton.all.first { $0.id == event.control.id }?.name ?? event.control.id
            lastChromecastControl = "\(name) · \(event.phase == .up ? "松开" : "按下")"
        }
        defer {
            if nativeIsolationPending, !hid.isHoldingRemoteKey { scheduleIsolationRefresh() }
        }
        let inProbe = isProbing && hid.diagnosticDeviceIDs.contains(event.device.id)
        if inProbe {
            let phase: String
            var durationLabel = ""
            switch event.phase {
            case .down:
                phase = "按下"
                probePressTimes[event.device.id, default: [:]][event.control] = event.timestamp
            case .up:
                phase = "松开"
                if let start = probePressTimes[event.device.id]?.removeValue(forKey: event.control), event.timestamp >= start {
                    durationLabel = String(format: "  %.0f 毫秒", (event.timestamp - start) * 1_000)
                }
            case .repeatPress: phase = "重复"
            }
            let source = event.source == .chromecastCompatibility ? " · 蓝牙短报文" : ""
            inputLog.append("\(phase)  \(event.control.id)  \(event.integerValue)\(durationLabel)\(source)")
            if inputLog.count > 40 { inputLog.removeFirst(inputLog.count - 40) }
        }
        if let role = learningRole {
            guard inProbe else { return }
            switch event.phase {
            case .down:
                if role == .cycleMode && RemoteMode.isReturnKey(page: event.control.usagePage, usage: event.control.usage) {
                    notice = Outcome(.unavailable, "OK／回车用于原生输入和模式内动作，请另选一个模式键")
                    return
                }
                if event.device.isXiaomiBluetoothRemote, event.control.usagePage == 0x07,
                   event.control.usage == 0x66 {
                    notice = Outcome(.unavailable, "小米遥控器的电源键仍由 macOS 处理，请选择其他按键")
                    return
                }
                // Ordinary mouse buttons must never be learned from a shared KMFU
                // interface or from a separate mouse. Only T1's own OK-as-click is allowed.
                if event.control.usagePage == 0x09,
                   !(role == .home && event.device.isDirectT1Receiver && event.device.usage == 0x02 && event.control.usage == 1) {
                    notice = Outcome(.unavailable, "已忽略鼠标点击；如果要配置 OK，请关闭空鼠后再按 OK")
                    return
                }
                if candidate == nil { candidate = event }
            case .up:
                guard let candidate, candidate.device.id == event.device.id, candidate.control == event.control else { return }
                let device = event.device.fingerprint
                let control = event.control.id
                if RemoteProfile.allCases.contains(where: { profile in
                    bindings(for: profile).contains { key, binding in
                        (profile != mappingProfile || key != role.rawValue) &&
                            KeyRole(rawValue: key).map { role.conflicts(with: $0) } != false &&
                            binding.device == device && binding.control == control
                    }
                }) {
                    notice = Outcome(.unavailable, "此键在同一模式已有动作，或被模式键占用。请先移除冲突的绑定。")
                    self.candidate = nil
                    return
                }
                learningRole = nil
                self.candidate = nil
                let useImmediately = event.source == .chromecastCompatibility || (event.device.isDirectT1Receiver && role.matchesStandardPlaybackKey(
                    page: event.control.usagePage, usage: event.control.usage
                ))
                editedBindings[role.rawValue] = KeyBinding(device: device, control: control, enabled: useImmediately)
                if event.control.usagePage == 0x09 {
                    notice = Outcome(.unavailable, "OK 的鼠标左键输入尚无法独立隔离，请关闭空鼠并用回车方式重新学习")
                } else if useImmediately {
                    if !allowsRemoteRole(role) || (prefs.remoteMode == nil && (role == .left || role == .right) && !prefs.mediaMode) {
                        notice = Outcome(.confirmed, "已学习并启用此键，切到媒体模式后使用")
                    } else {
                        notice = Outcome(.confirmed, "已学习并启用此键")
                    }
                } else {
                    notice = Outcome(.confirmed, "已学习。确认原生按键无冲突后，再开启映射")
                }
            case .repeatPress: break
            }
            return
        }
        guard event.isMonitored else { return }
        if prefs.remoteMode == .native {
            if event.source == .chromecastCompatibility { processChromecastBase(event) }
            if event.device.isDirectT1Receiver || event.device.isXiaomiBluetoothRemote {
                handleNativeKeyboard(event)
            }
        }
        for profile in RemoteProfile.allCases {
            guard let role = bindings(for: profile).first(where: { key, binding in
                binding.enabled && binding.device == event.device.fingerprint && binding.control == event.control.id &&
                    KeyRole(rawValue: key).map(allowsRemoteRole) == true
            }).flatMap({ KeyRole(rawValue: $0.key) }) else { continue }
            // T1/Xiaomi keep their original voice key. Only the mode key is
            // observed here; no native key is remapped or consumed in native mode.
            if prefs.remoteMode == .native && role != .cycleMode { continue }
            if prefs.remoteMode?.isolatesMappedKeys == true, event.source != .chromecastCompatibility,
               (nativeIsolationPending || !nativeIsolation.isIsolated(event.device,
                    key: HIDKey(page: event.control.usagePage, usage: event.control.usage))) {
                if event.phase == .up {
                    let key = HIDKey(page: event.control.usagePage, usage: event.control.usage)
                    notice = Outcome(.unavailable, key.supportsNativeIsolation
                        ? "按键隔离连接尚未就绪，本次映射已暂停，正在自动重新连接。"
                        : "此按键的原生动作无法独立隔离。OK 请关闭空鼠后用回车方式学习。")
                    scheduleIsolationRefresh()
                }
                return
            }
            process(event, as: role, in: profile)
            return
        }
        if prefs.remoteMode != .native, event.source == .chromecastCompatibility { processChromecastBase(event) }
    }

    private func handleNativeKeyboard(_ event: HIDEvent) {
        let isMute = (event.control.usagePage == 0x0C && event.control.usage == 0xE2) ||
            (event.control.usagePage == 0x07 && event.control.usage == 0x7F)
        if isMute {
            let phase: KeyPhase = event.phase == .down ? .down : event.phase == .up ? .up : .repeatPress
            if nativeGestures[event.device.fingerprint, default: GestureEngine()].handle(
                .mute, phase: phase, at: event.timestamp, mediaMode: false, mode: nil
            ) == .action(.toggleMute) {
                Task {
                    if let result = await nativeAudio.handleNativeKeyFallback() { updateNativeMuteResult(result) }
                }
            }
        }
        if event.phase == .down && ((event.control.usagePage == 0x0C && event.control.usage == 0xCF) ||
                                   (event.device.isXiaomiBluetoothRemote && event.control.usagePage == 7 && event.control.usage == 0x3E)) {
            notice = Outcome(.submitted, "原生语音键已交给 macOS；文字由系统听写输入当前文本框。")
        }
    }

    private func handleNativeChromecastMedia(_ action: ControllerAction) {
        switch action {
        case .toggleMute:
            Task { updateNativeMuteResult(await nativeAudio.toggle()) }
        case .volumeUp: notice = outcome(NativeMediaKeys.send(.volumeUp))
        case .volumeDown: notice = outcome(NativeMediaKeys.send(.volumeDown))
        case .togglePlayback: notice = outcome(NativeMediaKeys.send(.playPause))
        case .previousTrack: notice = outcome(NativeMediaKeys.send(.previous))
        case .nextTrack: notice = outcome(NativeMediaKeys.send(.next))
        default: submit(action) // explicit user-defined base action
        }
    }

    func releaseNativeSoftwareMute() { updateNativeMuteResult(nativeAudio.release()) }

    private func updateNativeMuteResult(_ result: PlatformResult) {
        updateOutput(result)
        if result.status == .confirmed {
            RemoteModeHUD.shared.showSystemMute(nativeAudio.isSoftwareMuted || audioOutput?.isMuted == true,
                                               device: audioOutput?.name ?? "系统音频输出")
        }
    }

    private func process(_ event: HIDEvent, as role: KeyRole, in profile: RemoteProfile) {
        let origin = VoiceOrigin.remote(event.device.fingerprint)
        if role == .voice && event.phase != .repeatPress {
            voiceKeyLog.notice("Mapped voice key \(event.phase.rawValue, privacy: .public) at \(event.timestamp)")
        }
        let phase: KeyPhase
        switch event.phase {
        case .down:
            phase = .down
            if profile == .t1 { activeKeyRole = role }
            else if profile == .xiaomi { activeXiaomiKeyRole = role }
            else { activeChromecastKeyRole = role }
        case .up:
            phase = .up
            if profile == .t1 && activeKeyRole == role { activeKeyRole = nil }
            if profile == .xiaomi && activeXiaomiKeyRole == role { activeXiaomiKeyRole = nil }
            if profile == .chromecast && activeChromecastKeyRole == role { activeChromecastKeyRole = nil }
        case .repeatPress: phase = .repeatPress
        }
        switch gestures[profile, default: GestureEngine()].handle(
            role, phase: phase, at: event.timestamp, mediaMode: prefs.mediaMode, mode: prefs.remoteMode
        ) {
        case .action(let action): submit(action)
        case .cycleMode:
            guard lastModeRelease.map({ event.timestamp - $0 >= 0.18 }) ?? true else { return }
            lastModeRelease = event.timestamp
            selectRemoteMode((prefs.remoteMode ?? .native).next)
        case .beginVoice:
            if voiceOrigin == origin, let firstRelease = t1PulseReleaseAt,
               VoicePulseEndPolicy.isSecondPress(firstRelease: firstRelease, nextPress: event.timestamp) {
                finishVoice(origin)
            } else {
                beginVoice(origin, classifySpeech: Self.isT1VoiceControl(event), interruptRecognition: true)
            }
        case .finishVoice:
            finishVoice(origin)
        case .shortVoiceRelease:
            guard voiceOrigin == origin else { return }
            if isT1VoicePulse(event) {
                finishAfterSpeech(origin, firstRelease: event.timestamp)
            } else {
                cancelVoice()
                notice = Outcome(.unavailable, "语音键上报的按住时间不足 180 毫秒，录音已取消")
            }
        case .cancelVoice:
            if voiceOrigin == .remote(event.device.fingerprint) {
                cancelVoice()
                notice = Outcome(.unavailable, "录音已达 15 秒，本次语音已取消")
            }
        case nil: break
        }
    }

    private var profiles: [PlayerProfile] {
        prefs.players.map { PlayerProfile(bundleID: $0.id, name: $0.name) }
    }

    private func dispatch(_ action: ControllerAction) async {
        switch action {
        case .volumeUp: await stepVolume(up: true)
        case .volumeDown: await stepVolume(up: false)
        case .setVolume(let percent):
            if prefs.playerVolumeSteps { await setSelectedPlayerVolume(percent) }
            else { updateOutput(SystemOutput.set(percent: percent)) }
        case .toggleMute:
            if prefs.playerVolumeSteps {
                guard let target = profiles.first(where: { $0.bundleID == prefs.playerID }) else {
                    notice = Outcome(.unavailable, "请先选择播放器。")
                    return
                }
                let selection = playerSelectionRevision
                let result = await nativeAudio.togglePlayer(target, isCurrent: { [weak self] in
                    self?.playerSelectionRevision == selection && self?.prefs.playerID == target.bundleID
                })
                if playerSelectionRevision == selection {
                    notice = outcome(result)
                    if result.status == .confirmed {
                        RemoteModeHUD.shared.showPlayerMute(mutedPlayers.contains(target.bundleID), player: target.name)
                    }
                }
            } else { updateNativeMuteResult(await nativeAudio.toggle()) }
        case .switchHost(let host): await performSwitch(host, displayOnly: false)
        case .switchDisplay(let host): await performSwitch(host, displayOnly: true)
        case .switchOtherHost:
            await performSwitch(nil, displayOnly: !toggleWithPeripherals)
        default: await handlePlayerAction(action)
        }
    }

    private func updateOutput(_ result: PlatformResult) {
        audioOutput = SystemOutput.info()
        updateOwnership()
        notice = outcome(result)
    }

    private func stepVolume(up: Bool) async {
        var systemResult: PlatformResult?
        if !prefs.playerVolumeSteps {
            let result = SystemOutput.adjust(by: up ? 5 : -5)
            guard result.status == .unavailable else { updateOutput(result); return }
            systemResult = result
        }
        guard await acquirePlayerControl() else { return }
        defer { playerActionInProgress = false }
        guard let target = players.installedPlayers(profiles).first(where: { $0.bundleID == prefs.playerID }) else {
            if let systemResult { updateOutput(systemResult) }
            else { notice = Outcome(.unavailable, "当前播放器未安装，请到音乐页选择") }
            return
        }
        let selection = playerSelectionRevision
        let result = await players.adjustPlayerVolume(up: up, on: target, isCurrent: { [weak self] in
            self?.playerSelectionRevision == selection && self?.prefs.playerID == target.bundleID
        })
        if playerSelectionRevision == selection { notice = outcome(result) }
    }

    private func setSelectedPlayerVolume(_ percent: Int?) async {
        guard await acquirePlayerControl() else { return }
        defer { playerActionInProgress = false }
        guard let target = players.installedPlayers(profiles).first(where: { $0.bundleID == prefs.playerID }) else {
            notice = Outcome(.unavailable, "请确认所选播放器可用，且上一项操作已完成。")
            return
        }
        let selection = playerSelectionRevision
        let result = await players.setPlayerVolume(percent, on: target, isCurrent: { [weak self] in
            self?.playerSelectionRevision == selection && self?.prefs.playerID == target.bundleID
        })
        if playerSelectionRevision == selection { notice = outcome(result) }
    }

    private func handlePlayerAction(_ action: ControllerAction) async {
        guard await acquirePlayerControl() else { return }
        defer { playerActionInProgress = false }
        let installed = players.installedPlayers(profiles)
        switch action {
        case .nextPlayer:
            guard !installed.isEmpty else {
                notice = Outcome(.unavailable, "请先在音乐页添加已安装的播放器")
                return
            }
            let current = installed.firstIndex(where: { $0.bundleID == prefs.playerID })
            await activate(installed[current.map { ($0 + 1) % installed.count } ?? 0])
        case .openPlayer(let id) where id == "netease" || id == PlayerProfile.netease.bundleID:
            rememberPlayer(.netease)
            await runMusicAgent(.open, player: .netease, opening: "正在打开网易云音乐")
        case .openPlayer(let id) where id == PlayerProfile.soda.bundleID:
            if let profile = players.installedPlayers([.soda]).first { await activate(profile) }
            else { notice = Outcome(.unavailable, "汽水音乐未安装。") }
        case .openPlayer(let id):
            if let profile = installed.first(where: { $0.bundleID == id }) { await activate(profile) }
            else { notice = Outcome(.unavailable, "播放器未安装或未配置") }
        case .playDailyRecommendations:
            guard prefs.playerID == PlayerProfile.netease.bundleID else {
                notice = Outcome(.unavailable, "当前选择\(currentPlayerName)，每日推荐需要先选择网易云音乐。")
                return
            }
            await runMusicAgent(.daily, player: .netease, opening: "正在查找网易云每日推荐")
        case .playSong(let title, let artist, let requestedPlayer):
            if let requestedPlayer, requestedPlayer.bundleID != prefs.playerID,
               let explicit = PlayerProfile.songSearchPlayers.first(where: { $0.bundleID == requestedPlayer.bundleID }) {
                rememberPlayer(explicit)
            }
            let bundleID = requestedPlayer?.bundleID ?? prefs.playerID
            guard let player = PlayerProfile.songSearchPlayers.first(where: { $0.bundleID == bundleID }) else {
                notice = Outcome(.unavailable, "当前播放器还未适配语音点歌。请在音乐页选择网易云音乐或汽水音乐。")
                return
            }
            let name = artist.map { "\($0)的《\(title)》" } ?? "《\(title)》"
            await runMusicAgent(.song(title: title, artist: artist), player: player,
                                opening: "正在\(player.name)搜索\(name)")
        default:
            let playback: PlaybackAction
            switch action {
            case .play: playback = .play
            case .pause: playback = .pause
            case .togglePlayback: playback = .toggle
            case .previousTrack: playback = .previous
            case .nextTrack: playback = .next
            default: return
            }
            guard let profile = installed.first(where: { $0.bundleID == prefs.playerID }) else {
                notice = Outcome(.unavailable, "当前播放器未安装，请到音乐页选择")
                return
            }
            let selection = playerSelectionRevision
            let result = await players.perform(playback, on: profile, isCurrent: { [weak self] in
                self?.playerSelectionRevision == selection && self?.prefs.playerID == profile.bundleID
            })
            if playerSelectionRevision == selection { notice = outcome(result) }
        }
    }

    private func acquirePlayerControl() async -> Bool {
        let selection = playerSelectionRevision
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while playerActionInProgress {
            guard !Task.isCancelled, selection == playerSelectionRevision else { return false }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                notice = Outcome(.unavailable, "上一项播放器操作尚未结束，请稍后再试。")
                return false
            }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
        guard !Task.isCancelled, selection == playerSelectionRevision else { return false }
        playerActionInProgress = true
        return true
    }

    private func runMusicAgent(_ request: MusicDesktopAgent.Request, player: PlayerProfile,
                               opening: String) async {
        guard prefs.playerID == player.bundleID else { return }
        let selection = playerSelectionRevision
        isRunningMusicAgent = true
        defer {
            isRunningMusicAgent = false
            musicAgentTask = nil
        }
        notice = Outcome(.submitted, opening)
        let task = Task { @MainActor [weak self] in
            guard let self else { return PlatformResult(.unavailable, "操作已取消。") }
            return await musicAgent.run(request, player: player) { [weak self] message in
                guard self?.playerSelectionRevision == selection else { return }
                self?.notice = Outcome(.submitted, message)
            }
        }
        musicAgentTask = task
        let result = await task.value
        if playerSelectionRevision == selection { notice = outcome(result) }
    }

    private func activate(_ player: PlayerProfile) async {
        rememberPlayer(player)
        let selection = playerSelectionRevision
        let result = outcome(await players.launch(player))
        if playerSelectionRevision == selection { notice = result }
    }

    private func rememberPlayer(_ player: PlayerProfile) {
        if !prefs.players.contains(where: { $0.id == player.bundleID }) {
            prefs.players.append(SavedPlayer(id: player.bundleID, name: player.name))
        }
        prefs.playerID = player.bundleID
    }

    private var calibration: DisplayCalibration? {
        UUID(uuidString: prefs.monitorUUID.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { DisplayCalibration(uuid: $0) }
    }

    private func host(for value: UInt16?) -> HostID? {
        guard let value, let mac = parseVCP(prefs.macInput), let windows = parseVCP(prefs.windowsInput),
              mac != windows else { return nil }
        if value == mac { return .mac }
        if value == windows { return .windows }
        return nil
    }

    private func parseVCP(_ text: String) -> UInt16? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = token.lowercased().hasPrefix("0x")
            ? UInt16(token.dropFirst(2), radix: 16) : UInt16(token)
        return parsed.flatMap { (1...255).contains($0) ? $0 : nil }
    }

    private var hubCalibration: KMFUCalibration {
        KMFUCalibration(keyCode: prefs.kmfuKey, command: prefs.kmfuCommand,
                        option: prefs.kmfuOption, control: prefs.kmfuControl,
                        shift: prefs.kmfuShift, verified: prefs.kmfuVerified)
    }

    private func routePeripherals(to host: HostID, using route: KMFUCalibration) -> Outcome {
        if hubOwner == host { return Outcome(.confirmed, "外设已在目标主机") }
        if prefs.routeAwaitingDeparture {
            return Outcome(.unavailable, "已发出一次 KMFU 热键，等待外设断开或人工确认")
        }
        let systemShortcuts: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100]
        if route.control && route.option && route.shift && !route.command,
           (prefs.actionHotkeysEnabled && systemShortcuts.contains(route.keyCode)) ||
            (prefs.modeHotkeysEnabled && ActionHotkeys.modeKeyCodes.contains(route.keyCode)) ||
            (prefs.voiceHotkeyEnabled && route.keyCode == 101) {
            return Outcome(.unavailable, "KMFU 快捷键与 T1 的全局快捷键冲突")
        }
        let result = outcome(hub.toggle(route, confirmedSource: hubOwner == host.other))
        if result.mayHaveTakenEffect {
            manualHubOwner = nil
            prefs.routeAwaitingDeparture = true
        }
        return result
    }

    private func performSwitch(_ requested: HostID?, displayOnly: Bool) async {
        guard !isSwitching else { return }
        guard let calibration, let mac = parseVCP(prefs.macInput), let windows = parseVCP(prefs.windowsInput),
              mac != windows else {
            notice = Outcome(.unavailable, "请先在主机页校准两个不同的输入源值")
            return
        }
        isSwitching = true
        defer { isSwitching = false }
        let target: HostID
        if let requested {
            target = requested
        } else {
            let reading = await display.read(calibration)
            let current = host(for: reading.value)
            visibleHost = current
            guard let next = SwitchCoordinator.alternateTarget(
                visible: current, hubOwner: hubOwner, withPeripherals: !displayOnly
            ) else {
                if reading.value == nil {
                    notice = Outcome(.unavailable, "Mac 读不到显示器的 DDC 输入。画面在 Windows 时，请从 Windows 发起切回 Mac，或使用显示器信号源菜单。")
                } else if current == nil {
                    notice = Outcome(.unavailable, "当前输入未对应已校准的 Mac 或 Windows，请核对两个输入值。")
                } else {
                    notice = Outcome(.unavailable, "画面和外设归属未对齐。可关掉菜单键联动 KMFU 后仅切画面。")
                }
                return
            }
            target = next
        }
        notice = Outcome(.submitted, "正在切换至 \(target.title)")
        let route = hubCalibration
        let setDisplay: SwitchCoordinator.Backend = { [self] host in
            let value = host == .mac ? mac : windows
            let result = outcome(await display.set(value, on: calibration))
            visibleHost = result.state == .confirmed ? host : nil
            return result
        }
        let routeHub: SwitchCoordinator.Backend = { [self] host in
            routePeripherals(to: host, using: route)
        }
        if let result = await switcher.run(target: target, display: setDisplay, hub: displayOnly ? nil : routeHub) {
            notice = result.outcome
        }
    }

    private func beginVoice(
        _ origin: VoiceOrigin, classifySpeech: Bool = false, interruptRecognition: Bool = false
    ) {
        guard voiceOrigin == nil else {
            voiceKeyLog.notice("Voice start ignored because a recording is already active")
            return
        }
        if isRecognizing {
            guard interruptRecognition else { return }
            voiceKeyLog.notice("New remote press replaced the pending transcription")
            cancelVoice()
        }
        let result = outcome(voice.begin(
            deviceUID: prefs.microphoneUID.isEmpty ? nil : prefs.microphoneUID, classifySpeech: classifySpeech
        ))
        guard result.mayHaveTakenEffect else {
            voiceKeyLog.notice("Voice capture could not start, status=\(result.state.rawValue, privacy: .public), reason=\(result.detail, privacy: .public)")
            notice = result
            return
        }
        voiceOrigin = origin
        voiceSession = UUID()
        prepareVoiceDestination()
        lastTranscript = ""
        isRecording = true
        notice = result
    }

    private static func isT1VoiceControl(_ event: HIDEvent) -> Bool {
        let device = event.device
        return device.isDirectT1Receiver && device.usage == 0x02 && device.locationID != 0 &&
            event.control.usagePage == 0x0C && event.control.usage == 0xCF && event.control.reportID == 0x02
    }

    private func isT1VoicePulse(_ event: HIDEvent) -> Bool {
        guard Self.isT1VoiceControl(event), voice.inputName == "Mic Device" else { return false }
        // Match the USB location so the voice key and microphone belong to the same receiver.
        let fields = prefs.microphoneUID.split(separator: ":")
        return fields.count == 5 && fields[0] == "AppleUSBAudioEngine" &&
            fields[1] == "XING WEI 2.4G USB" && fields[2] == "USB Composite Device" &&
            UInt32(fields[3], radix: 16) == event.device.locationID && fields[4] == "1"
    }

    private func finishAfterSpeech(_ origin: VoiceOrigin, firstRelease: TimeInterval) {
        guard voiceSilenceJob == nil, let token = voiceSession else { return }
        t1PulseReleaseAt = firstRelease
        notice = Outcome(.submitted, "T1 正在录音。再按一次语音键可立即停止并转写。")
        let beganWaiting = ContinuousClock.now
        let speechDeadline = beganWaiting.advanced(by: .seconds(5))
        let finishDeadline = beganWaiting.advanced(by: .seconds(VoicePulseEndPolicy.maximumWait))
        voiceSilenceJob = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.voiceOrigin == origin, self.voiceSession == token else { return }
                self.hid.refreshPermission()
                guard self.hid.permission == .granted else {
                    self.cancelVoice()
                    self.notice = Outcome(.unavailable, "输入监控已关闭，录音已取消")
                    return
                }
                let silence = self.voice.secondsSinceSpeech
                if VoicePulseEndPolicy.shouldFinish(
                    silence: silence, audioGap: self.voice.secondsSinceLastAudioBuffer,
                    classifiedSilence: self.voice.classifiedTrailingSilence
                ) {
                    voiceKeyLog.notice("T1 pulse ended after speech or audio stopped")
                    self.finishVoice(origin)
                    return
                }
                if ContinuousClock.now >= finishDeadline {
                    voiceKeyLog.notice("T1 pulse ended at bounded recording limit")
                    self.finishVoice(origin)
                    return
                }
                if silence == nil && ContinuousClock.now >= speechDeadline {
                    let diagnostics = self.voice.captureDiagnostics
                    let message: String
                    if let diagnostics, diagnostics.capturedSeconds > 0 {
                        if diagnostics.peak < 0.0001 {
                            message = "Mic Device 已收到音频，但输入没有电平。"
                        } else {
                            let peak = Int((20 * log10(diagnostics.peak)).rounded())
                            message = "Mic Device 已收到音频，峰值 \(peak) dBFS，未达到语音检测门限。"
                        }
                    } else {
                        message = "Mic Device 已选中，但 5 秒内未收到音频。"
                    }
                    self.cancelVoice()
                    self.notice = Outcome(.unavailable, message)
                    return
                }
            }
        }
    }

    private func finishVoice(_ origin: VoiceOrigin) {
        if origin == .chromecast { chromecastVoice.finishCapture(); return }
        guard voiceOrigin == origin, let token = voiceSession else { return }
        voiceSilenceJob?.cancel()
        voiceSilenceJob = nil
        t1PulseReleaseAt = nil
        voiceOrigin = nil
        isRecording = false
        isRecognizing = true
        notice = Outcome(.submitted, "正在关闭录音")
        let config = whisperConfiguration
        voiceJob = Task {
            let result = await voice.finish(using: config) {
                guard self.voiceSession == token else { return }
                self.notice = Outcome(.submitted, "录音已停止，正在识别语音")
            }
            await completeVoiceRecognition(result, token: token)
        }
    }

    private func completeVoiceRecognition(_ result: VoiceRecognition, token: UUID, bluetooth: Bool = false) async {
        guard !Task.isCancelled, voiceSession == token else { return }
        lastTranscript = result.transcript ?? ""
        if bluetooth { chromecastVoice.recognitionCompleted(result.transcript == nil ? result.result.message : "本地语音转写完成") }
        if voiceDestination == .focusedText {
            let delivered: PlatformResult
            if let text = result.transcript, let target = voiceTextTarget {
                delivered = await target.insert(text)
            } else if result.transcript != nil {
                delivered = .init(.unavailable, "已完成转写；请先把光标放进可编辑文本框。文字保留在语音页。")
            } else { delivered = result.result }
            guard !Task.isCancelled, voiceSession == token else { return }
            isRecognizing = false; voiceSession = nil; voiceJob = nil; voiceTextTarget = nil
            notice = outcome(delivered)
            lastVoiceDelivery = "原生转文字 · " + delivered.message
            RemoteModeHUD.shared.showVoice(title: delivered.status == .submitted ? "已发送语音文字" :
                delivered.status == .confirmed ? "语音文字已输入" : "语音文字未输入",
                                           detail: delivered.message)
            return
        }
        let action: ControllerAction?
        if let transcript = result.transcript { action = await commandAction(transcript) }
        else { action = nil }
        guard !Task.isCancelled, voiceSession == token else { return }
        isRecognizing = false
        voiceSession = nil
        voiceJob = nil
        voiceTextTarget = nil
        if let action, let transcript = result.transcript { await dispatchSpeechAction(action, transcript: transcript) }
        else if result.transcript != nil { notice = Outcome(.confirmed, "已完成语音转写，未匹配到可执行指令。") }
        else { notice = outcome(result.result) }
    }

    private func prepareVoiceDestination() {
        // Calls reaching our recorder come from a panel/shortcut or ATVV.
        // Native T1/Xiaomi voice is left to macOS before this point.
        voiceDestination = VoiceDestination.resolve(mode: prefs.remoteMode, hasSystemVoiceKey: false)
        voiceTextTarget = voiceDestination == .focusedText ? NativeTextInput.capture() : nil
        lastVoiceDelivery = voiceDestination == .focusedText ?
            (voiceTextTarget == nil ? "原生转文字 · 尚未找到可编辑输入框" : "原生转文字 · 已锁定当前输入框，使用系统键盘事件") : "指令控制模式"
        if voiceDestination == .focusedText {
            RemoteModeHUD.shared.showVoice(title: "原生语音输入", detail: voiceTextTarget == nil ?
                "未找到可编辑输入框 · 转写将保留在语音页" : "正在等待收音 · 文字将输入当前文本框")
        }
    }

    private func outcome(_ result: PlatformResult) -> Outcome {
        let state: OutcomeState
        switch result.status {
        case .confirmed: state = .confirmed
        case .submitted: state = .submitted
        case .unavailable: state = .unavailable
        case .failed: state = .failed
        }
        return Outcome(state, result.message)
    }
}
