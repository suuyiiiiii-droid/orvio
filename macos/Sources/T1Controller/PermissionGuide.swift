import AppKit
import ApplicationServices
import AVFoundation
import Speech
import SwiftUI
import T1Platform

private enum SetupPermission: String, CaseIterable, Identifiable {
    case input = "输入监控"
    case control = "辅助功能"
    case microphone = "麦克风"
    case speech = "语音识别"
    case screen = "录屏与系统录音"

    var id: Self { self }

    var icon: String {
        switch self {
        case .input: "keyboard"
        case .control: "cursorarrow.click"
        case .microphone: "mic"
        case .speech: "waveform"
        case .screen: "rectangle.inset.filled"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .input: "Privacy_ListenEvent"
        case .control: "Privacy_Accessibility"
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .screen: "Privacy_ScreenCapture"
        }
    }

    var purpose: String {
        switch self {
        case .input: "接收 T1 和小米遥控器的按下与松开，用于按键映射和按住说话。"
        case .control: "让智能体点击播放器里的搜索框和播放按钮，也用于发送全局快捷键。"
        case .microphone: "按住语音键时，使用你在语音页选定的麦克风录音。"
        case .speech: "使用 macOS 的设备端中文识别。已配置 Whisper 时可以跳过。"
        case .screen: "执行点歌时读取播放器窗口，找到搜索栏和播放控件。"
        }
    }

    var instructions: String {
        switch self {
        case .input: "在「隐私与安全性 → 输入监控」开启 Orvio。如果列表没有它，用「＋」添加当前打开的应用。"
        case .control: "在「隐私与安全性」找到「辅助功能」。部分系统显示为「设备控制和数据访问」。开启当前的 Orvio。"
        case .microphone: "允许系统弹窗里的麦克风请求，或在「隐私与安全性 → 麦克风」开启 Orvio。"
        case .speech: "允许系统弹窗里的语音识别请求，或在「隐私与安全性 → 语音识别」开启 Orvio。"
        case .screen: "在「隐私与安全性 → 录屏与系统录音」开启 Orvio。按系统提示退出并重新打开后，继续检查。"
        }
    }

    @MainActor
    func isAllowed(input: HIDPermission) -> Bool {
        switch self {
        case .input: input == .granted
        case .control: AXIsProcessTrusted() && CGPreflightPostEventAccess()
        case .microphone: PushToTalk.microphoneAllowed
        case .speech: SFSpeechRecognizer.authorizationStatus() == .authorized
        case .screen: MusicDesktopAgent.screenCaptureAvailable()
        }
    }

    var promptsOnFirstRequest: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speech: SFSpeechRecognizer.authorizationStatus() == .notDetermined
        default: false
        }
    }
}

struct PermissionGuide: View {
    @ObservedObject var model: ControllerModel
    let finish: () -> Void

    @State private var allowed: Set<SetupPermission> = []
    @State private var step = 0
    @State private var requesting = false
    @State private var started = false
    private let permissions = SetupPermission.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Label("权限引导", systemImage: "lock.shield")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("按顺序打开所需权限。可以跳过暂时用不到的功能。")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(permissions) { permission in
                        Label(permission.rawValue, systemImage: allowed.contains(permission) ? "checkmark.circle.fill" : permission.icon)
                            .font(.subheadline)
                            .foregroundStyle(allowed.contains(permission) ? .green : Color.primary)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(current == permission ? T1Design.accent.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(width: 147)
                Divider()
                if let current {
                    detail(current)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("设置检查完成").font(.headline)
                        Text(allowed.count == permissions.count
                             ? "所有权限均已检测到。"
                             : "已检测到 \(allowed.count) 项权限。可从控制台左下角再次打开引导。")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 200, alignment: .topLeading)
            Divider()
            HStack {
                Button("稍后") { finish() }.disabled(requesting)
                Spacer()
                Button("上一步") { step -= 1 }.disabled(step == 0 || requesting)
                if let current {
                    Button(allowed.contains(current) ? "下一步" : "暂跳过") { step += 1 }
                        .disabled(requesting)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("完成", action: finish).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(width: 610)
        .background(.regularMaterial)
        .interactiveDismissDisabled(requesting)
        .onAppear {
            check()
            if !started {
                started = true
                step = permissions.firstIndex { !allowed.contains($0) } ?? permissions.count
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private var current: SetupPermission? {
        permissions.indices.contains(step) ? permissions[step] : nil
    }

    private func detail(_ permission: SetupPermission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(step + 1) / \(permissions.count) · \(permission.rawValue)").font(.headline)
            Text(permission.purpose)
            Text(permission.instructions).foregroundStyle(.secondary)
            Label(allowed.contains(permission) ? "已开启" : "待授权",
                  systemImage: allowed.contains(permission) ? "checkmark.circle.fill" : "circle")
                .font(.subheadline)
                .foregroundStyle(allowed.contains(permission) ? .green : Color.secondary)
            HStack {
                Button(permission.promptsOnFirstRequest ? "请求系统授权" : "打开系统设置") {
                    request(permission)
                }
                .buttonStyle(.borderedProminent)
                .disabled(allowed.contains(permission) || requesting)
                Button("重新检测", action: check).disabled(requesting)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func check() {
        model.refreshPermission()
        model.refreshAudioInputs()
        model.refreshMusicAgentStatus()
        allowed = Set(permissions.filter { $0.isAllowed(input: model.permission) })
    }

    private func request(_ permission: SetupPermission) {
        if !permission.promptsOnFirstRequest {
            switch permission {
            case .input: model.requestInputPermission()
            case .control: model.requestAutomationPermission()
            case .screen: model.requestMusicScreenCapture()
            case .microphone, .speech: model.openPrivacySettings(permission.settingsAnchor)
            }
            check()
            return
        }
        requesting = true
        Task { @MainActor in
            switch permission {
            case .microphone: _ = await PushToTalk.requestPermission()
            case .speech:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
                }
            default: break
            }
            requesting = false
            check()
        }
    }
}
