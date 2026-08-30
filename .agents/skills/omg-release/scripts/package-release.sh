#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: OMG_SIGNING_IDENTITY=... PREVIOUS_TAG=vX.Y.Z $0 OMG_VERSION" >&2
  exit 64
fi
: "${OMG_SIGNING_IDENTITY:?set OMG_SIGNING_IDENTITY to a Developer ID identity or - for ad-hoc}"
: "${PREVIOUS_TAG:?set PREVIOUS_TAG to the previous published OMG tag}"

omg_version=$1
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
build_root="$repo_root/.release-build/$omg_version"
artifacts="$build_root/artifacts"

for arch in arm64 x86_64 universal; do
  app="$build_root/$arch/Release/OMG.app"
  [[ -x "$app/Contents/MacOS/omg" ]] || { echo "missing $app" >&2; exit 1; }
  dist/macos/sign_omg_app.sh "$app"
  codesign --verify --deep --strict "$app"

  if [[ "$arch" == x86_64 ]]; then
    output=$(arch -x86_64 "$app/Contents/MacOS/omg" --version 2>&1)
  else
    output=$("$app/Contents/MacOS/omg" --version 2>&1)
  fi
  mode=$(awk '/build mode/{print $NF}' <<<"$output")
  [[ "$mode" == ".ReleaseFast" ]] || { echo "$arch build mode is $mode" >&2; exit 1; }
  printf '[%s] signature=valid launch=ok mode=%s\n' "$arch" "$mode"
done

rm -rf "$artifacts"
mkdir -p "$artifacts"
for arch in arm64 x86_64 universal; do
  dist/macos/package_omg_dmg.sh \
    "$omg_version" \
    "$arch" \
    "$build_root/$arch/Release/OMG.app" \
    "$artifacts"
done
(cd "$artifacts" && shasum -a 256 *.dmg > SHA256SUMS.txt)

gh release download "$PREVIOUS_TAG" \
  -R jischeng/oh-my-ghostty \
  -p appcast.xml \
  -D "$artifacts" \
  --clobber

appcast_tool=${GENERATE_APPCAST-}
if [[ -z "$appcast_tool" ]]; then
  appcast_tool=$(command -v generate_appcast || true)
fi
if [[ -z "$appcast_tool" ]]; then
  appcast_tool=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*Sparkle*/bin/generate_appcast' -type f -perm +111 -print -quit 2>/dev/null || true)
fi
[[ -x "$appcast_tool" ]] || {
  echo "generate_appcast not found; set GENERATE_APPCAST" >&2
  exit 1
}

appcast_work="$build_root/appcast-work"
rm -rf "$appcast_work"
mkdir -p "$appcast_work"
cp "$artifacts/appcast.xml" "$appcast_work/appcast.xml"
cp "$artifacts/OMG-$omg_version-macos-universal.dmg" "$appcast_work/"

"$appcast_tool" \
  --account com.jischeng.omg \
  --download-url-prefix "https://github.com/jischeng/oh-my-ghostty/releases/download/v$omg_version/" \
  --embed-release-notes \
  "$appcast_work"
cp "$appcast_work/appcast.xml" "$artifacts/appcast.xml"

python3 - "$artifacts/appcast.xml" "$omg_version" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, expected_version = sys.argv[1:]
root = ET.parse(path).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("appcast has no update items")
values = {child.tag.split("}")[-1]: (child.text or "").strip() for child in item}
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("latest appcast item has no enclosure")
signature = next(
    (value for key, value in enclosure.attrib.items() if key.endswith("edSignature")),
    None,
)
expected_url = (
    "https://github.com/jischeng/oh-my-ghostty/releases/download/"
    f"v{expected_version}/OMG-{expected_version}-macos-universal.dmg"
)
if values.get("shortVersionString") != expected_version:
    raise SystemExit("wrong appcast short version")
if not values.get("version", "").isdigit():
    raise SystemExit("missing numeric appcast bundle version")
if values.get("minimumSystemVersion") != "13.0":
    raise SystemExit("wrong minimum system version")
if not signature:
    raise SystemExit("missing Sparkle EdDSA signature")
if enclosure.get("url") != expected_url:
    raise SystemExit("wrong appcast enclosure URL")
print(
    f"appcast=valid short={expected_version} "
    f"bundle={values['version']} url={expected_url}"
)
PY

mount_base=$(mktemp -d /tmp/omg-release.XXXXXX)
trap 'hdiutil detach "$mount_base/mnt" -force >/dev/null 2>&1 || true; rm -rf "$mount_base"' EXIT
mkdir "$mount_base/mnt"
for arch in arm64 x86_64 universal; do
  dmg="$artifacts/OMG-$omg_version-macos-$arch.dmg"
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_base/mnt" "$dmg" >/dev/null
  bin="$mount_base/mnt/OMG.app/Contents/MacOS/omg"
  if [[ "$arch" == x86_64 ]]; then
    output=$(arch -x86_64 "$bin" --version 2>&1)
  else
    output=$("$bin" --version 2>&1)
  fi
  mode=$(awk '/build mode/{print $NF}' <<<"$output")
  [[ "$mode" == ".ReleaseFast" ]] || { echo "$arch DMG build mode is $mode" >&2; exit 1; }
  hdiutil detach "$mount_base/mnt" >/dev/null
  printf '[%s] dmg_mount=valid launch=ok mode=%s\n' "$arch" "$mode"
done

printf 'artifacts=%s\nsigning_identity=%s\n' "$artifacts" \
  "$([[ "$OMG_SIGNING_IDENTITY" == - ]] && echo ad-hoc || echo Developer-ID)"
