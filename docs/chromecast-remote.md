# Chromecast Remote on macOS

## Verified hardware and cause

On 2026-11-26 the connected device identified as `Chromecast Remote`, manufacturer
`zhuhai_jieli`, Bluetooth LE, VID/PID `18D1:9450`, version `0x011B`.
Its descriptor declares report 2 as a 16-bit consumer usage plus an 8-bit numeric
button field (three bytes). The remote sends only two bytes. A shared-mode native
IOHID observer opened successfully with input permission, but received neither
value nor raw-report callbacks for Up, OK, or Back.

After the scoped logging override was installed, BTLEServer showed:

| Physical button | Consumer payload | Release |
| --- | --- | --- |
| Up | `42 00` | `00 00` |
| OK | `41 00` | `00 00` |
| Back | `24 02` | `00 00` |
| Power | `9E 01` (`0x019E`) | `00 00` |
| Input source | `89 01` (`0x0189`) | `00 00` |

These are hardware/transport observations, not a claim that all application
actions or every physical button has passed acceptance.

## Orvio integration

Select **按键映射 → Chromecast**, enable **0x011B 蓝牙短报文兼容**, and optionally
apply the media preset. OK controls playback, Left/Right change tracks, volume
buttons use the existing volume preference, Home cycles modes, and Back switches
hosts in host mode. Player actions use the selected player, never a broadcast
system media key. Existing T1 and Xiaomi bindings remain separate.

All standard role mappings can be learned again. **基础按键修复与自定义** changes
the fallback action of each consumer button. Active mode mappings take priority;
a reserved mode key does not leak Return when its action is inactive in another
mapped mode. Native navigation is sent to the app that was foreground at press
time, only if it remains foreground at release. Missing releases, sleep, device
removal, disabled compatibility and log termination cancel held gestures.

The bridge only parses two-byte consumer report 2 and never logs raw payloads to
application files. Keyboard, vendor and audio logs are ignored. A valid native
report takes priority and disables log input for that connection.

### Source attribution limit

BTLEServer's report message contains no peripheral identifier. The bridge
therefore requires exactly one affected Chromecast collection and its expected
24-bit descriptor. An unknown Bluetooth descriptor, a second target, or another
Bluetooth HID declaring report 2 of at most three bytes pauses compatibility.
This Mac's two Bluetooth mice declare eight-byte report 2; their correctly sized
reports cannot match the two-byte parser. This is length/topology validation,
not an authenticated per-device transport. A second device with its own broken,
unexpectedly truncated report could still be ambiguous; disconnect it and do not
use the compatibility transport in that configuration.

## System logging configuration

The supplied third-party executable is not bundled or executed. Its broad
`DEFAULT-OPTIONS` profile was replaced by a category-only configuration.

The category-only mobileconfig appeared in Managed Preferences but live payloads
remained `<private>` on this Mac. Installing the same category dictionary at
Apple's documented subsystem path made **new** payloads readable:

`/Library/Preferences/Logging/Subsystems/com.apple.bluetooth.plist`

The settings are only for `com.apple.bluetooth / BTLEServer`, with Debug enabled,
`Persist=Off`, `Default-Privacy-Setting=Public`, and `Enable-Private-Data=true`.
There is no `DEFAULT-OPTIONS` or system-wide private-data setting. Other BLE
devices' private data in this category can also become readable. `Persist=Off`
does not promise that no other system diagnostic mechanism ever writes data.

The installer used for this local verification has no executables or scripts.
It installs only that plist. Disabling Orvio's listener does **not** remove the
system logging configuration. On this Mac the target plist did not previously
exist. To remove the override after ending compatibility use, an administrator
can remove that file and the `Orvio · Chromecast 蓝牙短报文兼容` profile in
System Settings → General → Device Management. Do not remove an entire shared
subsystem plist on another Mac without preserving its unrelated settings.

The exact standalone category dictionary is tracked at
`macos/Resources/ChromecastBTLELogging.plist` for review and reproducibility. It
is not installed automatically by Orvio and requires explicit system approval.

## ATVV voice

The Google Assistant button and microphone use a separate ATVV GATT service.
Orvio now has an opt-in CoreBluetooth client, PnP verification of `18D1:9450`,
control/audio notification subscriptions, capability negotiation, bounded ADPCM
decoding, start/stop feedback, and direct local recognition. No virtual audio
driver is installed. Only a physical button start or its corresponding on-request
stream is accepted. Disconnects, application exit, audio gaps and the 15-second
limit close/cancel capture instead of executing incomplete commands.

On 2026-11-26 this Mac negotiated ATVV 1.0 at 16 kHz with the remote. A physical
voice-button test delivered 139 audio notifications (2.22 seconds of decoded
audio), followed by a stop notification on release. Local recognition returned
the requested phrase `窗外有三只蓝色的小鸟`. A subsequent test of the final
candidate delivered 118 audio notifications, recognized `下一曲`, reported the
remote microphone stopped, and changed Soda Music from `的青春 — 贰佰` to
`风车 — 南青乐队`; the player displayed its pause icon (playing). The application
permission guide detected all six requested permissions after the current app
was re-added and fully restarted. Audio delivery on this remote can begin later than the initial
button notification; wait for the receiving-audio indicator before speaking.

In native mode, this ATVV transcript is inserted into the editable control that
was focused at voice start; it never enters the command dispatcher. A changed
focus/selection cancels insertion and leaves the transcript in Orvio. Native
audio compatibility sends system media keys; media mode continues to target the
player selected in Orvio. Existing base overrides and learned bindings remain.
T1 and Xiaomi native voice keys are left to macOS instead of starting a second
application recorder. These routing changes have automated coverage. On November 27, native-mode
dictation was also confirmed in TextEdit and Codex using system keyboard events;
the earlier physical ATVV command test above predates that repair. See the
[November 27 acceptance record](update-2026-11-27.md).

The codec/protocol implementation adapts MI-AO's MIT-licensed modules, preserving
their copyright and license; see `THIRD_PARTY_NOTICES.md`.

## Not yet supported/accepted

- This particular `0x011B` unit reports Power and Input over Bluetooth (`0x019E` / `0x0189`), verified in a physical Up → Power → Input → Up sequence. Both codes must be admitted by the consumer decoder and exposed as mappable keys. Other hardware/configurations may use infrared, but that was not the cause on this unit.
- Power and Input have no default action. Learning maps the physical buttons to existing roles; detecting a Power button does not request macOS shutdown.
- 0x0110 report-index variants are not decoded by this 0x011B compatibility path.
- Physical buttons beyond those listed above require direct observation and
  application acceptance before being described as verified.

## References

- [Apple: configuring logging by subsystem/category](https://developer.apple.com/documentation/os/customizing-logging-behavior-while-debugging)
- [Apple: logging configuration profile schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.system.logging.yaml)
- [Independent hardware observations](https://github.com/zfdang/remote-buddy/blob/v26-11-22.957/docs/g9n9n-hardware-debugging.md)
- [OpenClaw's scoped subsystem configuration procedure](https://github.com/openclaw/openclaw/blob/main/docs/platforms/mac/logging.md)

The HID/log compatibility transport was independently implemented. No third-party
executable or GPL implementation code was copied into Orvio. The reused MIT
codec/protocol files are identified separately above.
