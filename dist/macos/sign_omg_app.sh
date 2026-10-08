#!/bin/bash
# Sign OMG.app and every nested executable with one identity.
# Public releases use a pinned persistent certificate, not a code hash.
# Self-signed releases disable hardened runtime (no Apple Team ID).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: OMG_SIGNING_IDENTITY=<certificate> $0 APP_PATH" >&2
  exit 64
fi

app_path=$1
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
entitlements=${OMG_SIGNING_ENTITLEMENTS:-"$repo_root/macos/Ghostty.entitlements"}
mode=$(python3 "$repo_root/dist/macos/omg_signing.py" policy)
[[ -f "$entitlements" ]] || { echo "missing signing entitlements" >&2; exit 1; }
if [[ "$mode" == self-signed ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == com.jischeng.omg ]] || {
    echo "self-signed release requires com.jischeng.omg" >&2; exit 1;
  }
  requirement=$(python3 "$repo_root/dist/macos/omg_signing.py" requirement)
fi

if [[ ! -x "$app_path/Contents/MacOS/omg" ]]; then
  echo "missing OMG executable in $app_path" >&2
  exit 1
fi

sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_options=(--force --sign "$OMG_SIGNING_IDENTITY")
if [[ -n "${OMG_SIGNING_KEYCHAIN:-}" ]]; then
  [[ -f "$OMG_SIGNING_KEYCHAIN" ]] || { echo "missing signing keychain" >&2; exit 1; }
  sign_options+=(--keychain "$OMG_SIGNING_KEYCHAIN")
  if [[ "$mode" == self-signed ]]; then
    python3 "$repo_root/dist/macos/omg_signing.py" unlock
  fi
fi
case "$mode" in
  developer-id) sign_options+=(--options runtime --timestamp) ;;
  development) sign_options+=(--options runtime) ;;
  self-signed|ad-hoc) sign_options+=(--options 0 --timestamp=none) ;;
esac
printf 'signing_mode=%s\n' "$mode" >&2

components=(
  "$sparkle/XPCServices/Downloader.xpc"
  "$sparkle/XPCServices/Installer.xpc"
  "$sparkle/Autoupdate"
  "$sparkle/Updater.app"
  "$app_path/Contents/Frameworks/Sparkle.framework"
  "$app_path/Contents/PlugIns/DockTilePlugin.plugin"
)

for component in "${components[@]}"; do
  [[ -e "$component" ]] || continue
  codesign "${sign_options[@]}" "$component"
done

# Keep this array non-empty: macOS Bash 3.2 treats empty arrays as unset under -u.
app_sign_options=("${sign_options[@]}")
if [[ "$mode" == self-signed ]]; then
  app_sign_options+=(--requirements "=designated => $requirement")
fi
codesign \
  "${app_sign_options[@]}" \
  --entitlements "$entitlements" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
if [[ "$mode" == self-signed || "$mode" == developer-id ]]; then
  python3 "$repo_root/dist/macos/omg_signing.py" verify "$app_path"
fi
