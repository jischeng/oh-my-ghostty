#!/bin/bash
# Sign OMG.app and every nested executable with one identity.
# Developer ID and persistent development builds use hardened runtime. Local
# ad-hoc builds deliberately do not: hardened runtime library validation cannot
# treat independently ad-hoc signed embedded frameworks as members of the same
# Team ID.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: OMG_SIGNING_IDENTITY='<Developer ID Application identity>' $0 APP_PATH" >&2
  exit 64
fi

: "${OMG_SIGNING_IDENTITY:?set OMG_SIGNING_IDENTITY to a Developer ID Application identity}"
app_path=$1
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
entitlements=${OMG_SIGNING_ENTITLEMENTS:-"$repo_root/macos/Ghostty.entitlements"}

if [[ ! -x "$app_path/Contents/MacOS/omg" ]]; then
  echo "missing OMG executable in $app_path" >&2
  exit 1
fi

sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_options=(--force --sign "$OMG_SIGNING_IDENTITY")
if [[ "$OMG_SIGNING_IDENTITY" != "-" ]]; then
  sign_options+=(--options runtime)
else
  echo "warning: creating a local ad-hoc build without hardened runtime" >&2
fi

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

[[ -f "$entitlements" ]] || {
  echo "missing signing entitlements: $entitlements" >&2
  exit 1
}
codesign \
  "${sign_options[@]}" \
  --entitlements "$entitlements" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
