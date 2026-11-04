#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
"$root/ios/scripts/build-vt.sh" macos
unset SDKROOT
swift test --package-path "$root/ios" \
  -Xcc "-I$root/ios/.build/headers" \
  -Xlinker "-L$root/zig-out/lib" \
  -Xlinker -rpath -Xlinker "$root/zig-out/lib"
