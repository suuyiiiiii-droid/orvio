# Orvio · 开发任务书

把整份文件交给 Codex，并在克隆后的项目根目录 开始执行。开发目标是在 macOS 和 Windows 上各运行一个常驻控制工具。用 T1 飞鼠切换音乐应用、播放或暂停、切歌、调音量，用同一个动作切换显示器和共享外设，再让按住语音键说出的中文指令调用同一套功能。

## 1. 已有证据

| 来源 | 已确认的内容 | 开发时要实测 |
| --- | --- | --- |
| `IMG_5405–5407.HEIC` 实拍 | 正面方向环、OK、返回、菜单、主页、语音、静音、空鼠和电源，侧边音量加减，背面 mini 键盘，Type-C 充电 | 每个按键在 Windows 和 macOS 实际上报的事件 |
| `IMG_5408–5412.HEIC` 说明书 | 封面型号 T1。支持 2.4G USB 接收器、蓝牙 `T1-Remote`、红外学习。语音描述为 16 kHz 谷歌语音助手。空鼠开时 OK 是左键，关时是 Enter。配对组合为 2.4G 的 OK＋返回、蓝牙的主页＋返回 | 语音键是否有独立按下和松开事件，麦克风数据是否能被电脑读取，两个连接方式的能力差异 |
| 本机 KMFU | 枚举到沁恒 `1A86:8020` KMFU、`1A86:8022` KMFU HID、`1A86:8026` KMFU CDROM。KMFU HID 暴露键盘、鼠标和消费控制。已安装官方 KMFU 1.9.0，其中文界面资源有快捷键切换和端口跟随设置 | T1 经 Hub 后能否与普通键鼠区分。KMFU 热键能否由应用触发，键鼠、音响及接收器分别如何跟随 |
| 本机显示器和音乐应用 | 读到了 `JQ27F360L` 与 `T16KD` 两个 EDID 名称。已安装 BetterDisplay 5.2.1 和网易云音乐 3.1.12，网易云 bundle ID 为 `com.netease.163music` | 哪台是两台电脑共用的显示器、两边接的是哪个物理口、DDC/CI 是否支持双向输入切换、当前网易云版本能否通过系统辅助功能操作每日推荐 |

KMFU V1.9 手册第 2 页说明 Windows 支持自定义键鼠切换快捷键。第 18 页的 macOS 章节描述了边缘、鼠标等操作，已安装的 macOS 版另有快捷键相关文案，需实测其可用性。第 19 页描述了 P1/P2/P3 端口的独立切换。手册中的屏幕共享是软件投屏。附件是硬件参考资料，按本任务书确定实现范围。 [沁恒 CH9338 资料](https://www.wch.cn/downloads/CH9338DS1_PDF.html)

本轮用 GitHub 连接器读取固定版本源码，通过 Craft Anything 给其中 10 个文件建立索引，并静态检查了本机 KMFU 的 Mach-O 和偏好设置资源。当前会话缺少可调用的 REA 入口。T1 按键与录音、DDC 写入、KMFU 交接及网易云播放均列入后续实机验证。

### SayAll 的借鉴范围

- macOS 参考 [固定提交 `00d78af8`](https://github.com/HD838A/remote-mic-app/commit/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2)。借鉴按设备身份匹配 HID、独立手势状态机、按键透传与重复触发处理。其监听匹配小米 VID/PID `2717:32B8`，报告解析也基于小米格式。T1 配置由采样生成。 [HIDRemoteMonitor.swift](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/Sources/RemoteMic/HIDRemoteMonitor.swift#L419-L465) · [RemoteButtonGestureRecognizer.swift](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/Sources/RemoteMic/RemoteButtonGestureRecognizer.swift)
- SayAll 的小米语音桥会协商 ATVV、解码 IMA ADPCM 并输出 PCM。借鉴会话生命周期、按下即录音和断连清理。T1 的音频来源与协议以实测为准。SayAll 启动或聚焦网易云、派发系统媒体事件的实现只覆盖通用播控，每日推荐另做。 [小米语音桥](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/Sources/RemoteMic/XiaomiBluetoothBridge.swift#L938-L1139) · [媒体事件](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/Sources/RemoteMic/KeyboardInjector.swift#L2883-L2924)
- Windows 参考官方姊妹仓库 `v1.9.0` 的 Raw Input、WinRT、WASAPI 与纯协议逻辑分层。新项目按公开 API 独立实现。若后续选用上游代码，按 GPL-3.0-only 核对衍生项目与分发义务，并单独核对品牌和素材许可。 [Windows 技术文档](https://github.com/GetSayAll/remote-mic-app-windows/blob/v1.9.0/TECHNICAL.md) · [Windows 许可证声明](https://github.com/GetSayAll/remote-mic-app-windows/blob/v1.9.0/Cargo.toml) · [Mac 版权说明](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/COPYRIGHT.md)

## 2. 产品和键位

做简体中文菜单栏应用（macOS）和系统托盘应用（Windows）。首屏显示当前主机、T1 连接方式、目标播放器、实际录音输入，以及画面和外设各自的切换状态。设置提供「学习按键」「切换校准」「语音试录」和一键恢复默认映射。每个键可设为透传或映射。首次启动先连接和学习，按键按下、松开、原生行为验证通过才启用推荐预设。

| 实体键与手势 | 推荐预设 | 启用条件 |
| --- | --- | --- |
| 菜单短按 | 按配置列表循环选择音乐应用，并启动或聚焦选中应用 | 能区分短按与长按，原菜单行为无冲突。列表默认只加入已识别的网易云音乐，其余由用户添加 |
| 菜单长按约 800 ms 后松开 | 切换至另一台主机 | 已完成双向校准，当前目标可判定。长按执行一次并取消短按 |
| 主页短按 | 播放 / 暂停当前选中的播放器 | 识别唯一按键且无系统主页动作冲突 |
| 左 / 右方向键 | 上一曲 / 下一曲 | 仅在用户开启媒体模式时启用，普通模式方向键透传 |
| 侧键音量＋ / −、正面静音 | 控制当前主机的输出音量与静音 | 已有原生行为时只透传。数字输出不可调时显示原因，可显式改用播放器音量 |
| 语音键按住、松开 | 按下开始收音，松开识别并执行 | 两个事件都可靠时启用。否则提供自选电脑快捷键或托盘按住说话 |
| 电源、空鼠、OK、返回、上下方向、背面键盘 | 原生操作 | 保留配对、光标档位、红外学习、休眠唤醒和翻面操作 |

给播放、切歌、音量、选择播放器和切换主机提供托盘按钮与可选全局快捷键，便于没有飞鼠时测试。菜单键或主页键与系统默认动作冲突时，提示学习另一颗无冲突按键。用于持续按住的键优先验证释放事件，连续音量步进有明确的限速，切主机键无自动连发。

## 3. 工程结构与实现顺序

在 `macos/` 用 Swift 和 SwiftUI 实现菜单栏壳及平台适配器，核心逻辑放可独立运行测试的 Swift Package。先以当前 Apple Silicon Mac mini 为 macOS 首测环境。在 `windows/` 用 C#、.NET 10 和 WPF 实现托盘壳，首测 Windows 11 x64。用 `shared/` 的版本化 JSON schema 和同一组输入、动作测试数据约束两端行为。落地 `README.md`、构建入口、配置迁移和本机诊断流程。保留系统托盘退出和停用重映射的入口。

### 阶段 A · 设备诊断和音乐

1. 先做仅在诊断窗口启动的 `HID Probe` 与音频电平测试。每台主机分别测试 T1 蓝牙直连、2.4G 接收器直连、2.4G 经过 KMFU。记录设备名、VID/PID、传输、集合、Usage Page/Usage、Report ID、按下/释放/重复、原生行为、休眠重连以及语音键按住时的输入端点和电平。按键数据仅采已选设备和必要字段。用两端各自实测的设备指纹匹配，热插拔时重建句柄，失联清理按键状态。KMFU 合并设备无法区分来源时，只启用已验证的无冲突触发键，或提示改走接收器直连 / 蓝牙。
2. macOS 通过 `IOHIDManager` 观察设备和报表，按需引导输入监控授权。Windows 通过 Raw Input 接收 `WM_INPUT`、设备到达及移除。Windows 的 `RIDEV_NOLEGACY` 对注册应用生效，不能作为全局按设备拦截。只有验证能选择性抑制该设备的该键时才替换原生事件。不要对混合 KMFU 设备做独占抓取。 [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h) · [微软 RAWINPUTDEVICE](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-rawinputdevice#remarks)
3. 将按键标准化为 `deviceId, control, down/up, monotonicTime`，手势层输出强类型动作。按钮、快捷键和语音都调同一个 `ActionDispatcher`。配置保存设备匹配条件、连接方式、键位、播放器列表、主机和输入源映射，原子写入。动作状态至少区分「已确认」「已发出但未确认」「部分完成」「不可用 / 失败」。
4. 播放器切换时启动或激活已配置应用，并更新当前目标。Windows 用 GSMTC 匹配目标会话，支持时调用播放、暂停、上一曲、下一曲。macOS 通过 `NSWorkspace` 启动应用，用已验证的 app 快捷键或 Accessibility 菜单适配目标播放器。Windows 可对无 GSMTC 的应用采用已校验的应用快捷键。只有用户启用全局媒体键兼容模式时才发系统媒体键，并显示目标可能由系统决定。音量操作指向当前音频输出，macOS 监听 Core Audio 默认输出变化，Windows 用 `IMMNotificationClient` 重新绑定 `IAudioEndpointVolume`，覆盖 Hub 切换后的音响重新枚举。 [GSMTC](https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssession) · [Windows 音频设备变更](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient)

### 阶段 B · 双主机切换

实现 `DisplayInputBackend`、`HubRouteBackend` 与 `SwitchCoordinator`。同一个动作可明确指定 Windows 或 Mac。菜单键的「切到另一台」在当前归属无法确认或画面与外设分离时，改为显示两个明确目标和恢复入口。

1. **校准画面。** 设置页选中两台主机共用的显示器并记录显示器身份、两端的接口与线缆、当前输入源。打开显示器 OSD 中的 DDC/CI（如果有）。Windows 用 Dxva2 的 `GetPhysicalMonitorsFromHMONITOR`、`GetVCPFeatureAndVCPFeatureReply`、`SetVCPFeature` 并释放句柄。macOS 优先验证已安装 BetterDisplay 的官方 CLI。按实际连接路径探测 VCP `0x60` 的读取和写入，再用 OSD、读回或目标端可见画面核对两边数值。把两端可访问的路径记入配置，逐项验证在另一输入已激活时还能否读写。显示器、线缆、转接器、端口可能影响结果。 [Windows DDC/CI](https://learn.microsoft.com/en-us/windows/win32/monitor/using-the-low-level-monitor-configuration-functions) · [BetterDisplay CLI](https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI) · [Apple Silicon DDC 工具参考](https://github.com/waydabber/m1ddc)
2. **校准外设。** 在两端官方 KMFU 中先手动测试已配置的切换快捷键，记录 A/B 主机角色和接收器、音响所用的端口。逐个验证键鼠切换后接收器、音响的跟随选项和实际归属。再验证从应用发出相同快捷键能否切换，包括 macOS 辅助功能权限及 Windows 在正常桌面的权限层级。优先使用已证实可调用的厂商接口或快捷键，保存能力及限制。合成热键无效时，可实测官方界面中带明确目标的可访问控件。只有手动操作有效时，提供手动 KMFU 步骤和可独立使用的显示器切换。
3. **协调一次操作。** 单次操作带目标和操作 ID，同一时间只允许一次切换。优先尝试在源主机的显示通道仍可用时提交并核验 DDC，再发外设交接。若实测画面先切会丢控制，按校准结果调整顺序或用能独立访问显示器的已验证路径。画面与键鼠、接收器和音响分别记录状态。热键只有翻转语义时，必须有可验证的起始归属，超时后先查询，禁止盲目补发导致切回。接收器或音响重枚举后刷新状态。失败时提供单独补做失败项、KMFU 手动切换、显示器 OSD 恢复。可先让用户在向导中确认画面及外设实际归属，软件无读回时显示「已发出，待确认」。如双向确需对端协助，才加配对的同网段组件，只允许协商、切换、读回这些固定操作。

## 4. 语音和网易云每日推荐

1. **接通收音。** 首选已经证实能提供有效 PCM 的 T1 录音路径。先枚举系统 USB / 蓝牙输入端点，用 macOS AVAudioEngine、Windows WASAPI 读音频并重采样给识别器。若仅有厂商传输，先确认 T1 的公开或设备实测协议，再实现专用解码。仍无音频时优先保留 T1 语音键作为触发，改用用户选择的主机麦克风，并在界面显示实际来源。若按键本身也不可见，则使用已学习的替代键或托盘录音入口。
2. **按住说话。** 有效按下立即开始缓冲，录音时显示状态，松开结束并识别。用 15 秒作为初始上限，超时、撤销、设备掉线或丢释放事件时结束会话，异常取消不执行命令。音频默认只驻留内存。首版用本地多语种 `whisper.cpp` 模型识别中文，记录模型版本、大小和校验值。允许把「小爱同学」「你好飞鼠」作为句首称呼去掉，按键本身负责唤醒。 [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
3. **识别意图并调用动作。** 首版用短语和同义词匹配到白名单动作，接受文本直接测试同一条执行路径。「播放 / 暂停」「上一首 / 下一首」「切换音乐软件」「音量调到 35%」「打开网易云音乐」「切到 Windows / Mac」映射到固定动作。播放和暂停分别执行指定状态，只有物理播放键使用翻转动作。语义不确定时显示转写并请用户选择。自然语言模型可以后续作为结构化意图解析器，输出仍由同一个动作层校验并执行。
4. **每日推荐单独实现。** 「小爱同学，帮我打开网易云音乐，播放今日推荐的歌曲」解析成 `PlayDailyRecommendations(app: netease)`。启动或聚焦已安装的官方客户端，等待目标窗口和已有登录态，识别「每日推荐」「每日歌曲推荐」等该版本的语义控件，进入后触发「播放全部」或等价控件。macOS 用 `AXUIElement`，Windows 用 UI Automation，并按客户端版本和语言维护选择器，先验证控件属于目标进程且唯一。验证已进入目标页面，并用播放状态或曲目变化确认结果。若 UI 未暴露控件，只使用实际验证可用的应用接口或导航方式。页面未找到、需登录、版本不匹配或播放状态无法确认时，回报具体阶段，保留已打开的应用供用户接续。 [macOS Accessibility](https://developer.apple.com/documentation/applicationservices/axuielement_h) · [Windows UI Automation](https://learn.microsoft.com/en-us/windows/desktop/winauto/entry-uiauto-win32)

## 5. 验收与交付

| 场景 | 通过条件 |
| --- | --- |
| 设备和键位 | 分别记录两端每种连接方式的真实键位。普通键鼠、空鼠移动、OK、返回、背面键盘及音量键行为正常。长按和短按各执行一次。覆盖睡眠唤醒、拔插、权限变化、KMFU 交接和重启后的配置恢复 |
| 音乐 | 循环选择已安装的播放器；所选播放器实际播放、暂停、上一曲、下一曲；系统音量或配置的播放器音量可核验。验证两个播放器同时运行时动作仍指向正确目标。音响切换回来后音量能继续控制 |
| 一键切主机 | 分别执行 Windows → Mac 和 Mac → Windows，每方向连续 10 次。逐次记录画面、键盘、鼠标、音响、接收器，五项都到目标主机才记整机切换通过。模拟目标主机睡眠、DDC 不支持、USB 枚举超时和其中一项失败，检查恢复入口和无重复翻转 |
| 按键语音 | 按下开始、松开停止。用实际飞鼠麦克风或清楚标明的主机麦克风实测中文音乐和切换主机指令，覆盖短按、静音、丢释放、断连和识别不确定。验证任意单条指令只执行一次 |
| 网易云每日推荐 | 每个通过的平台都用已登录的官方客户端，从冷启动和已运行分别测试，记录客户端版本、目标页面和实际播放结果。覆盖未登录、未找到控件与超时。仅启动网易云时记「启动通过」 |

交付两端源码、可本地运行的 macOS `.app` 和 Windows 可执行构建、构建命令、配置示例、测试结果、T1 诊断矩阵和双向切换记录。核心测试覆盖按键时序、去重、断连恢复、配置迁移、切换部分成功、语音指令参数及动作派发。macOS 在本机完成构建和可测项目。Windows 在实际 Windows 环境或 Windows CI 构建，再到用户的 Windows 主机完成设备与桌面行为验证。若部分硬件或权限暂不可用，继续交付可运行的诊断、音乐控制与已验证的降级路径，在验收表中写清具体缺项及所需操作。平台构建、模拟测试、真机通过各自记录。

创建工程时固定下列入口，并在对应环境从工作区根目录跑通。Windows 安装包可在应用完成后按分发需求另做。

```sh
# macOS
swift test --package-path macos
xcodebuild -project macos/T1Controller.xcodeproj -scheme T1Controller -configuration Release -derivedDataPath build/macos build
```

```powershell
# Windows
dotnet test windows/T1Controller.sln -c Release
dotnet publish windows/T1Controller/T1Controller.csproj -c Release -r win-x64 --self-contained true -o build/windows
```
