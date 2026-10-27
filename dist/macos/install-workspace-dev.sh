#!/bin/bash
set -euo pipefail
# Dedicated local development target for the omg-workspace checkout.
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || {
  echo 'Commit the intended changes before installing OMG Dev Workspace.' >&2
  exit 1
}
commit=$(git rev-parse HEAD)
short=${commit:0:8}
identity=${OMG_DEV_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '$1 ~ /^[0-9]+\)$/ {print $2; exit}')}
[[ -n "$identity" && "$identity" != '-' ]] || { echo 'Persistent signing identity required.' >&2; exit 1; }
base_version=$(python3 -c 'import re; print(re.search(r"MARKETING_VERSION = ([0-9.]+);", open("macos/Ghostty.xcodeproj/project.pbxproj").read()).group(1))')
version="${base_version}-workspace.${short}"
ghostty_version=$(plutil -extract GhosttyBaseVersion raw macos/Ghostty-Info.plist)
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
  -Dxcframework-target=native -Demit-macos-app=false "-Dversion-string=$ghostty_version"
macos/build.nu --configuration Debug --action build --workspace-app --marketing-version "$version"
[[ "$(git rev-parse HEAD)" == "$commit" && -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || {
  echo 'Source changed while building; refusing installation.' >&2; exit 1;
}
source_app="$repo_root/macos/build-workspace/Debug/OMG.app"
target_app='/Applications/OMG Dev Workspace.app'
[[ "$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")" == 'com.jischeng.omg.debug.workspace' ]]
# Disable updater and URL registration for this isolated development application.
python3 - "$source_app/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: info = plistlib.load(f)
info['CFBundleName'] = info['CFBundleDisplayName'] = 'OMG Dev Workspace'
info['SUEnableAutomaticChecks'] = False
info['SUAllowsAutomaticUpdates'] = False
info.pop('SUFeedURL', None)
info.pop('CFBundleURLTypes', None)
with open(path, 'wb') as f: plistlib.dump(info, f)
PY
OMG_SIGNING_MODE=development OMG_SIGNING_IDENTITY="$identity" OMG_SIGNING_KEYCHAIN= \
  OMG_SIGNING_ENTITLEMENTS="$repo_root/macos/GhosttyDebug.entitlements" \
  dist/macos/sign_omg_app.sh "$source_app"
"$source_app/Contents/MacOS/omg" --version | grep -q '.ReleaseFast'
OMG_TEST_BINARY="$source_app/Contents/MacOS/omg" python3 dist/test_ssh_agent_wrappers.py
if pgrep -f '^/Applications/OMG Dev Workspace.app/Contents/MacOS/omg' >/dev/null; then
  osascript -e 'tell application id "com.jischeng.omg.debug.workspace" to quit'
  for _ in {1..40}; do
    pgrep -f '^/Applications/OMG Dev Workspace.app/Contents/MacOS/omg' >/dev/null || break
    sleep 0.25
  done
fi
if pgrep -f '^/Applications/OMG Dev Workspace.app/Contents/MacOS/omg' >/dev/null; then
  echo 'OMG Dev Workspace is still running; refusing to overwrite it.' >&2; exit 1
fi
staging=$(mktemp -d '/Applications/.omg-workspace-install.XXXXXX')
trap 'rm -rf "$staging"' EXIT
ditto "$source_app" "$staging/OMG Dev Workspace.app"
codesign --verify --deep --strict "$staging/OMG Dev Workspace.app"
if [[ -e "$target_app" ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist")" == 'com.jischeng.omg.debug.workspace' ]]
  mv "$target_app" "$staging/previous.app"
fi
mv "$staging/OMG Dev Workspace.app" "$target_app"
codesign --verify --deep --strict "$target_app"
cmp "$source_app/Contents/MacOS/omg" "$target_app/Contents/MacOS/omg"
launch_tmpdir=$(getconf DARWIN_USER_TEMP_DIR)
env -u NO_COLOR TMPDIR="$launch_tmpdir" open "$target_app"
printf 'installed=%s\nbundle_id=com.jischeng.omg.debug.workspace\nversion=%s\ncommit=%s\n' "$target_app" "$version" "$commit"
