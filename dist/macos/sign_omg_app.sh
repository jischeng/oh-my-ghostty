#!/bin/bash
# Sign OMG.app and every nested executable with one distribution identity.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: OMG_SIGNING_IDENTITY='<Developer ID Application identity>' $0 APP_PATH" >&2
  exit 64
fi

: "${OMG_SIGNING_IDENTITY:?set OMG_SIGNING_IDENTITY to a Developer ID Application identity}"
app_path=$1
repo_root=$(cd "$(dirname "$0")/../.." && pwd)

if [[ ! -x "$app_path/Contents/MacOS/omg" ]]; then
  echo "missing OMG executable in $app_path" >&2
  exit 1
fi

sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
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
  codesign --force --sign "$OMG_SIGNING_IDENTITY" --options runtime "$component"
done

codesign \
  --force \
  --sign "$OMG_SIGNING_IDENTITY" \
  --options runtime \
  --entitlements "$repo_root/macos/Ghostty.entitlements" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
