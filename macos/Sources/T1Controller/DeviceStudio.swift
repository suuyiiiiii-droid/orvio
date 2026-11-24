import SwiftUI
import T1Core
import T1Platform

struct DeviceStudio: View {
    @ObservedObject var model: ControllerModel
    let openMappings: (RemoteProfile) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var face = RemoteFace.front
    @State private var selected = RemoteKey.ok
    @State private var pose = RemotePose(yaw: RemoteFace.front.yaw, pitch: 0.025)
    @State private var dragging = false
    @State private var anchors: [RemoteKey: CGPoint] = [:]
    @State private var profile = RemoteProfile.t1

    private var faces: [RemoteFace] { profile == .xiaomi ? [.front, .side] : RemoteFace.allCases }
    private var shownKeys: [RemoteKey] { face.keys(for: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设备导览")
                        .font(.system(size: 34, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(profile == .xiaomi ? "小米蓝牙遥控器 2 Pro · RC003" : "T1 空中飞鼠")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                connectionStatus
            }
            Picker("遥控器型号", selection: $profile) {
                ForEach(RemoteProfile.allCases) { device in Text(device.rawValue).tag(device) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("遥控器型号")
            .frame(maxWidth: 350)
            HStack(alignment: .top, spacing: 17) {
                stage
                VStack(spacing: 15) {
                    inspector
                    mappingSummary
                }
                .frame(width: 214)
            }
        }
        .onChange(of: profile) { _, _ in
            anchors.removeAll()
            switchFace(to: .front)
        }
    }

    private var directConnected: Bool { model.devices.contains(where: \.isDirectT1Receiver) }

    private var connectionStatus: some View {
        let connected = profile == .xiaomi ? !model.xiaomiDevices.isEmpty : directConnected
        let detail = profile == .xiaomi
            ? (connected ? "小米遥控器已连接" : "小米遥控器未检测到")
            : (connected ? "T1 接收器已连接" : model.deviceSummary)
        return HStack(spacing: 8) {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(detail)
                .lineLimit(1)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .t1Glass()
    }

    private var stage: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                stageSurface
                RemoteRender(
                    profile: profile, pose: pose, selected: selected, pressed: pressedKey, animate: !reduceMotion && !dragging,
                    onProjection: { anchors = $0 },
                    onSelect: selectKey,
                    onDrag: rotate,
                    onDragEnd: settle
                )
                .id(profile)
                .accessibilityHidden(true)
                if !dragging {
                    calloutLines
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    ForEach(shownKeys) { key in
                        let layout = key.labelPosition(for: profile)
                        keyLabel(key)
                            .position(x: layout.left ? 70 : size.width - 70, y: size.height * layout.level)
                    }
                }
                VStack(spacing: 0) {
                    Spacer()
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "arrow.trianglehead.clockwise.rotate.90").font(.system(size: 10))
                        Text("拖动旋转")
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption2.weight(.medium))
                    .allowsHitTesting(false)
                    .padding(.bottom, 8)
                    facePicker
                        .padding(.bottom, 15)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay {
                RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.77))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 510)
        .shadow(color: .black.opacity(0.07), radius: 19, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.rawValue)三维按键导览")
    }

    private var stageSurface: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(LinearGradient(colors: [
                T1Design.accent.opacity(colorScheme == .dark ? 0.22 : 0.10),
                Color.cyan.opacity(colorScheme == .dark ? 0.09 : 0.05),
                .clear
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            RadialGradient(colors: [
                Color(nsColor: .white).opacity(colorScheme == .dark ? 0.11 : 0.86),
                .clear
            ], center: .init(x: 0.48, y: 0.38), startRadius: 0, endRadius: 295)
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.49)
                for radius in [104.0, 158.0, 217.0, 284.0] {
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(T1Design.accent.opacity(0.085)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var calloutLines: some View {
        Canvas { context, size in
            for key in shownKeys {
                guard let anchor = anchors[key], (8...size.width - 8).contains(anchor.x),
                      (8...size.height - 85).contains(anchor.y) else { continue }
                let layout = key.labelPosition(for: profile)
                let left = layout.left
                let endX = left ? 124.0 : size.width - 124
                let labelY = size.height * layout.level
                let isActive = key == selected || key == pressedKey
                let tint = isActive ? T1Design.accent : T1Design.accent.opacity(0.39)
                var line = Path()
                line.move(to: CGPoint(x: endX, y: labelY))
                line.addLine(to: CGPoint(x: endX + (left ? 11 : -11), y: labelY))
                line.addLine(to: anchor)
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: isActive ? 1.4 : 0.8, lineCap: .round, lineJoin: .round))
                let size = isActive ? 6.0 : 4.0
                context.fill(Path(ellipseIn: CGRect(x: anchor.x - size / 2, y: anchor.y - size / 2, width: size, height: size)),
                             with: .color(tint))
            }
        }
    }

    private func keyLabel(_ key: RemoteKey) -> some View {
        let current = key == selected
        let held = key == pressedKey
        return Button { selectKey(key) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(key.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(current || held ? T1Design.accent : Color.primary)
                Text(action(for: key))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 108, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8)
                shape.fill(.regularMaterial)
                if current || held { shape.fill(T1Design.accent.opacity(held ? 0.24 : 0.12)) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(current || held ? T1Design.accent.opacity(0.44) : .white.opacity(0.35))
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(key.name)，\(action(for: key))")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var facePicker: some View {
        HStack(spacing: 1) {
            ForEach(faces) { candidate in
                Button { switchFace(to: candidate) } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11, weight: face == candidate ? .semibold : .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .foregroundStyle(face == candidate ? T1Design.accent : Color.secondary)
                        .background {
                            if face == candidate { Capsule().fill(T1Design.accent.opacity(0.13)) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(face == candidate ? .isSelected : [])
                .accessibilityLabel("查看\(candidate.rawValue)")
            }
        }
        .padding(4)
        .t1Glass()
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: selected.icon)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(T1Design.accent)
                    .frame(width: 49, height: 49)
                    .background(T1Design.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                Spacer()
                Text(status(for: selected))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T1Design.accent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(T1Design.accent.opacity(0.11), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(selected.name).font(.system(size: 25, weight: .semibold))
                Text(action(for: selected)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T1Design.accent)
            }
            Text(selected.guide(for: profile))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if profile == .xiaomi ? selected.isXiaomiMappable : selected.candidate != nil {
                Button { openMappings(profile) } label: {
                    HStack {
                        Text("配置按键")
                        Image(systemName: "arrow.right").imageScale(.small)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.82) : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(T1Design.accent, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("配置按键")
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .t1Panel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选按键功能")
    }

    private var mappingSummary: some View {
        let count = bindings.values.filter(\.enabled).count
        return VStack(alignment: .leading, spacing: 13) {
            Text("映射状态").font(.system(size: 13, weight: .semibold))
            Divider().opacity(0.65)
            stateLine("当前模式", value: model.remoteModeTitle, icon: "keyboard")
            stateLine("已启用绑定", value: "\(count) 项", icon: "checkmark.circle")
            stateLine("当前播放器", value: model.currentPlayerName, icon: "play.circle")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .t1Panel()
    }

    private func stateLine(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 13).foregroundStyle(T1Design.accent)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Text(value).fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }

    private var bindings: [String: KeyBinding] {
        profile == .xiaomi ? model.prefs.xiaomiBindings : model.prefs.bindings
    }

    private func mapping(for key: RemoteKey) -> (role: KeyRole, binding: KeyBinding)? {
        let candidates = KeyRole.allCases.compactMap { role -> (role: KeyRole, binding: KeyBinding)? in
            guard let binding = bindings[role.rawValue], key.represents(binding, profile: profile) else { return nil }
            return (role, binding)
        }
        return candidates.first { $0.binding.enabled && model.allowsRemoteRole($0.role) } ?? candidates.first
    }

    private func action(for key: RemoteKey) -> String {
        let native = key.nativeAction(for: profile)
        guard let mapped = mapping(for: key), mapped.binding.enabled, model.allowsRemoteRole(mapped.role) else { return native }
        if model.needsNativeIsolation(mapped.binding) { return native }
        if model.prefs.remoteMode == nil && (mapped.role == .left || mapped.role == .right) && !model.prefs.mediaMode { return native }
        switch mapped.role {
        case .cycleMode: return "循环切换模式"
        case .menu: return model.prefs.remoteMode == nil ? "切换播放器／主机" : "切换播放器"
        case .switchHost: return "切换主机"
        case .home: return "播放／暂停"
        case .left: return "上一曲"
        case .right: return "下一曲"
        case .volumeUp: return "提高音量"
        case .volumeDown: return "降低音量"
        case .mute: return "切换系统静音"
        case .voice: return "按住说话"
        }
    }

    private func status(for key: RemoteKey) -> String {
        guard let mapped = mapping(for: key) else { return "原生功能" }
        if !mapped.binding.enabled { return "映射已暂停" }
        if !model.allowsRemoteRole(mapped.role) { return "当前模式未使用" }
        if model.needsNativeIsolation(mapped.binding) { return model.nativeBindingStatus(mapped.binding) }
        if model.prefs.remoteMode == nil && (mapped.role == .left || mapped.role == .right) && !model.prefs.mediaMode { return "左右键切歌关闭" }
        return model.permission == .granted ? "映射开启" : "已绑定"
    }

    private var pressedKey: RemoteKey? {
        guard let role = profile == .xiaomi ? model.activeXiaomiKeyRole : model.activeKeyRole else { return nil }
        return shownKeys.first { mapping(for: $0)?.role == role }
    }

    private func selectKey(_ key: RemoteKey) {
        guard shownKeys.contains(key) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selected = key }
    }

    private func switchFace(to target: RemoteFace) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            dragging = false
            face = target
            pose = RemotePose(yaw: target.yaw, pitch: 0.025)
            if !target.keys(for: profile).contains(selected) {
                switch target {
                case .front: selected = .ok
                case .side: selected = profile == .xiaomi ? .charge : .volumeUp
                case .rear: selected = .typing
                }
            }
        }
    }

    private func rotate(_ horizontal: CGFloat, _ vertical: CGFloat) {
        dragging = true
        let minimumYaw = profile == .xiaomi ? -2.05 : -.pi - 0.13
        pose.yaw = min(0.40, max(minimumYaw, pose.yaw + Double(horizontal) * 0.012))
        pose.pitch = min(0.36, max(-0.36, pose.pitch + Double(vertical) * 0.009))
    }

    private func settle() {
        let face: RemoteFace = pose.yaw > -0.72 ? .front : (pose.yaw > -2.18 ? .side : .rear)
        switchFace(to: face)
    }
}
