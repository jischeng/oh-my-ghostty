#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
if [[ "${1:-}" == --changed-since ]]; then
  [[ $# -eq 2 ]] || { echo "usage: $0 [--changed-since REF]" >&2; exit 64; }
  plan=$(bash "$root/dist/macos/dev-tool.sh" python3 "$root/dist/omg_mobile_test_plan.py" --changed-since "$2")
  echo "$plan"
  selected=$(printf '%s' "$plan" | bash "$root/dist/macos/dev-tool.sh" python3 -c \
    'import json,sys; print(int(json.load(sys.stdin)["run_mobile"]))')
  [[ "$selected" == 1 ]] || exit 0
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--changed-since REF]" >&2
  exit 64
fi
"$root/ios/scripts/build-vt.sh" macos
unset SDKROOT
swift test --package-path "$root/ios" \
  -Xcc "-I$root/ios/.build/headers" \
  -Xlinker "-L$root/zig-out/lib" \
  -Xlinker -rpath -Xlinker "$root/zig-out/lib"
