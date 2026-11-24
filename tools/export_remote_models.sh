#!/bin/bash
# Regenerate the Windows geometry from the models used by the macOS app.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
model_dir="$(mktemp -d "${TMPDIR:-/tmp}/t1-scene.XXXXXX")"
trap 'rm -rf "$model_dir"' EXIT
cd "$project_dir"
swiftc -emit-library -emit-module -module-name T1Core -module-cache-path "$model_dir/cache" \
    macos/Sources/T1Core/*.swift -o "$model_dir/libT1Core.dylib"
sed -n '/^enum RemoteProfile: /,/^}/p' macos/Sources/T1Controller/ControllerModel.swift > "$model_dir/RemoteProfile.swift"
cat macos/Sources/T1Controller/RemoteScene.swift tools/export_remote_models.swift > "$model_dir/Scene.swift"
swiftc -D T1_EXPORT_REMOTE -I "$model_dir" -L "$model_dir" -lT1Core -module-cache-path "$model_dir/cache" \
    -Xlinker -rpath -Xlinker "$model_dir" macos/Sources/T1Controller/RemoteKey.swift \
    "$model_dir/RemoteProfile.swift" "$model_dir/Scene.swift" -o "$model_dir/export"
"$model_dir/export" | gzip -n -9 > "$model_dir/remote-models.json.gz"
mv "$model_dir/remote-models.json.gz" "${1:-shared/remote-models.json.gz}"
