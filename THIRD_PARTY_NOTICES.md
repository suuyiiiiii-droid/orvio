# Third-party notices and references

Original Orvio code and assets are distributed under PolyForm Noncommercial 1.0.0; see [LICENSE](LICENSE). Dependencies keep their own license terms. The repository does not include the source or installers of NetEase Cloud Music, Soda Music, KMFU, BetterDisplay, Home Assistant, or Xiaomi applications.

## Reference projects

These are architecture, protocol, and interface references. Their licenses apply to their own code and assets; this repository's noncommercial terms do not relicense those projects or restrict rights granted by their licenses.

- **SayAll macOS / remote-mic-app**, Copyright (C) 2026 SayAll contributors. Referenced for remote-input architecture, gesture handling, and interface organization, at commit `00d78af8c7aef319e961a8a1b7b0b4dbc2936af2`. Its software is GPL-3.0-only. [Source](https://github.com/HD838A/remote-mic-app/tree/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2), [copyright](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/COPYRIGHT.md), [license](https://github.com/HD838A/remote-mic-app/blob/00d78af8c7aef319e961a8a1b7b0b4dbc2936af2/LICENSE.md).
- **SayAll Windows**, GPL-3.0-only. Referenced for platform-layer organization and public Windows API approaches. [Source at v1.9.0](https://github.com/GetSayAll/remote-mic-app-windows/tree/v1.9.0).
- **xiaoai-control-pc**. Referenced as an example of a XiaoAI-to-Bemfa computer-control workflow. [Source](https://github.com/Frequenk/xiaoai-control-pc).

Orvio uses its own application icon and procedurally constructed remote geometry. SayAll's proprietary application logos are not included. Hardware and third-party application names identify compatibility and do not imply affiliation.

## Dependencies

- **NAudio 2.2.1** — Windows audio APIs. [Source and license](https://github.com/naudio/NAudio). Restored through NuGet; dependency notices accompany its distribution.
- **Eclipse Paho MQTT Python 2.1.0** — optional MQTT bridge. [Source and license](https://github.com/eclipse-paho/paho.mqtt.python). The macOS packaging script includes the installed package's license and metadata with the bridge.
- **.NET test SDK, xUnit, and Visual Studio xUnit runner** — development/test dependencies declared in the test project; restored through NuGet.

Whisper CLI and speech models are configured separately by the user. BetterDisplay, KMFU, Home Assistant, and Xiaomi Home integration are external integrations and are not bundled as source dependencies.
