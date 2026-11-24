# Orvio

**Turn a remote into a desktop control deck.**

Source available for noncommercial use under the PolyForm Noncommercial License 1.0.0. Commercial use is not granted by this license.

[简体中文](README.zh-CN.md) · [Noncommercial use only](LICENSE)

Orvio is a native macOS and Windows utility for remote-button mapping, music playback, display input switching, and Chinese voice commands. It supports T1 air-mouse receivers and Xiaomi RC003 Bluetooth remotes, with separate bindings for each device.

This is an actively developed source release. Hardware behavior depends on the remote, USB routing, display, and music-client version. Windows device-level native-key isolation still requires a compatible signed filter driver; mappings in the new isolated modes remain paused until that backend is available. See the detailed [usage and hardware notes](README.zh-CN.md).

## Features

- **Native, media, and host modes:** switch button groups with a learned mode key or a desktop shortcut.
- **Targeted music controls:** the selected player is the control target for playback, track changes, and mapped actions. Includes NetEase Cloud Music and Soda Music adapters.
- **Per-device key isolation on macOS:** suppress mapped keyboard/consumer actions on supported remote collections, and restore them in native mode or on exit. HID services are rediscovered after reconnects.
- **Dual-host switching:** display input control through BetterDisplay on macOS and DDC/CI APIs on Windows, with optional KMFU peripheral handoff.
- **Push-to-talk:** system speech recognition on macOS or a separately configured local Whisper CLI. Voice song search and music-window automation are experimental and verify visible results before reporting success.
- **Optional XiaoAI bridge:** Home Assistant and Bemfa MQTT integration for a configured Xiaomi speaker. Credentials are supplied locally.
- **Device guide:** interactive remote views and shared geometry assets for the T1 and Xiaomi RC003.

## Repository layout

| Path | Contents |
| --- | --- |
| `macos/Sources/T1Controller` | SwiftUI/AppKit application and settings |
| `macos/Sources/T1Core` | Commands, intent parsing, and gestures |
| `macos/Sources/T1Platform` | HID, audio, playback, display, and desktop automation |
| `windows/T1Controller` | WPF application and Windows adapters |
| `windows/T1Controller.Tests` | Portable command, mode, and routing tests |
| `shared` | Command contract, fixtures, and remote geometry |
| `tools` | Packaging, geometry export, XiaoAI/Bemfa bridge, and tests |

Internal target names, namespaces, application identifiers, and settings directories retain `T1Controller` for compatibility. The product name and new build outputs are **Orvio**. The T1 name in the device guide refers to the hardware.

## Build on macOS

Use Xcode with Swift 6.2 or newer and a macOS 26 SDK; the application deployment target is macOS 14. Liquid Glass is available on macOS 26 and newer, with system materials on earlier supported versions.

```sh
git clone https://github.com/suuyiiiiii-droid/orvio.git
cd orvio
swift test --package-path macos
swift build --package-path macos -c release --product Orvio
```

For an application bundle with permission descriptions and resources:

```sh
xcodebuild -project macos/T1Controller.xcodeproj \
  -scheme T1Controller -configuration Release \
  -derivedDataPath build/macos build
open build/macos/Build/Products/Release/Orvio.app
```

The universal packaging script includes the optional Python bridge and its MQTT dependency:

```sh
python3 -m pip install --target /private/tmp/orvio-paho paho-mqtt==2.1.0
bash tools/package_macos.sh /private/tmp/orvio-paho
```

Build outputs are written to `build/` and are excluded from Git. Local builds use ad-hoc signing; permissions may need refreshing after rebuilding. Use the application's permission guide to check input monitoring, accessibility, microphone, speech recognition, and screen capture for the features you use.

## Build on Windows

Use the .NET 10 SDK. Windows 11 x64 is the primary desktop/hardware test target.

```powershell
dotnet test windows/T1Controller.Tests/T1Controller.Tests.csproj -c Release
dotnet publish windows/T1Controller/T1Controller.csproj -c Release `
  -r win-x64 --self-contained true -o build/windows
.\build\windows\Orvio.exe
```

The pre-generated `shared/remote-models.json.gz` is included. To regenerate it from the macOS SceneKit models, run `bash tools/export_remote_models.sh` on a Mac.

For local speech recognition, install Whisper CLI and a multilingual model separately, then choose their paths in the voice settings. Model weights and third-party application installers are not part of this repository.

## Bridge tests

```sh
python3 -m pip install paho-mqtt==2.1.0
python3 -m unittest discover -s tools -p 'test_*.py'
```

See [XiaoAI and Bemfa setup](tools/README.md) for the optional speaker integration. Home Assistant tokens and Bemfa UID credentials belong in the local application inputs, never in source files or issues.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and hardware verification. Original Orvio software and project assets are distributed under **PolyForm Noncommercial 1.0.0**. This is a source-available license, not an OSI-approved open-source license. Third-party dependencies retain their own licenses. Reference projects and dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
