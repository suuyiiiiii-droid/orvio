#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    cat >&2 <<'EOF'
Usage: bash tools/package_macos.sh PATH_TO_PAHO_INSTALL

Prepare the local dependency if needed:
  python3 -m pip install --target /private/tmp/t1-bemfa-paho paho-mqtt==2.1.0
  bash tools/package_macos.sh /private/tmp/t1-bemfa-paho

Set T1_SWIFTPM_DISABLE_SANDBOX=1 in build runners that forbid nested sandboxes.
EOF
    exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
paho_dir=$1
paho_metadata="$paho_dir/paho_mqtt-2.1.0.dist-info"
paho_license="$paho_metadata/licenses/LICENSE.txt"
if [[ ! -f "$paho_license" ]]; then
    paho_license="$paho_metadata/LICENSE.txt"
fi
if [[ ! -f "$paho_dir/paho/mqtt/client.py" || ! -f "$paho_license" ]] ||
    ! grep -qx 'Version: 2.1.0' "$paho_metadata/METADATA"; then
    echo 'Expected a local paho-mqtt 2.1.0 installation with its license.' >&2
    exit 2
fi

version=0.3.0
output_dir="$repo_dir/build"
output_app="$output_dir/Orvio-$version.app"
output_zip="$output_dir/Orvio-$version-macos.zip"
if [[ -e "$output_app" || -L "$output_app" || -e "$output_zip" || -L "$output_zip" ]]; then
    echo "Move the existing $version artifacts out of build/ before rebuilding." >&2
    exit 2
fi

staging=$(mktemp -d /private/tmp/t1-package-macos.XXXXXX)
publish_dir=
cleanup() {
    rm -rf -- "$staging"
    if [[ -n "$publish_dir" ]]; then
        rm -rf -- "$publish_dir"
    fi
}
trap cleanup EXIT

app="$staging/Orvio.app"
contents="$app/Contents"
bridge="$contents/Resources/XiaoAIBridge"
mkdir -p "$contents/MacOS" "$bridge/paho/mqtt" "$bridge/paho_mqtt-2.1.0.dist-info/licenses" \
    "$staging/cache" "$staging/config" "$staging/security" "$staging/modules"
install -m 644 "$repo_dir/macos/Resources/T1Mark.icns" "$contents/Resources/"
install -m 644 "$repo_dir/tools/xiaoai_daily.py" "$repo_dir/tools/bemfa_probe.py" "$bridge/"
install -m 644 "$paho_dir/paho/__init__.py" "$bridge/paho/"
install -m 644 "$paho_dir"/paho/mqtt/*.py "$paho_dir/paho/mqtt/py.typed" "$bridge/paho/mqtt/"
install -m 644 "$paho_metadata/METADATA" "$bridge/paho_mqtt-2.1.0.dist-info/"
install -m 644 "$paho_license" "$bridge/paho_mqtt-2.1.0.dist-info/licenses/LICENSE.txt"

swift_options=(
    --package-path "$repo_dir/macos"
    --cache-path "$staging/cache"
    --config-path "$staging/config"
    --security-path "$staging/security"
    --build-system native
    --configuration release
    --product Orvio
)
if [[ ${T1_SWIFTPM_DISABLE_SANDBOX:-0} == 1 ]]; then
    swift_options+=(--disable-sandbox)
fi
export SWIFTPM_MODULECACHE_OVERRIDE="$staging/modules"
for architecture in arm64 x86_64; do
    architecture_options=(--scratch-path "$staging/$architecture" --triple "$architecture-apple-macosx14.0")
    swift build "${swift_options[@]}" "${architecture_options[@]}"
    bin_dir=$(swift build "${swift_options[@]}" "${architecture_options[@]}" --show-bin-path)
    ln -s "$bin_dir/Orvio" "$staging/Orvio-$architecture"
done
lipo -create "$staging/Orvio-arm64" "$staging/Orvio-x86_64" \
    -output "$contents/MacOS/Orvio"
lipo "$contents/MacOS/Orvio" -verify_arch arm64
lipo "$contents/MacOS/Orvio" -verify_arch x86_64

plist="$contents/Info.plist"
install -m 644 "$repo_dir/macos/Info.plist" "$plist"
plutil -replace CFBundleDevelopmentRegion -string en "$plist"
plutil -replace CFBundleExecutable -string Orvio "$plist"
plutil -replace CFBundleIdentifier -string local.t1controller.app "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string 22 "$plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$plist"
plutil -lint "$plist"
printf 'APPL????' > "$contents/PkgInfo"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

archive="$staging/Orvio-$version-macos.zip"
ditto -c -k --norsrc --keepParent "$app" "$archive"
ditto -x -k "$archive" "$staging/archive-check"
codesign --verify --deep --strict "$staging/archive-check/Orvio.app"

mkdir -p "$output_dir"
publish_dir=$(mktemp -d "$output_dir/.t1-package.XXXXXX")
ditto --norsrc "$app" "$publish_dir/Orvio-$version.app"
codesign --verify --deep --strict "$publish_dir/Orvio-$version.app"
install -m 644 "$archive" "$publish_dir/Orvio-$version-macos.zip"
mv -n "$publish_dir/Orvio-$version.app" "$output_app"
mv -n "$publish_dir/Orvio-$version-macos.zip" "$output_zip"
printf '%s\n' "$output_app" "$output_zip"
