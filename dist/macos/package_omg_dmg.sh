#!/bin/bash
# Package one verified single-architecture OMG.app as a release DMG.
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
  arm64|x86_64) ;;
  *) echo "unsupported architecture: $arch" >&2; exit 64 ;;
esac

binary="$app_path/Contents/MacOS/omg"
if [[ ! -x "$binary" ]]; then
  echo "missing OMG executable: $binary" >&2
  exit 1
fi
if [[ "$(lipo -archs "$binary")" != "$arch" ]]; then
  echo "OMG.app is not a single-architecture $arch build" >&2
  exit 1
fi

codesign --verify --deep --strict "$app_path"
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
