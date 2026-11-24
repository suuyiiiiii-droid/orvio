# Contributing to Orvio

Changes should preserve device-specific routing and make failures observable. A submitted command is not proof that a player started: inspect the selected application, song, and playback state before recording a successful hardware test.

## Checks

Run the checks appropriate to your change:

```sh
swift test --package-path macos
python3 -m unittest discover -s tools -p 'test_*.py'
dotnet test windows/T1Controller.Tests/T1Controller.Tests.csproj -c Release
dotnet build windows/T1Controller/T1Controller.csproj -c Release
```

The Windows application can be cross-compiled on macOS with the .NET 10 SDK, but desktop interaction, microphone behavior, and hardware filtering require a Windows machine. macOS builds require the Xcode SDK described in the README.

## Hardware changes

Record the OS version, remote model, transport, HID collection, down/up events, native behavior, and reconnect result. Verify shared keyboards and mice remain unaffected. For music changes, run both clients, select one in Orvio, and verify the other client's track and playback state do not change. For display or KMFU changes, verify both switching directions and the peripheral owner.

Keep machine-specific configurations, credentials, recordings, and diagnostic screenshots out of commits. Add sanitized fixtures when needed. Do not include authentication tokens in issue reports.

## Compatibility

The product is Orvio. Existing `T1Controller` namespaces, bundle identifier, settings paths, keychain service, and instance locks are intentionally retained so existing settings and installation behavior remain compatible. Device labels such as T1 and RC003 identify the hardware.

Contributions are submitted under the repository's PolyForm Noncommercial 1.0.0 license. Do not introduce third-party code whose license is incompatible with these distribution terms; obtain separate authorization or keep the dependency under its own applicable terms. Preserve relevant copyright and dependency notices when adding third-party code or assets.
