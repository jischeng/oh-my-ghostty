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
  leaf_fp=${requirement##*H\"}
  leaf_fp=${leaf_fp%\"}
  [[ "$leaf_fp" =~ ^[0-9A-F]{40}$ ]] || { echo "invalid leaf fingerprint in requirement" >&2; exit 1; }
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

bundle_identifier() {
  local target=$1
  local plist
  for plist in \
    "$target/Contents/Info.plist" \
    "$target/Resources/Info.plist" \
    "$target/Versions/Current/Resources/Info.plist"; do
    if [[ -f "$plist" ]]; then
      plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null && return 0
    fi
  done
  return 1
}

sign_target() {
  local target=$1
  local explicit_id=${2:-}
  local effective_id=$explicit_id
  local target_options=("${sign_options[@]}")
  if [[ -n "$explicit_id" ]]; then
    target_options+=(-i "$explicit_id")
  else
    effective_id=$(bundle_identifier "$target" || true)
  fi
  if [[ "$mode" == self-signed ]]; then
    [[ -n "$effective_id" ]] || {
      echo "missing signing identifier for $target" >&2
      exit 1
    }
    target_options+=(--requirements "=designated => identifier \"$effective_id\" and certificate leaf = H\"$leaf_fp\"")
  fi
  codesign "${target_options[@]}" "$target"
}

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
  askpass="$runtime/askpass"
  if [[ -e "$askpass" || -L "$askpass" ]]; then
    [[ ! -L "$askpass" && -f "$askpass" && -x "$askpass" ]] || {
      echo "session-runtime/askpass must be an executable regular file" >&2
      exit 1
    }
  fi
  while IFS= read -r -d '' component; do
    if file -b "$component" | grep -q 'Mach-O'; then
      case "$(basename "$component")" in
        omgd) comp_id="com.jischeng.omg.omgd" ;;
        omg-mobile-support) comp_id="com.jischeng.omg.mobile-support" ;;
        libghostty-vt*.dylib) comp_id="com.jischeng.omg.libghostty-vt" ;;
        *) comp_id="com.jischeng.omg.runtime.$(basename "$component" | tr -c 'A-Za-z0-9._-' '_')" ;;
      esac
      sign_target "$component" "$comp_id"
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

for framework in "$app_path/Contents/Frameworks"/*.framework; do
  [[ -e "$framework" ]] || continue
  [[ "$(basename "$framework")" == "Sparkle.framework" ]] && continue
  sign_target "$framework"
done

for component in "${components[@]}"; do
  [[ -e "$component" ]] || continue
  if [[ "$component" == "$sparkle/Autoupdate" ]]; then
    sign_target "$component" "com.jischeng.omg.sparkle.autoupdate"
  else
    sign_target "$component"
  fi
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

if [[ "${OMG_SKIP_POST_SIGN_VERIFY:-0}" != "1" ]]; then
  codesign --verify --deep --strict --verbose=2 "$app_path"
  if [[ "$mode" == self-signed || "$mode" == developer-id ]]; then
    bash "$repo_root/dist/macos/signing-python.sh" verify "$app_path"
  fi
fi
