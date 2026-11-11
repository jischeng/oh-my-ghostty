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
mkdir -p "$root/ios/.build/headers"
# The macOS embedder's umbrella module also owns vt.h. Isolate the VT-only
# headers so Clang does not substitute the full GhosttyKit module on iOS.
cp -R "$root/include/ghostty" "$root/ios/.build/headers/"
args=(-Demit-lib-vt=true -Demit-macos-app=false -Demit-xcframework=false
      -Doptimize=ReleaseFast -Dversion-string=1.3.2-dev)
if [[ -n "$target" ]]; then args+=("-Dtarget=$target"); fi
cd "$root"
if [[ "$sdk" == macos ]]; then
  mise exec zig@0.16.0 -- zig build "${args[@]}"
else
  mise exec zig@0.16.0 -- zig build "${args[@]}" --prefix "ios/.build/vt-build/$sdk"
  mkdir -p "$root/ios/.build/vt/$sdk"
  cp "$root/ios/.build/vt-build/$sdk/lib/libghostty-vt.a" "$root/ios/.build/vt/$sdk/"
fi
