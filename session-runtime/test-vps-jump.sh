#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
runtime="$repo/session-runtime/target/debug/omg-sessiond"
app='/Applications/OMG Dev PTY.app/Contents/MacOS/omg'
# Direct execution starts another GUI even if Finder already opened this app.
# Check before creating a relay; the app's profile lock closes the race too.
existing_pids=$(pgrep -f '^/Applications/OMG Dev PTY\.app/Contents/MacOS/omg( --|$)' || true)
if [[ -n "$existing_pids" ]]; then
  echo "OMG Dev PTY is already running (PID: $existing_pids). Quit that app before running this launcher; other OMG variants may stay open." >&2
  exit 1
fi
state="${TMPDIR:-/tmp}/omg-vps-host-test"
mkdir -p "$state"
chmod 700 "$state"
if [[ -S "$state/client.sock" ]]; then
  echo "Test relay socket already exists: $state/client.sock. Stop the previous test launcher first." >&2
  exit 1
fi
"$runtime" ssh-relay "$state/client.sock" vps-jump /root/.local/share/omg-host-test >"$state/relay.log" 2>&1 &
relay_pid=$!
cleanup() { kill "$relay_pid" 2>/dev/null || true; rm -f "$state/client.sock"; }
trap cleanup EXIT
for _ in {1..50}; do [[ -S "$state/client.sock" ]] && break; sleep 0.1; done
[[ -S "$state/client.sock" ]] || { echo "Relay failed; see $state/relay.log" >&2; exit 1; }
echo "Connecting OMG Dev PTY to vps-jump durable session. Relay log: $state/relay.log"
OMG_EXPERIMENTAL_SESSION_ROUTED=1 OMG_EXPERIMENTAL_SESSION_SOCKET="$state/client.sock" \
  "$app" \
  --window-save-state=always --quit-after-last-window-closed=true
