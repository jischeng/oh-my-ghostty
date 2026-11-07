#!/bin/bash
# The Mac GUI lives only in Tart; the iOS UI runs on the host's Simulator.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
skip_build=false
simulator=${OMG_MOBILE_SIMULATOR_ID:-}
reference=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=true; shift ;;
    --simulator) simulator=${2:?Simulator UUID required}; shift 2 ;;
    --changed-since) reference=${2:?Git reference required}; shift 2 ;;
    *) echo "usage: $0 [--skip-build] [--simulator UUID] [--changed-since REF]" >&2; exit 64 ;;
  esac
done
devtool="$root/dist/macos/dev-tool.sh"
if [[ -n "$reference" ]]; then
  plan=$(bash "$devtool" python3 "$root/dist/omg_mobile_test_plan.py" --changed-since "$reference")
  echo "$plan"
  selected=$(printf '%s' "$plan" | bash "$devtool" python3 -c \
    'import json,sys; print(int(json.load(sys.stdin)["run_mobile"]))')
  [[ "$selected" == 1 ]] || exit 0
fi

source "$root/macos/scripts/vm/common.sh"
vm="$root/macos/scripts/vm/omg-vm"
run_id=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')
guest_directory="/tmp/omg-mobile-vm-$run_id"
evidence="${OMG_MOBILE_TEST_EVIDENCE:-/tmp/omg-mobile-vm-evidence-$run_id}"
mkdir -p "$evidence"
vm_started=false
fixture_started=false
cleanup() {
  result=$?
  trap - EXIT
  if $vm_started && [[ "$result" -ne 0 ]]; then
    "$vm" shot "$evidence/guest-failure.png" || true
    "$vm" logs >"$evidence/guest-failure.log" 2>&1 || true
  fi
  if $fixture_started; then
    omg_vm_ssh "if test -f '$guest_directory/fixture.pid'; then
      kill -TERM \"\$(cat '$guest_directory/fixture.pid')\" 2>/dev/null || true
    fi" || true
    omg_vm_ssh "for attempt in {1..30}; do
      test -f '$guest_directory/stopped' && break
      sleep 0.1
    done" || true
    for file in ready.json result.json output.bin gateway.log; do
      omg_vm_scp_from "$(omg_vm_ip)" "$guest_directory/$file" "$evidence/$file" 2>/dev/null || true
    done
    omg_vm_scp_from "$(omg_vm_ip)" "$guest_directory.log" "$evidence/fixture.log" 2>/dev/null || true
  fi
  if $vm_started; then "$vm" down || result=1; fi
  echo "Mobile VM evidence: $evidence"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! $skip_build; then
  (
    cd "$root"
    unset SDKROOT
    mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast \
      -Demit-xcframework=true -Dxcframework-target=native \
      -Demit-macos-app=false -Dversion-string=1.3.2-dev
    macos/build.nu --configuration Debug --action build
    rm -rf macos/build/Debug/OMG.app/Contents/Resources/session-runtime
    bash "$devtool" python3 dist/macos/build-session-runtime.py \
      --output macos/build/Debug/OMG.app/Contents/Resources/session-runtime --linux ""
    codesign --force --deep --sign - --timestamp=none macos/build/Debug/OMG.app
    ios/scripts/build.sh iphonesimulator
  )
fi
omg_vm_require_debug_app
if [[ -z "$simulator" ]]; then
  simulator=$(bash "$devtool" xcrun simctl list devices available -j |
    bash "$devtool" python3 -c '
import json,sys
devices=[d for runtime, items in json.load(sys.stdin)["devices"].items()
         if "iOS" in runtime for d in items if "iPhone" in d["name"]]
devices.sort(key=lambda d: d["state"] != "Booted")
if not devices: sys.exit("Install an iOS Simulator runtime first.")
print(devices[0]["udid"])')
fi
if ! bash "$devtool" xcrun simctl list devices booted -j |
  bash "$devtool" python3 -c \
    'import json,sys; sys.exit(0 if any(d["udid"]==sys.argv[1] for ds in json.load(sys.stdin)["devices"].values() for d in ds) else 1)' "$simulator"; then
  bash "$devtool" xcrun simctl boot "$simulator"
fi
bash "$devtool" xcrun simctl bootstatus "$simulator" -b
vm_started=true
"$vm" up
"$vm" deploy
"$vm" provision
# The retained guest can contain restored sessions from an older runtime epoch.
# Reset only its disposable Dev profile before starting this integration test.
omg_vm_ssh bash -s <<'GUEST'
set -euo pipefail
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/OMG.app/Contents/Info.plist)" == com.jischeng.omg.debug ]]
defaults delete com.jischeng.omg.debug >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Application Support/OMG Dev" \
  "$HOME/Library/Saved Application State/com.jischeng.omg.debug.savedState" \
  "$HOME/.config/oh-my-ghostty-dev"
GUEST
"$vm" run
ip=$(omg_vm_ip)
omg_vm_ssh "command -v python3 >/dev/null" || omg_vm_die "Guest needs Python 3"
omg_vm_scp_to "$ip" "$root/ios/scripts/vm-fixture.py" /tmp/omg-mobile-vm-fixture.py
fixture_started=true
omg_vm_ssh "nohup python3 /tmp/omg-mobile-vm-fixture.py \
  --directory '$guest_directory' --listen '$ip:18790' \
  >'$guest_directory.log' 2>&1 </dev/null &"
ready=false
for attempt in $(seq 1 40); do
  if omg_vm_ssh "test -s '$guest_directory/ready.json'"; then ready=true; break; fi
  if omg_vm_ssh "test -f '$guest_directory/stopped'"; then break; fi
  sleep 1
done
if ! $ready; then
  omg_vm_ssh "cat '$guest_directory.log'" >&2 || true
  omg_vm_die "Guest GUI session fixture did not become ready"
fi
omg_vm_scp_from "$ip" "$guest_directory/ready.json" "$evidence/ready.json"
session_id=$(bash "$devtool" python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$evidence/ready.json")
(
  cd "$root"
  xcodegen generate --spec ios/project.yml
  bash "$devtool" xcrun xcodebuild -project ios/OMGMobile.xcodeproj -scheme OMGMobile \
    -configuration Debug -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath ios/.build/app -resultBundlePath "$evidence/Simulator.xcresult" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    -parallel-testing-enabled NO \
    "OMG_MOBILE_UI_SERVER=$ip:18790" "OMG_MOBILE_UI_SESSION=$session_id" \
    OMG_MOBILE_UI_VM=YES test
) >"$evidence/simulator.log" 2>&1 || {
  tail -n 60 "$evidence/simulator.log" >&2
  exit 1
}
received=false
for attempt in $(seq 1 15); do
  if omg_vm_ssh "test -s '$guest_directory/result.json'"; then received=true; break; fi
  sleep 1
done
$received || omg_vm_die "Simulator finished without the guest execution receipts"
omg_vm_scp_from "$ip" "$guest_directory/result.json" "$evidence/result.json"
bash "$devtool" python3 - "$evidence/result.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1]))
for key in ("mobile_executed", "mac_gui_reclaimed", "mobile_reconnected", "same_pid_and_generation"):
    if result.get(key) is not True:
        sys.exit(f"Missing execution receipt: {key}")
print(json.dumps(result, indent=2))
PY
"$vm" shot "$evidence/guest.png"
