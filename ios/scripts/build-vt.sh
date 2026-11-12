#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
sdk=${1:-iphonesimulator}
case "$sdk" in
  macos) target= ;;
  iphoneos) target=aarch64-ios.17.0 ;;
  iphonesimulator) target=aarch64-ios.17.0-simulator ;;
  *) echo "usage: $0 [macos|iphoneos|iphonesimulator]" >&2; exit 64 ;;
esac
unset SDKROOT
mkdir -p "$root/ios/.build/headers/ghostty"
# The macOS embedder's umbrella module also owns vt.h. Isolate the VT-only
# headers so Clang does not substitute the full GhosttyKit module on iOS.
# Preserve timestamps on unchanged headers so incremental Xcode builds stay warm.
rsync -a --checksum --delete "$root/include/ghostty/" "$root/ios/.build/headers/ghostty/"
ghostty_version="1.3.2-dev"
if [[ -f "$root/macos/Ghostty-Info.plist" ]]; then
  ghostty_version=$(/usr/bin/plutil -extract GhosttyBaseVersion raw "$root/macos/Ghostty-Info.plist" 2>/dev/null || echo "1.3.2-dev")
fi
args=(-Demit-lib-vt=true -Demit-macos-app=false -Demit-xcframework=false
      -Doptimize=ReleaseFast "-Dversion-string=$ghostty_version")
if [[ -n "$target" ]]; then args+=("-Dtarget=$target"); fi
cd "$root"
if [[ "$sdk" == macos ]]; then
  mise exec zig@0.16.0 -- zig build "${args[@]}"
else
  dest_dir="$root/ios/.build/vt/$sdk"
  dest_lib="$dest_dir/libghostty-vt.a"
  mkdir -p "$dest_dir"
  use_cache=1
  if [[ "${OMG_RELEASE_NO_CACHE:-0}" == "1" ]]; then
    use_cache=0
  fi
  zig_ver=$(mise exec zig@0.16.0 -- zig version)
  cache_key=$(python3 - "$root" "$sdk" "$ghostty_version" "$zig_ver" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
h = hashlib.sha256()
for token in sys.argv[2:]:
    h.update(token.encode())
    h.update(b"\0")
for base in ("src", "include"):
    for path in sorted((root / base).rglob("*")):
        if path.is_file():
            h.update(str(path.relative_to(root)).encode())
            h.update(path.read_bytes())
for rel in ("build.zig", "build.zig.zon"):
    p = root / rel
    if p.is_file():
        h.update(rel.encode())
        h.update(p.read_bytes())
print(h.hexdigest()[:24])
PY
  )
  cache_root="$root/.release-build/_cache/ios-vt"
  cache_lib="$cache_root/$sdk-$cache_key/libghostty-vt.a"
  if [[ "$use_cache" -eq 1 && -s "$cache_lib" ]]; then
    if [[ ! -f "$dest_lib" ]] || ! cmp -s "$cache_lib" "$dest_lib"; then
      cp -p "$cache_lib" "$dest_lib"
    fi
    touch "$cache_root/$sdk-$cache_key"
    printf '[ios-vt:%s] cache=hit key=%s\n' "$sdk" "$cache_key"
    exit 0
  fi
  mise exec zig@0.16.0 -- zig build "${args[@]}" --prefix "ios/.build/vt-build/$sdk"
  cp "$root/ios/.build/vt-build/$sdk/lib/libghostty-vt.a" "$dest_lib"
  if [[ "$use_cache" -eq 1 ]]; then
    mkdir -p "$cache_root/$sdk-$cache_key"
    cp -p "$dest_lib" "$cache_lib"
    python3 - "$cache_root" "$sdk-" <<'PY'
from pathlib import Path
import shutil
import sys

root, prefix = Path(sys.argv[1]), sys.argv[2]
entries = sorted(
    (p for p in root.iterdir() if p.is_dir() and p.name.startswith(prefix)),
    key=lambda p: p.stat().st_mtime,
    reverse=True,
)
for stale in entries[2:]:
    shutil.rmtree(stale, ignore_errors=True)
PY
  fi
fi
