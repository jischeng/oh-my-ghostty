#!/bin/bash
# One interpreter for all signing helpers. No credential values are handled here.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
command_name=${1:-}
python=${OMG_SIGNING_PYTHON:-}
pin=
if [[ -n "${OMG_SIGNING_KEYCHAIN:-}" ]]; then
  pin="$(dirname "$OMG_SIGNING_KEYCHAIN")/signing-python.pin"
fi
if [[ -z "$python" && -n "$pin" && -f "$pin" ]]; then
  IFS= read -r python < "$pin"
  expected=$(awk 'NR == 2 {print; exit}' "$pin")
  [[ "$python" == /* && -x "$python" && "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "invalid or missing pinned signing interpreter; use OMG_SIGNING_PYTHON with the already-authorized executable" >&2; exit 1;
  }
  actual=$(/usr/bin/shasum -a 256 "$python" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || {
    echo "pinned signing interpreter changed; reauthorize explicitly with store-password (never change the signing identity)" >&2; exit 1;
  }
fi
if [[ -z "$python" ]]; then
  case "$command_name" in
    unlock|store-password)
      echo "no pinned signing interpreter; set OMG_SIGNING_PYTHON to the already-authorized absolute Python executable; see docs/RELEASING.md" >&2
      exit 1 ;;
    *) python=$(command -v python3) ;;
  esac
fi
[[ "$python" == /* && -x "$python" ]] || {
  echo "OMG_SIGNING_PYTHON must be an absolute executable path" >&2; exit 1;
}
exec "$python" "$repo_root/dist/macos/omg_signing.py" "$@"
