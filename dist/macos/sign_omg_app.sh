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
mode=$(bash "$repo_root/dist/macos/signing-python.sh" policy)
[[ -f "$entitlements" ]] || { echo "missing signing entitlements" >&2; exit 1; }
if [[ "$mode" == self-signed ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == com.jischeng.omg ]] || {
    echo "self-signed release requires com.jischeng.omg" >&2; exit 1;
  }
  requirement=$(bash "$repo_root/dist/macos/signing-python.sh" requirement)
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
    bash "$repo_root/dist/macos/signing-python.sh" unlock
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

# Native runtime helpers/libraries are nested code too. Linux artifacts remain
# data inside the signed bundle; refresh manifest hashes after Mach-O signing.
runtime="$app_path/Contents/Resources/session-runtime"
if [[ -d "$runtime" ]]; then
  while IFS= read -r -d '' component; do
    if file -b "$component" | grep -q 'Mach-O'; then
      codesign "${sign_options[@]}" "$component"
    fi
  done < <(find "$runtime" -type f -print0)
  python3 - "$runtime" <<'PY'
import hashlib, json, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('*/manifest.json'):
    manifest = json.loads(path.read_text())
    for entry in manifest['files']:
        entry['sha256'] = hashlib.sha256((path.parent / entry['name']).read_bytes()).hexdigest()
    path.write_text(json.dumps(manifest, indent=2) + '\n')
PY
fi

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
  bash "$repo_root/dist/macos/signing-python.sh" verify "$app_path"
fi
