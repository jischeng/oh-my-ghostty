#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
support=${OMG_MOBILE_APP_SUPPORT:-"$HOME/Library/Application Support/OMG Dev"}
listen=${OMG_MOBILE_LISTEN:-}
if [[ -z "$listen" ]]; then
  for interface in en0 en1; do
    address=$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)
    if [[ -n "$address" ]]; then listen="$address:8791"; break; fi
  done
fi
if [[ -z "$listen" ]]; then
  echo "No LAN address found. Set OMG_MOBILE_LISTEN=192.168.x.x:8791." >&2
  exit 69
fi
binary=${OMG_MOBILE_RUNTIME:-"$root/session-runtime/target/debug/omgd"}
if [[ ! -x "$binary" ]]; then
  echo "Build the runtime first: ios/scripts/build-vt.sh macos; cargo build --manifest-path session-runtime/Cargo.toml" >&2
  exit 69
fi
if [[ ! -d "$support" ]]; then
  echo "The selected OMG channel has no Application Support directory." >&2
  exit 66
fi
token="$support/mobile-pair.token"
exec "$binary" mobile --listen "$listen" --app-support "$support" --token-file "$token" "$@"
