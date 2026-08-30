#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 [--skip-build]" >&2
  exit 64
}

skip_build=false
case "${1-}" in
  "") ;;
  --skip-build) skip_build=true ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

source_app="$repo_root/macos/build/Debug/OMG.app"
target_app="/Applications/OMG Dev.app"
source_bin="$source_app/Contents/MacOS/omg"
target_bin="$target_app/Contents/MacOS/omg"

if [[ "$skip_build" != true ]]; then
  macos/build.nu --scheme Ghostty --configuration Debug --action build
fi

[[ -x "$source_bin" ]] || {
  echo "missing Debug app: $source_app" >&2
  exit 1
}

bundle_id=$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")
[[ "$bundle_id" == "com.jischeng.omg.debug" ]] || {
  echo "refusing to install non-Debug bundle: $bundle_id" >&2
  exit 1
}

version_output=$("$source_bin" --version 2>&1)
build_mode=$(awk '/build mode/{print $NF}' <<<"$version_output")
[[ "$build_mode" == ".ReleaseFast" ]] || {
  echo "refusing routine Dev install with GhosttyKit build mode $build_mode" >&2
  exit 1
}

if pgrep -f '/Applications/OMG Dev.app/Contents/MacOS/omg' >/dev/null; then
  osascript -e 'tell application id "com.jischeng.omg.debug" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f '/Applications/OMG Dev.app/Contents/MacOS/omg' >/dev/null || break
    sleep 0.25
  done
fi

if pgrep -f '/Applications/OMG Dev.app/Contents/MacOS/omg' >/dev/null; then
  echo "OMG Dev is still running; refusing to overwrite it" >&2
  exit 1
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"

codesign --verify --deep --strict "$target_app"
source_sha=$(shasum -a 256 "$source_bin" | awk '{print $1}')
target_sha=$(shasum -a 256 "$target_bin" | awk '{print $1}')
[[ "$source_sha" == "$target_sha" ]] || {
  echo "installed binary hash mismatch" >&2
  exit 1
}

installed_bundle_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist")
installed_version=$(plutil -extract CFBundleShortVersionString raw "$target_app/Contents/Info.plist")
installed_build=$(plutil -extract CFBundleVersion raw "$target_app/Contents/Info.plist")

open "$target_app"
printf 'installed=%s\nbundle_id=%s\nomg_version=%s\nbundle_version=%s\nbuild_mode=%s\nsource_sha=%s\ninstalled_sha=%s\nlaunched=yes\n' \
  "$target_app" "$installed_bundle_id" "$installed_version" "$installed_build" \
  "$build_mode" "$source_sha" "$target_sha"
