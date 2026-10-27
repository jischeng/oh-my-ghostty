#!/bin/bash
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || { echo 'Commit intended changes before installing OMG Dev PTY.' >&2; exit 1; }
commit=$(git rev-parse HEAD)
short=${commit:0:8}
identity=${OMG_DEV_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '$1 ~ /^[0-9]+\)$/ {print $2; exit}')}
[[ -n "$identity" && "$identity" != '-' ]] || { echo 'Persistent signing identity required.' >&2; exit 1; }
base_version=$(python3 -c 'import re; print(re.search(r"MARKETING_VERSION = ([0-9.]+);", open("macos/Ghostty.xcodeproj/project.pbxproj").read()).group(1))')
version="${base_version}-pty.${short}"
ghostty_version=$(plutil -extract GhosttyBaseVersion raw macos/Ghostty-Info.plist)
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
  -Dxcframework-target=native -Demit-macos-app=false "-Dversion-string=$ghostty_version"
macos/build.nu --configuration Debug --action build --pty-app --marketing-version "$version"
[[ "$(git rev-parse HEAD)" == "$commit" && -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || { echo 'Source changed while building.' >&2; exit 1; }
source_app="$repo_root/macos/build-pty/Debug/OMG.app"
target_app='/Applications/OMG Dev PTY.app'
[[ "$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")" == 'com.jischeng.omg.debug.pty' ]]
python3 dist/macos/build-session-runtime.py --output "$source_app/Contents/Resources/session-runtime"
[[ "$(git rev-parse HEAD)" == "$commit" && -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || { echo 'Source changed while packaging runtime.' >&2; exit 1; }
python3 - "$source_app/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: info = plistlib.load(f)
info['CFBundleName'] = info['CFBundleDisplayName'] = 'OMG Dev PTY'
info['SUEnableAutomaticChecks'] = False
info['SUAllowsAutomaticUpdates'] = False
info.pop('SUFeedURL', None)
info.pop('CFBundleURLTypes', None)
# Dock tile plugin reads the standard Dev defaults; omit it for isolation.
info.pop('NSDockTilePlugIn', None)
with open(path, 'wb') as f: plistlib.dump(info, f)
PY
OMG_SIGNING_MODE=development OMG_SIGNING_IDENTITY="$identity" OMG_SIGNING_KEYCHAIN= \
  OMG_SIGNING_ENTITLEMENTS="$repo_root/macos/GhosttyDebug.entitlements" dist/macos/sign_omg_app.sh "$source_app"
"$source_app/Contents/MacOS/omg" --version | grep -q '.ReleaseFast'
OMG_TEST_BINARY="$source_app/Contents/MacOS/omg" python3 dist/test_ssh_agent_wrappers.py
if pgrep -f '^/Applications/OMG Dev PTY.app/Contents/MacOS/omg' >/dev/null; then
  osascript -e 'tell application id "com.jischeng.omg.debug.pty" to quit' || true
  for _ in {1..40}; do
    pgrep -f '^/Applications/OMG Dev PTY.app/Contents/MacOS/omg' >/dev/null || break
    sleep 0.25
  done
fi
if pgrep -f '^/Applications/OMG Dev PTY.app/Contents/MacOS/omg' >/dev/null; then
  echo 'OMG Dev PTY is still running; refusing to overwrite it.' >&2; exit 1
fi
staging=$(mktemp -d '/Applications/.omg-pty-install.XXXXXX')
trap 'rm -rf "$staging"' EXIT
ditto "$source_app" "$staging/OMG Dev PTY.app"
codesign --verify --deep --strict "$staging/OMG Dev PTY.app"
if [[ -e "$target_app" ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist")" == 'com.jischeng.omg.debug.pty' ]]
  mv "$target_app" "$staging/previous.app"
fi
if ! mv "$staging/OMG Dev PTY.app" "$target_app"; then
  [[ ! -e "$staging/previous.app" ]] || mv "$staging/previous.app" "$target_app"
  exit 1
fi
codesign --verify --deep --strict "$target_app"
cmp "$source_app/Contents/MacOS/omg" "$target_app/Contents/MacOS/omg"
printf 'installed=%s\nbundle_id=com.jischeng.omg.debug.pty\nversion=%s\ncommit=%s\n' "$target_app" "$version" "$commit"
