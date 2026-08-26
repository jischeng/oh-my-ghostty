#!/bin/bash
# Package one verified architecture-specific or universal OMG.app as a release DMG.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 VERSION ARCH APP_PATH OUTPUT_DIR" >&2
  exit 64
fi

version=$1
arch=$2
app_path=$3
output_dir=$4

case "$arch" in
  arm64|x86_64|universal) ;;
  *) echo "unsupported architecture: $arch" >&2; exit 64 ;;
esac

binary="$app_path/Contents/MacOS/omg"
if [[ ! -x "$binary" ]]; then
  echo "missing OMG executable: $binary" >&2
  exit 1
fi
actual_archs=$(lipo -archs "$binary")
if [[ "$arch" == universal ]]; then
  read -r -a arch_list <<< "$actual_archs"
  if [[ ${#arch_list[@]} -ne 2 ]] ||
     [[ " ${arch_list[*]} " != *" arm64 "* ]] ||
     [[ " ${arch_list[*]} " != *" x86_64 "* ]]; then
    echo "OMG.app is not an arm64+x86_64 universal build: $actual_archs" >&2
    exit 1
  fi
elif [[ "$actual_archs" != "$arch" ]]; then
  echo "OMG.app is not a single-architecture $arch build" >&2
  exit 1
fi

codesign --verify --deep --strict "$app_path"

app_signature=$(codesign -dv --verbose=4 "$app_path" 2>&1)
if grep -q '^Signature=adhoc$' <<< "$app_signature" &&
   grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$app_signature"; then
  echo "ad-hoc OMG.app cannot use hardened runtime: embedded Sparkle will fail library validation" >&2
  exit 1
fi
app_team=$(sed -n 's/^TeamIdentifier=//p' <<< "$app_signature")
sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
signed_components=(
  "$sparkle/Sparkle"
  "$sparkle/XPCServices/Downloader.xpc"
  "$sparkle/XPCServices/Installer.xpc"
  "$sparkle/Autoupdate"
  "$sparkle/Updater.app"
  "$app_path/Contents/PlugIns/DockTilePlugin.plugin"
)
for component in "${signed_components[@]}"; do
  [[ -e "$component" ]] || continue
  component_signature=$(codesign -dv --verbose=4 "$component" 2>&1)
  component_team=$(sed -n 's/^TeamIdentifier=//p' <<< "$component_signature")
  if [[ "$app_team" != "$component_team" ]]; then
    echo "OMG.app and $component have different Team IDs: $app_team != $component_team" >&2
    exit 1
  fi
done

test "$(plutil -extract OMGVersion raw "$app_path/Contents/Info.plist")" = "$version"
test "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" = "com.jischeng.omg"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$output_dir"
ditto "$app_path" "$stage/OMG.app"
ln -s /Applications "$stage/Applications"

output="$output_dir/OMG-$version-macos-$arch.dmg"
rm -f "$output"
hdiutil create \
  -volname "OMG $version — $arch" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$output" >/dev/null
hdiutil verify "$output" >/dev/null
printf '%s\n' "$output"
