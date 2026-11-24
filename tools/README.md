# 小爱音箱和巴法接入

Home Assistant 是一个可在本地运行的智能家居服务。它通过小米官方集成，把 T1 转写后匹配到的固定指令交给小爱音箱执行。米家控制巴法开关后，Mac 会收到 MQTT 开启信号并播放每日推荐。语音在 Mac 转写，发送给 Home Assistant 的固定口令是「打开电脑音乐开关」。

1. 依照 [Home Assistant 的 macOS 安装指南](https://www.home-assistant.io/installation/macos/) 启动 Home Assistant OS。也可使用同一局域网内已有的 Home Assistant。
2. 安装 [小米官方 Xiaomi Home 集成](https://github.com/XiaoMi/ha_xiaomi_home/blob/main/doc/README_zh.md)，通过小米登录授权，选择音箱所在的地区和家庭。找到音箱的「执行文本指令」`notify.…` 实体。[L05C 规格](https://miot-spec.org/miot-spec-v2/instance?type=urn%3Amiot-spec-v2%3Adevice%3Aspeaker%3A0000A015%3Axiaomi-l05c%3A2)列出了文本和静默两个参数。可以先在 Home Assistant 的「开发者工具 → 动作」选择 `notify.send_message`，在消息栏填入 `["现在几点", false]`，确认音箱能回应。见[小米接入示例](https://github.com/XiaoMi/ha_xiaomi_home/wiki/Feed,-start-cooking,-play-text-and-execute-text-directive#execute-text-directive)。
3. 在巴法创建专用开关主题 `t1music006`。通过米家「我的 → 其他平台设备」绑定巴法并同步开关，取名「电脑音乐」。先直接对音箱说「打开电脑音乐开关」，确认米家开关会改变。初次测试前将它置于关闭。
4. 打开新版 macOS 安装包。在「语音 → 小爱同学」填入 Home Assistant 服务地址、`notify.…` 实体和主题。L05C 保留「发送『静默执行』参数」。Home Assistant 长期访问令牌和巴法 UID 只填入本机的安全输入框并点「存入钥匙串」。不要在聊天或日志里发凭据。需要可用的 Python 3.9 或更新版本，应用已包含 MQTT 依赖。
5. 在网易云客户端登录账号，在 T1「音乐」页确认辅助功能、屏幕录制权限。启用「以『小爱同学』开头时调用小爱音箱」，先点「测试小爱并播放」，再按住飞鼠语音键，说「小爱同学，打开网易云音乐，播放今日推荐」。核对状态栏有巴法信号、网易云进入每日推荐，且进度继续走动。测试期间关闭同 UID 的终端监听器，避免两个客户端互相断开。

T1 先核对音箱是否可用。对专用主题 `t1music006`，T1 通过[巴法设备 HTTPS 接口](https://cloud.bemfa.com/docs/src/api_device.html)发送 `off`。复位响应超时或异常时，T1 查询最新的云端状态，确认开关已关闭后才继续。T1 随后订阅 MQTT，订阅成功后发送小爱指令。等待超时后，T1 会检查小爱指令是否留下执行记录。测试时只用专门为 T1 创建的主题，等待期间手动打开同一个开关也会触发播放。

巴法订阅确认后，独立的回传等待窗口随即开始，Home Assistant 请求期间仍会接收 MQTT 消息。小爱指令每轮只提交一次，Home Assistant 没有回应时也会继续等待真实开启信号。若 Home Assistant 跑在本机 UTM，启动虚拟机后等小米集成的音箱实体恢复可用再运行。

本机已经授权的 0.1.7 通过 `t1_legacy_daily.py` 使用新版页面定位。桥接收到实时开启信号后，`T1DailyPreparation` 打开并确认每日推荐歌曲列表，再由原应用点击「播放全部」。桥接结果与页面准备结果分别记入运行目录的 `last-result.json` 和 `last-playback-prep.json`。

## 仅测试巴法 MQTT 监听

这个监听器在 Mac 终端里运行。它只订阅一个虚拟开关主题，收到实时的 `on` 后输出匹配结果并退出。带上 `--open-netease` 时，它会请 macOS 打开网易云音乐。该参数用于验证收到信号后的本机动作。

1. 在巴法 MQTT 控制台创建主题 `t1music006`。后缀 `006` 对应米家虚拟开关。
2. 在米家「我的 → 其他平台设备」添加「巴法」并同步主题。把开关命名为「电脑音乐」。
3. 在工作区根目录的 Mac 终端运行以下命令。监听器会提示输入巴法 UID 私钥，输入时不显示。

```sh
python3 -m venv /tmp/t1-bemfa-venv
/tmp/t1-bemfa-venv/bin/python -m pip install paho-mqtt==2.1.0
/tmp/t1-bemfa-venv/bin/python tools/bemfa_probe.py --topic t1music006
```

看到「已订阅」后，在巴法控制台向此主题发送 `on`，或在米家打开开关。小爱端可以对已绑定该米家家庭的小爱设备说「打开电脑音乐」。需要测试打开网易云时，在最后一条命令末尾加上 `--open-netease`。

虚拟开关只发送 `on` 或 `off`。要用它控制多首预设歌曲，可以为每首歌配置一个主题。口述歌名需要另一条能传递文本的链路。

参考 [巴法小爱接入](https://cloud.bemfa.com/docs/src/speaker_mi.html)、[巴法 MQTT 接入](https://cloud.bemfa.com/docs/src/mqtt.html) 和 [xiaoai-control-pc](https://github.com/Frequenk/xiaoai-control-pc)。
