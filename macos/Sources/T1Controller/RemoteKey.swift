import SwiftUI
import T1Core

enum RemoteFace: String, CaseIterable, Identifiable {
    case front = "正面", side = "侧面", rear = "背面"

    var id: Self { self }
    var yaw: Double {
        switch self {
        case .front: return -0.20
        case .side: return -.pi / 2 + 0.24
        case .rear: return -.pi + 0.13
        }
    }

    var keys: [RemoteKey] {
        switch self {
        case .front: return [.power, .up, .left, .ok, .right, .down, .back, .voice, .mute, .home, .air, .menu]
        case .side: return [.volumeUp, .volumeDown, .charge]
        case .rear: return [.typing, .keyboardModifiers, .keyboardArrows, .keyboardEdit]
        }
    }

    func keys(for profile: RemoteProfile) -> [RemoteKey] {
        guard profile == .xiaomi else { return keys }
        switch self {
        case .front: return [.power, .voice, .up, .left, .ok, .right, .down, .back, .volumeUp, .home, .volumeDown, .menu, .tv]
        case .side: return [.charge]
        case .rear: return []
        }
    }
}

enum RemoteKey: String, Hashable, Identifiable {
    case power, up, left, ok, right, down, back, voice, mute, home, air, menu
    case volumeUp, volumeDown, charge, typing, keyboardModifiers, keyboardArrows, keyboardEdit, tv

    var id: Self { self }
    var name: String {
        switch self {
        case .power: return "电源"
        case .up: return "上方向"
        case .left: return "左方向"
        case .ok: return "OK"
        case .right: return "右方向"
        case .down: return "下方向"
        case .back: return "返回"
        case .voice: return "语音"
        case .mute: return "静音"
        case .home: return "主页"
        case .air: return "空鼠"
        case .menu: return "菜单"
        case .volumeUp: return "音量＋"
        case .volumeDown: return "音量−"
        case .charge: return "USB-C"
        case .tv: return "TV"
        case .typing: return "字母与数字"
        case .keyboardModifiers: return "组合键"
        case .keyboardArrows: return "键盘方向键"
        case .keyboardEdit: return "编辑键"
        }
    }

    var icon: String {
        switch self {
        case .power: return "power"
        case .up: return "chevron.up"
        case .left: return "chevron.left"
        case .ok: return "circle.inset.filled"
        case .right: return "chevron.right"
        case .down: return "chevron.down"
        case .back: return "arrow.left"
        case .voice: return "mic.fill"
        case .mute: return "speaker.slash.fill"
        case .home: return "house.fill"
        case .air: return "cursorarrow.motionlines"
        case .menu: return "line.3.horizontal"
        case .volumeUp: return "plus"
        case .volumeDown: return "minus"
        case .charge: return "bolt.fill"
        case .tv: return "tv"
        case .typing: return "textformat.abc"
        case .keyboardModifiers: return "command"
        case .keyboardArrows: return "arrow.up.and.down.and.arrow.left.and.right"
        case .keyboardEdit: return "return"
        }
    }

    var candidate: KeyRole? {
        switch self {
        case .left: return .left
        case .right: return .right
        case .ok, .home: return .home
        case .voice: return .voice
        case .mute: return .mute
        case .menu: return .menu
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        default: return nil
        }
    }

    func represents(_ binding: KeyBinding?, profile: RemoteProfile = .t1) -> Bool {
        guard let binding else { return false }
        let usage = binding.control.uppercased().split(separator: ":").dropFirst().prefix(2).joined(separator: ":")
        if profile == .xiaomi { return xiaomiUsage == usage }
        switch self {
        case .left: return usage == "0007:0050" || usage == "000C:00B6"
        case .right: return usage == "0007:004F" || usage == "000C:00B5"
        case .ok: return ["0007:0028", "0007:0058", "0009:0001"].contains(usage)
        case .home: return usage == "000C:0223"
        case .voice: return usage == "000C:00CF"
        case .mute: return usage == "000C:00E2"
        case .menu: return usage == "0007:0065"
        case .volumeUp: return usage == "000C:00E9"
        case .volumeDown: return usage == "000C:00EA"
        default: return false
        }
    }

    private var xiaomiUsage: String? {
        switch self {
        case .power: "0007:0066"
        case .voice: "0007:003E"
        case .up: "0007:0052"
        case .down: "0007:0051"
        case .left: "0007:0050"
        case .right: "0007:004F"
        case .ok: "0007:0028"
        case .back: "0007:00F1"
        case .home: "0007:004A"
        case .menu: "0007:0065"
        case .volumeUp: "0007:0080"
        case .volumeDown: "0007:0081"
        case .tv: "0007:0035"
        default: nil
        }
    }

    var isXiaomiMappable: Bool { xiaomiUsage != nil && self != .power }

    func nativeAction(for profile: RemoteProfile) -> String {
        guard profile == .xiaomi else { return nativeAction }
        switch self {
        case .ok: return "确认／回车"
        case .voice: return "语音键／F5"
        case .power: return "遥控器电源"
        default: return nativeAction
        }
    }

    func guide(for profile: RemoteProfile) -> String {
        guard profile == .xiaomi else { return guide }
        switch self {
        case .power: return "电源键保留原生行为。"
        case .ok: return "OK 发送回车。可以在小米遥控器的按键映射里将它绑定为播放／暂停。"
        case .voice: return "蓝牙语音键上报为 F5。绑定后使用「语音控制」里选择的麦克风。配置前请检查前台应用的 F5 行为。"
        case .back, .volumeUp, .volumeDown, .tv: return "这个键使用小米的特殊键值。可在「按键映射」确认系统是否收到事件，再学习绑定。"
        case .charge: return "位于遥控器底端的 USB-C 充电接口。"
        default: return guide
        }
    }

    func labelPosition(for profile: RemoteProfile) -> (left: Bool, level: Double) {
        if profile == .xiaomi {
            let left: [RemoteKey] = [.power, .up, .left, .down, .back, .home, .menu]
            let right: [RemoteKey] = [.voice, .ok, .right, .volumeUp, .volumeDown, .tv, .charge]
            if let index = left.firstIndex(of: self) { return (true, 0.12 + Double(index) * 0.103) }
            if let index = right.firstIndex(of: self) { return (false, 0.12 + Double(index) * 0.103) }
        }
        return (labelOnLeft, labelLevel)
    }

    var nativeAction: String {
        switch self {
        case .power: return "电源／红外"
        case .up, .left, .right, .down: return "方向导航"
        case .ok: return "确认／左键"
        case .back: return "返回上级"
        case .voice: return "语音键"
        case .mute: return "静音键"
        case .home: return "主页键"
        case .air: return "体感光标"
        case .menu: return "菜单键"
        case .volumeUp: return "提高音量"
        case .volumeDown: return "降低音量"
        case .charge: return "充电"
        case .tv: return "电视快捷键"
        case .typing: return "文本输入"
        case .keyboardModifiers: return "修饰与功能层"
        case .keyboardArrows: return "移动光标"
        case .keyboardEdit: return "回车与删除"
        }
    }

    var guide: String {
        switch self {
        case .power: return "遥控器原生的电源控制。红外学习和红外设备控制由遥控器处理。"
        case .up, .down: return "保留原生方向键，用于菜单、列表或文本导航。"
        case .left, .right: return "在「按键映射」里启用绑定和媒体模式后，控制当前选择的音乐播放器。"
        case .ok: return "关闭空鼠后，OK 发送回车，可映射播放／暂停。开启空鼠时，OK 会发送鼠标左击。"
        case .back: return "保留飞鼠和当前应用的原生返回键行为。"
        case .voice: return "按住说出指令。麦克风来源、转写和小爱音箱接入在「语音控制」中设置。"
        case .mute: return "绑定开启时发送系统静音操作。系统数字音频设备可能不提供静音控制。"
        case .home: return "原生主页键。可以用它控制播放／暂停，也可以把这一项改绑到 OK。"
        case .air: return "切换遥控器的体感鼠标模式。模式变化也会改变 OK 上报的键值。"
        case .menu: return "启用后轻按切播放器。长按切主机需要先完成显示器和外设的切换配置。"
        case .volumeUp, .volumeDown: return "在「音乐控制」启用优先调整播放器音量，即可调整受支持播放器的内部音量。"
        case .charge: return "遥控器右侧的 USB-C 充电接口。"
        case .tv: return "遥控器的电视快捷键。"
        case .typing: return "背面的迷你键盘按常规键盘输入。数字和附加符号使用键帽标注的功能层。"
        case .keyboardModifiers: return "Ctrl、Shift、Alt、Caps 和 Fn 改变按键组合或切换键帽上标出的第二功能。"
        case .keyboardArrows: return "背面方向键用于导航和文本输入，键帽上也标有 Home、End 和翻页功能。"
        case .keyboardEdit: return "Esc、Back、Del 和 Enter 用于退出、编辑和确认。"
        }
    }

    var labelOnLeft: Bool {
        switch self {
        case .up, .left, .down, .back, .mute, .air, .typing, .keyboardModifiers: return true
        default: return false
        }
    }

    var labelLevel: Double {
        switch self {
        case .power: return 0.14
        case .up, .right: return 0.24
        case .left, .ok: return 0.34
        case .down, .voice: return 0.44
        case .back, .home: return 0.54
        case .mute, .menu: return 0.64
        case .air: return 0.74
        case .volumeUp: return 0.26
        case .volumeDown: return 0.42
        case .charge, .tv: return 0.76
        case .typing: return 0.30
        case .keyboardModifiers: return 0.67
        case .keyboardArrows: return 0.54
        case .keyboardEdit: return 0.72
        }
    }
}
