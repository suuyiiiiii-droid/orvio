import AppKit
import Darwin
import SwiftUI
import T1Core
import T1Platform

@main
enum T1ControllerEntryPoint {
    @MainActor
    static func main() {
        if let status = MusicDesktopAgent.runOCRWorker(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(status)
        }
        do {
            let lock = try ControllerInstance.lock()
            defer { close(lock) }
            if ControllerInstance.hasLegacyCopy {
                ControllerInstance.showConflict()
                return
            }
            T1ControllerApp.main()
        } catch ControllerInstance.Failure.alreadyRunning {
            ControllerInstance.showConflict()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动 Orvio"
            alert.informativeText = "无法打开控制台的启动锁。\(error.localizedDescription)"
            alert.runModal()
        }
    }
}

private enum ControllerInstance {
    enum Failure: Error { case alreadyRunning }

    static func lock() throws -> Int32 {
        let directory = Preferences.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "controller.lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return descriptor
    }

    /// Versions before 0.2.1 run outside the lock and must be exited before upgrading.
    @MainActor
    static var hasLegacyCopy: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { app in
            guard app.processIdentifier != getpid(), !app.isTerminated,
                  let url = app.bundleURL,
                  let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  let build = Int(version) else { return false }
            return build < 13
        }
    }

    @MainActor
    static func showConflict() {
        let alert = NSAlert()
        alert.messageText = "Orvio已在运行"
        alert.informativeText = "请先从菜单栏退出正在运行的 Orvio，再打开此版本。同时运行两个版本可能会重复执行按键。"
        alert.addButton(withTitle: "好")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

struct T1ControllerApp: App {
    @StateObject private var model = ControllerModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Orvio控制台", id: "control") {
            ControlWindow(model: model)
        }
        .defaultSize(width: 1110, height: 750)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("功能组合") {
                Button("循环切换功能组合") { model.selectRemoteMode((model.prefs.remoteMode ?? .native).next) }
                    .keyboardShortcut(KeyEquivalent("\u{F70D}"), modifiers: [.control, .option, .shift])
                    .disabled(!model.prefs.modeHotkeysEnabled)
                Divider()
                Button("原生") { model.selectRemoteMode(.native) }
                    .keyboardShortcut("1", modifiers: [.control, .option, .shift])
                    .disabled(!model.prefs.modeHotkeysEnabled)
                Button("媒体") { model.selectRemoteMode(.media) }
                    .keyboardShortcut("2", modifiers: [.control, .option, .shift])
                    .disabled(!model.prefs.modeHotkeysEnabled)
                Button("主机切换") { model.selectRemoteMode(.host) }
                    .keyboardShortcut("3", modifiers: [.control, .option, .shift])
                    .disabled(!model.prefs.modeHotkeysEnabled)
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Orvio").font(.headline)
                        Text(model.deviceSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        openWindow(id: "control")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("打开控制台")
                }
                PlaybackButtons(model: model)
                Menu("遥控器 · \(model.remoteModeTitle)") {
                    ForEach(RemoteMode.allCases) { mode in
                        Button(mode.title) { model.selectRemoteMode(mode) }
                    }
                }
                Divider()
                HStack {
                    HoldToTalkButton(model: model)
                    Spacer()
                    Menu("切换主机") {
                        Button("切到 Mac") { model.switchTo(.mac, displayOnly: false) }
                        Button("切到 Windows") { model.switchTo(.windows, displayOnly: false) }
                    }
                    .fixedSize()
                    .disabled(model.isSwitching)
                    Button("退出") { NSApp.terminate(nil) }.buttonStyle(.borderless)
                }
                NoticeView(outcome: model.notice)
            }
            .padding(16)
            .frame(width: 335)
        } label: {
            Label { Text("Orvio") } icon: { Image(nsImage: T1Design.menuMark) }
        }
        .menuBarExtraStyle(.window)

    }
}

private struct ControlWindow: View {
    @ObservedObject var model: ControllerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = Page.overview
    @State private var showingPermissionGuide = false
    @State private var offeredPermissionGuide = false

    private enum Page: String, CaseIterable, Identifiable {
        case overview = "设备导览", keys = "按键映射", music = "音乐控制", hosts = "主机切换", voice = "语音控制"
        var id: Self { self }

        var icon: String {
            switch self {
            case .overview: return "cube.transparent"
            case .keys: return "keyboard"
            case .music: return "music.note"
            case .hosts: return "display.2"
            case .voice: return "waveform"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Divider().opacity(0.45)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if page != .overview {
                            Label(page.rawValue, systemImage: page.icon)
                                .font(.system(size: 29, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        switch page {
                        case .overview: DeviceStudio(model: model) { profile in
                            model.mappingProfile = profile
                            select(.keys)
                        }
                        case .keys: KeyPane(model: model)
                        case .music: MusicPane(model: model)
                        case .hosts: HostPane(model: model)
                        case .voice: VoicePane(model: model)
                        }
                    }
                    .id(page)
                    .transition(reduceMotion ? .identity : .opacity)
                    .padding(26)
                    .frame(maxWidth: 1250, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                Divider().opacity(0.55)
                VStack(alignment: .leading, spacing: 5) {
                    if let error = model.settingsError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                    NoticeView(outcome: model.notice)
                }
                .padding(.horizontal, 25)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
            }
        }
        .background { T1Design.windowBackdrop }
        .tint(T1Design.accent)
        .frame(minWidth: 930, minHeight: 640)
        .onAppear {
            guard !offeredPermissionGuide else { return }
            offeredPermissionGuide = true
            showingPermissionGuide = !model.prefs.permissionGuideSeen
        }
        .sheet(isPresented: $showingPermissionGuide) {
            PermissionGuide(model: model) {
                showingPermissionGuide = false
                model.prefs.permissionGuideSeen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
            model.refreshMusicAgentStatus()
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                ProductMark().frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orvio").font(.system(size: 17, weight: .semibold))
                    Text("控制台").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            VStack(spacing: 6) {
                ForEach(Page.allCases) { item in
                    Button { select(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).font(.system(size: 15, weight: .medium)).frame(width: 23)
                            Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 42)
                        .foregroundStyle(page == item ? T1Design.accent : Color.primary.opacity(0.76))
                        .background {
                            if page == item {
                                RoundedRectangle(cornerRadius: 13).fill(T1Design.accent.opacity(0.13))
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            Spacer()
            Button { showingPermissionGuide = true } label: {
                Label("权限引导", systemImage: "lock.shield")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)
            HStack(spacing: 9) {
                Image(systemName: "macmini").font(.system(size: 15)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机 Mac").font(.caption.weight(.semibold))
                    Text(model.permission == .granted ? "输入监控可用" : "输入监控未授权")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal, 13)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .frame(width: 172)
        .background(.ultraThinMaterial)
    }

    private func select(_ target: Page) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.19)) {
            page = target
        }
    }
}

private struct KeyPane: View {
    @ObservedObject var model: ControllerModel
    @State private var learningDialogRole: KeyRole?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard("遥控器模式") {
                Picker("当前模式", selection: Binding(
                    get: { model.prefs.remoteMode },
                    set: { if let mode = $0 { model.selectRemoteMode(mode) } }
                )) {
                    if model.prefs.remoteMode == nil { Text("现有映射").tag(nil as RemoteMode?) }
                    ForEach(RemoteMode.allCases) { mode in Text(mode.title).tag(Optional(mode)) }
                }
                .pickerStyle(.segmented)
                Text("短按模式键，在原生、媒体和主机切换间循环。\(model.nativeIsolationStatus)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.prefs.remoteMode == nil {
                    HStack {
                        Toggle("启用现有映射", isOn: $model.prefs.mappingsEnabled)
                        Toggle("左右键切歌", isOn: $model.prefs.mediaMode)
                    }
                }
            }
            SectionCard("学习按键") {
                Picker("遥控器", selection: $model.mappingProfile) {
                    ForEach(RemoteProfile.allCases) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                if model.mappingProfile == .xiaomi {
                    if model.xiaomiDevices.isEmpty {
                        Text("请在 macOS「蓝牙」中连接小米遥控器 2 Pro（RC003）。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("小米蓝牙遥控器已连接", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if model.permission != .granted {
                        Button("打开输入监控设置", action: model.requestInputPermission)
                    } else {
                        Label("输入监控可用", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isProbing {
                        Button("结束诊断", action: model.endProbe)
                    } else {
                        Button("开始诊断", action: model.beginProbe).buttonStyle(.borderedProminent)
                    }
                }
                if model.isProbing {
                    Picker("设备", selection: $model.selectedDevice) {
                        Text("选择设备或 HID 集合").tag("")
                        if model.mappingProfile == .t1 && !model.directT1Devices.isEmpty {
                            Text("T1 接收器 · 自动（键盘和媒体／鼠标）").tag(ControllerModel.directT1Selection)
                        }
                        ForEach(model.diagnosticDevices, id: \.id) { device in
                            Text(deviceLabel(device))
                                .tag(device.id)
                        }
                    }
                    if model.mappingProfile == .t1 && !model.directT1Devices.isEmpty {
                        Text("自动模式同时学习两个 T1 集合。左／右键用于切歌，OK 建议关闭空鼠后学习。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.devices.first(where: { $0.id == model.selectedDevice })?.isSharedHub == true {
                        Text("KMFU 可能把多种外设合并。确认飞鼠触发独有的事件后再开启映射。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if !model.inputLog.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(model.inputLog.suffix(8).enumerated()), id: \.offset) { _, event in
                                Text(event).font(.system(.caption, design: .monospaced))
                            }
                        }
                        .textSelection(.enabled)
                    }
                    if let summary = model.vendorReportSummary {
                        Text(summary).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            SectionCard("模式键") { bindingRows([.cycleMode]) }
            SectionCard("媒体键位预设") {
                bindingRows(KeyRole.allCases.filter { $0 != .cycleMode && $0 != .switchHost })
            }
            SectionCard("主机切换键位预设") {
                bindingRows([.switchHost])
                Text("在「主机切换」页配置显示器和外设。进入此模式后，短按已绑定的切换键。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("当前组合中已隔离的绑定只执行自定义动作。未绑定的按键使用原生功能。OK 的左键模式请先关闭空鼠并重新学习。")
                .font(.caption).foregroundStyle(.secondary)
            Button("恢复当前遥控器设置", action: model.restoreBindings)
            SectionCard("电脑快捷键") {
                Toggle("启用功能组合切换快捷键", isOn: $model.prefs.modeHotkeysEnabled)
                Text("⌃⌥⇧F10 循环切换 · ⌃⌥⇧1 原生 · ⌃⌥⇧2 媒体 · ⌃⌥⇧3 主机")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("启用 ⌃⌥⇧F1–F8", isOn: $model.prefs.actionHotkeysEnabled)
                Text("F1 上一曲 · F2 播放/暂停 · F3 下一曲 · F4 降低音量 · F5 静音 · F6 提高音量 · F7 切播放器 · F8 切主机")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $learningDialogRole, onDismiss: model.cancelLearning) { role in
            VStack(alignment: .leading, spacing: 14) {
                Text(role.title).font(.headline)
                if model.mappingProfile == .xiaomi {
                    Text("在小米蓝牙遥控器上按一下要映射的按键并松开。")
                } else if role == .home {
                    Text("先关闭飞鼠的空鼠模式，再按一下 OK 并松开，以回车方式学习并隔离。")
                } else {
                    Text("在飞鼠上按一下要映射的按键并松开。")
                }
                Text(model.notice.detail).foregroundStyle(.secondary)
                    .accessibilityIdentifier("learning-status")
                HStack {
                    Spacer()
                    Button(model.learningRole == nil ? "完成" : "取消") { learningDialogRole = nil }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 415)
        }
        .onDisappear { model.endProbe() }
    }

    private func bindingRows(_ roles: [KeyRole]) -> some View {
        ForEach(roles) { role in
            HStack {
                Text(role == .menu && model.prefs.remoteMode == nil ? "菜单 · 切播放器 / 长按切主机" : role.title)
                Spacer()
                if let binding = model.editedBindings[role.rawValue] {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(binding.control).font(.system(.caption, design: .monospaced))
                        if binding.enabled && model.allowsRemoteRole(role) && model.needsNativeIsolation(binding) {
                            Text(model.nativeBindingStatus(binding)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .foregroundStyle(.secondary)
                    Toggle("启用", isOn: Binding(
                        get: { model.editedBindings[role.rawValue]?.enabled ?? false },
                        set: { model.editedBindings[role.rawValue]?.enabled = $0 }
                    ))
                    .help("本组合会隔离已启用按键的原生功能")
                    Button("移除") { model.editedBindings.removeValue(forKey: role.rawValue) }
                }
                Button(role == .home ? "换成 OK／学习" : "学习") {
                    if model.learn(role) { learningDialogRole = role }
                }
                .accessibilityLabel("学习\(role.title)")
                .disabled(!model.canLearnKey)
            }
            if role != roles.last { Divider() }
        }
    }

    private func deviceLabel(_ device: HIDDevice) -> String {
        if device.isDirectT1Receiver {
            switch device.usage {
            case 6: return "T1 接收器 · 键盘 · 1915:1025 · 1/6"
            case 2: return "T1 接收器 · 媒体／鼠标 · 1915:1025 · 1/2"
            default: break
            }
        }
        return "\(device.name) · \(device.transport) · \(hex(device.vendorID)):\(hex(device.productID)) · \(hex(device.usagePage))/\(hex(device.usage))"
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String { String(value, radix: 16, uppercase: true) }
}

private struct MusicPane: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard("播放控制") {
                PlaybackButtons(model: model)
                HStack {
                    Button("启动所选播放器") { model.submit(.openPlayer(model.prefs.playerID)) }
                    Spacer()
                    Button("开启辅助功能权限", action: model.requestAutomationPermission)
                }
                Toggle("优先调整播放器音量", isOn: $model.prefs.playerVolumeSteps)
                if model.prefs.playerVolumeSteps, model.prefs.playerID == PlayerProfile.soda.bundleID {
                    Text("汽水音乐使用应用内快捷键 ⌘↑／⌘↓。在后台时会短暂激活播放器窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("当前控制目标：\(model.currentPlayerName)。界面按钮、遥控器及快捷键共用此目标。")
                    .font(.caption).foregroundStyle(.secondary)
                if let output = model.audioOutput {
                    Text("\(output.name)  \(output.volumePercent.map { "\($0)%" } ?? "系统音量不可调")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SectionCard("网易云音乐") {
                HStack {
                    Button("播放每日推荐") { model.submit(.playDailyRecommendations) }
                        .disabled(model.isRunningMusicAgent || model.prefs.playerID != PlayerProfile.netease.bundleID)
                    Spacer()
                    if model.musicScreenCaptureAvailable {
                        Label("录屏权限已开启", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("开启录屏权限", action: model.requestMusicScreenCapture)
                    }
                }
                Text("语音点歌使用当前选中的网易云音乐或汽水音乐。也可以说「用汽水音乐播放某位歌手的歌名」。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.musicModelAvailability.message)
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard("播放器列表") {
                if model.prefs.players.isEmpty {
                    Text("添加已安装的音乐应用").foregroundStyle(.secondary)
                }
                ForEach(model.prefs.players) { player in
                    HStack {
                        Button {
                            model.selectPlayer(player.id)
                        } label: {
                            Label(player.name, systemImage: model.prefs.playerID == player.id ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(player.id).font(.caption).foregroundStyle(.secondary)
                        Button("移除") { model.removePlayer(player.id) }
                    }
                }
                Button("添加应用…", action: model.addPlayer)
            }
        }
    }
}

private struct HostPane: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard("切换主机") {
                HStack {
                    Label("画面 \(model.visibleHost?.title ?? "待读回")", systemImage: "display")
                    Spacer()
                    Label("外设 \(model.hubOwner?.title ?? "待确认")", systemImage: "keyboard")
                }
                .font(.callout)
                HStack {
                    Button("切到 Mac") { model.switchTo(.mac, displayOnly: false) }
                        .buttonStyle(.borderedProminent)
                    Button("切到 Windows") { model.switchTo(.windows, displayOnly: false) }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Menu("仅切画面") {
                        Button("Mac") { model.switchTo(.mac, displayOnly: true) }
                        Button("Windows") { model.switchTo(.windows, displayOnly: true) }
                    }
                    .fixedSize()
                }
                .disabled(model.isSwitching)
                Toggle("长按菜单键时同时交接 KMFU 外设", isOn: $model.toggleWithPeripherals)
                    .disabled(model.isSwitching)
            }
            SectionCard("显示器输入校准") {
                Picker("当前连接", selection: Binding(
                    get: { model.displays.first(where: { $0.id.uuidString == model.prefs.monitorUUID })?.id.uuidString ?? "" },
                    set: { if !$0.isEmpty { model.prefs.monitorUUID = $0 } }
                )) {
                    Text("选择显示器").tag("")
                    ForEach(model.displays, id: \.id) { item in Text(item.name).tag(item.id.uuidString) }
                }
                TextField("显示器 UUID", text: $model.prefs.monitorUUID)
                HStack {
                    TextField("Mac 输入值", text: $model.prefs.macInput)
                    Button("用当前值") { model.captureDisplayValue(.mac) }
                    TextField("Windows 输入值", text: $model.prefs.windowsInput)
                    Button("用当前值") { model.captureDisplayValue(.windows) }
                }
                HStack {
                    Button("读当前输入", action: model.readDisplay)
                    Button("刷新显示器", action: model.refreshDisplays)
                }
                .disabled(model.isSwitching)
                Text("在显示器 OSD 中启用 DDC/CI。两台主机输入值可填十进制或 0x 开头的十六进制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard("KMFU 外设交接") {
                HStack {
                    Text("快捷键")
                    Picker("按键", selection: $model.prefs.kmfuKey) {
                        ForEach(functionKeys, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Toggle("⌃", isOn: $model.prefs.kmfuControl)
                    Toggle("⌥", isOn: $model.prefs.kmfuOption)
                    Toggle("⇧", isOn: $model.prefs.kmfuShift)
                    Toggle("⌘", isOn: $model.prefs.kmfuCommand)
                }
                Toggle("已在官方 KMFU 中配置并验证这个快捷键", isOn: $model.prefs.kmfuVerified)
                HStack {
                    Button("确认外设在 Mac") { model.verifyHubAt(.mac) }
                    Button("确认外设在 Windows") { model.verifyHubAt(.windows) }
                    Spacer()
                    Menu("仅交接外设") {
                        Button("Mac") { model.handOffPeripherals(to: .mac) }
                        Button("Windows") { model.handOffPeripherals(to: .windows) }
                    }
                    .fixedSize()
                    Button("打开 KMFU") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "cn.wch.USBCrossLink") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .disabled(model.isSwitching)
                Text("确认归属时，逐项检查键盘、鼠标、音响和接收器。只确认过起点时会发送一次热键，再等待确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.isSwitching)
            SectionCard("自动识别本机外设归属") {
                Picker("共享接收器", selection: Binding(
                    get: { model.prefs.routeReceiver },
                    set: model.selectRouteReceiver
                )) {
                    Text("选择接收器的独立 HID 集合").tag("")
                    let receivers = model.devices.filter { !$0.isSharedHub }
                    if !model.prefs.routeReceiver.isEmpty &&
                        !receivers.contains(where: { $0.fingerprint == model.prefs.routeReceiver }) {
                        Text("所选接收器未连接").tag(model.prefs.routeReceiver)
                    }
                    ForEach(receivers, id: \.id) { device in
                        Text("\(device.name) · \(device.transport) · \(device.usagePage)/\(device.usage)")
                            .tag(device.fingerprint)
                    }
                }
                HStack {
                    Button("记住当前默认音响", action: model.captureRouteSpeaker)
                    Text(model.prefs.routeSpeakerName.isEmpty ? "未记录" : model.prefs.routeSpeakerName)
                        .foregroundStyle(.secondary)
                }
                Toggle("已验证接收器和音响只在本机接管时出现，且键鼠跟随", isOn: $model.prefs.routeSensorsVerified)
                    .disabled(model.prefs.routeReceiver.isEmpty || model.prefs.routeSpeakerUID.isEmpty)
            }
            .disabled(model.isSwitching)
        }
        .onAppear(perform: model.refreshDisplays)
    }

    private let functionKeys: [(name: String, code: UInt16)] = [
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98),
        ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111), ("F13", 105), ("F14", 107),
        ("F15", 113), ("F16", 106), ("F17", 64), ("F18", 79), ("F19", 80), ("F20", 90)
    ]
}

private struct VoicePane: View {
    @ObservedObject var model: ControllerModel
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard("按住说话") {
                HStack {
                    Picker("录音来源", selection: $model.prefs.microphoneUID) {
                        Text("系统默认输入").tag("")
                        if !model.prefs.microphoneUID.isEmpty &&
                            !model.audioInputs.contains(where: { $0.uid == model.prefs.microphoneUID }) {
                            Text("所选麦克风未连接").tag(model.prefs.microphoneUID)
                        }
                        ForEach(model.audioInputs, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    Button("刷新", action: model.refreshAudioInputs)
                    if model.microphoneAllowed {
                        Label("麦克风权限可用", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Button("开启麦克风权限", action: model.requestMicrophonePermission)
                    }
                }
                Toggle("使用电脑快捷键 ⌃⌥⇧F9 按住说话", isOn: $model.prefs.voiceHotkeyEnabled)
                HStack {
                    HoldToTalkButton(model: model)
                    if model.isRecording {
                        Button("停止并转写", action: model.stopRecording)
                    }
                    if model.isRecording || model.isRecognizing { Button("取消", action: model.cancelVoice) }
                    Text(model.microphoneName).foregroundStyle(.secondary)
                    Spacer()
                }
                if model.isRecording {
                    TimelineView(.periodic(from: .now, by: 0.07)) { _ in
                        ProgressView("输入电平", value: Double(model.recordingLevel), total: 1)
                            .progressViewStyle(.linear)
                    }
                }
                if !model.lastTranscript.isEmpty {
                    Text("识别结果  \(model.lastTranscript)").textSelection(.enabled)
                }
            }
            XiaoAIPane(model: model)
            SectionCard("离线识别") {
                TextField("whisper-cli 可执行文件路径", text: $model.prefs.whisperExecutable)
                TextField("Whisper 多语种模型路径", text: $model.prefs.whisperModel)
                Text("留空时使用 Mac 自带的设备端中文识别（需系统支持）。填入两个路径时改用本地 whisper.cpp。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard("文字指令") {
                HStack {
                    TextField("例如播放周杰伦的晴天", text: $command).onSubmit(send)
                    Button("执行", action: send)
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear(perform: model.refreshAudioInputs)
    }

    private func send() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.submitText(text)
    }
}

private struct XiaoAIPane: View {
    @ObservedObject var model: ControllerModel
    @State private var expanded = false
    @State private var uid = ""
    @State private var token = ""

    var body: some View {
        SectionCard("小爱同学") {
            Toggle("以「小爱同学」开头时调用小爱音箱", isOn: $model.prefs.xiaoAI.enabled)
            Text("直接说「播放今日推荐」会在本机执行。小爱音箱模式需在 Home Assistant 接入音箱，并把巴法开关同步到米家。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("设置 Home Assistant 和巴法", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Home Assistant 地址，例如 http://homeassistant.local:8123", text: $model.prefs.xiaoAI.homeAssistantURL)
                    TextField("小爱音箱「执行文本指令」实体（notify.…）", text: $model.prefs.xiaoAI.notifyEntity)
                    TextField("巴法开关主题（以 006 结尾）", text: $model.prefs.xiaoAI.topic)
                    TextField("交给小爱的固定口令", text: $model.prefs.xiaoAI.switchCommand)
                    Toggle("发送「静默执行」参数", isOn: $model.prefs.xiaoAI.includeSilentParameter)
                    TextField("Python 3 路径（留空使用 /usr/bin/python3）", text: $model.prefs.xiaoAI.pythonPath)
                    SecureField("巴法 UID 私钥", text: $uid)
                    SecureField("Home Assistant 长期访问令牌", text: $token)
                    HStack {
                        Button("存入钥匙串") {
                            if model.saveXiaoAICredentials(uid: uid, token: token) { uid = ""; token = "" }
                        }
                        .disabled(uid.isEmpty || token.isEmpty)
                        Button("清除凭据", action: model.clearXiaoAICredentials)
                    }
                }
                .padding(.top, 8)
                .disabled(model.isRunningXiaoAI)
            }
            HStack {
                Button("测试小爱并播放", action: model.testXiaoAIDaily)
                    .disabled(!model.prefs.xiaoAI.enabled || model.isRunningXiaoAI)
                if model.isRunningXiaoAI { ProgressView().controlSize(.small) }
            }
            if !model.xiaoAIStatus.isEmpty {
                Text(model.xiaoAIStatus).font(.callout).textSelection(.enabled)
            }
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.headline)
            content
        }
        .padding(19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .t1Panel()
    }
}

private struct PlaybackButtons: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.currentPlayerName).font(.callout.weight(.semibold))
                Spacer()
                Button("切播放器") { model.submit(.nextPlayer) }
            }
            HStack(spacing: 8) {
                control(.previousTrack, "backward.end.fill", "上一曲")
                control(.togglePlayback, "playpause.fill", "播放 / 暂停")
                control(.nextTrack, "forward.end.fill", "下一曲")
                Spacer(minLength: 6)
                control(.volumeDown, "speaker.wave.1", "降低音量")
                control(.toggleMute, "speaker.slash", "切换静音")
                control(.volumeUp, "speaker.wave.3", "提高音量")
            }
            .controlSize(.regular)
        }
    }

    private func control(_ action: ControllerAction, _ icon: String, _ title: String) -> some View {
        Button { model.submit(action) } label: { Image(systemName: icon) }
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct HoldToTalkButton: View {
    @ObservedObject var model: ControllerModel
    @GestureState private var pressing = false

    private var label: String {
        if model.isRecording {
            return model.isWaitingForT1Silence ? "正在录音" : "正在录音 · 松开发送"
        }
        return model.isRecognizing ? "正在识别…" : "按住说话"
    }

    var body: some View {
        Label(
            label,
            systemImage: model.isRecording ? "waveform" : "mic"
        )
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(model.isRecording ? Color.red.opacity(0.22) : Color.accentColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true }
                .onEnded { _ in model.finishPanelRecording() }
        )
        .onChange(of: pressing) { _, active in
            if active { model.beginPanelRecording() }
        }
        .onDisappear { model.cancelPanelRecording() }
        .accessibilityHint("也可在语音设置启用电脑快捷键")
    }
}

private struct NoticeView: View {
    let outcome: Outcome

    var body: some View {
        Label(outcome.detail, systemImage: icon)
            .font(.caption)
            .foregroundStyle(outcome.state == .failed ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var icon: String {
        switch outcome.state {
        case .confirmed: return "checkmark.circle"
        case .submitted: return "arrow.clockwise.circle"
        case .partial: return "exclamationmark.circle"
        case .unavailable: return "info.circle"
        case .failed: return "xmark.circle"
        }
    }
}
