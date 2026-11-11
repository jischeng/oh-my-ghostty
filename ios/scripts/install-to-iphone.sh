#!/bin/bash
# Sign, build, and install OMG Mobile onto a connected physical iPhone or iPad.
# Works from a prebuilt OMG-Mobile-<version>-ios release archive (no Zig/Rust/XcodeGen
# needed) or from a source checkout after running ios/scripts/build-vt.sh iphoneos.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
if [[ -d "$script_dir/ios/OMGMobile.xcodeproj" || -f "$script_dir/ios/project.yml" ]]; then
  ios_dir="$script_dir/ios"
elif [[ -d "$script_dir/../OMGMobile.xcodeproj" || -f "$script_dir/../project.yml" ]]; then
  ios_dir=$(cd "$script_dir/.." && pwd)
else
  echo "error: could not locate ios/ directory relative to $script_dir" >&2
  exit 1
fi

team_id=${OMG_IOS_DEVELOPMENT_TEAM:-}
device_query=${OMG_IOS_DEVICE:-}
bundle_id=${OMG_MOBILE_BUNDLE_ID:-}
launch_after_install=true

usage() {
  cat <<'EOF'
Usage: ./install-to-iphone.sh [options]

Options:
  --team <TEAM_ID>        10-character Apple Development Team ID (auto-detected if omitted)
  --device <UDID|NAME>    Connected iPhone/iPad UDID or name (auto-detected if omitted)
  --bundle-id <BUNDLE_ID> Override app bundle ID (defaults to com.jischeng.omg.mobile.<team>)
  --no-launch             Install without launching the app
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) team_id=${2:?missing value for --team}; shift 2 ;;
    --device) device_query=${2:?missing value for --device}; shift 2 ;;
    --bundle-id) bundle_id=${2:?missing value for --bundle-id}; shift 2 ;;
    --no-launch) launch_after_install=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: full Xcode is required. Install Xcode from the App Store and run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'." >&2
  exit 1
}

if [[ ! -f "$ios_dir/.build/vt/iphoneos/libghostty-vt.a" ]]; then
  if [[ -x "$ios_dir/scripts/build-vt.sh" ]] && command -v zig >/dev/null 2>&1 || command -v mise >/dev/null 2>&1; then
    echo "==> Building libghostty-vt.a for iphoneos..."
    "$ios_dir/scripts/build-vt.sh" iphoneos
  else
    echo "error: missing prebuilt $ios_dir/.build/vt/iphoneos/libghostty-vt.a." >&2
    echo "Download OMG-Mobile-<version>-ios-installer.tar.gz from GitHub Releases so Zig is not needed." >&2
    exit 1
  fi
fi

if [[ ! -d "$ios_dir/OMGMobile.xcodeproj" ]]; then
  command -v xcodegen >/dev/null 2>&1 || {
    echo "error: OMGMobile.xcodeproj is missing and xcodegen is not installed." >&2
    exit 1
  }
  (unset SDKROOT; xcodegen generate --spec "$ios_dir/project.yml")
fi

if [[ -z "$team_id" ]]; then
  team_id=$(python3 - <<'PY'
import plistlib, re, subprocess, sys

teams = []
out = subprocess.run(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    capture_output=True, text=True
).stdout
for _, label in re.findall(r'\b([0-9A-F]{40})\s+"([^"]+)"', out):
    if "Apple Development" in label or "iPhone Developer" in label:
        pem = subprocess.run(
            ["security", "find-certificate", "-Z", "-p", "-c", label],
            capture_output=True, text=True
        ).stdout
        subj = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
            input=pem, capture_output=True, text=True
        ).stdout
        m = re.search(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", subj.strip())
        if m and m.group(1) not in teams:
            teams.append(m.group(1))

if not teams:
    raw = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True)
    if raw.returncode == 0 and raw.stdout:
        prefs = plistlib.loads(raw.stdout)
        for entries in (prefs.get("IDEProvisioningTeams") or {}).values():
            if isinstance(entries, list):
                for entry in entries:
                    tid = entry.get("teamID") if isinstance(entry, dict) else None
                    if isinstance(tid, str) and re.fullmatch(r"[A-Z0-9]{10}", tid) and tid not in teams:
                        teams.append(tid)

if not teams:
    sys.exit(1)
print(teams[0])
PY
  ) || {
    cat >&2 <<'EOF'
error: no Apple Development team found on this Mac.
1. Open Xcode -> Settings -> Accounts and sign in with your Apple ID (a free Personal Team Apple ID works).
2. Re-run ./install-to-iphone.sh (or pass --team <YOUR_10_CHAR_TEAM_ID>).
EOF
    exit 1
  }
fi

if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: invalid Apple Team ID '$team_id' (expected 10 uppercase letters/digits)." >&2
  exit 1
fi

tmp_json=$(mktemp "${TMPDIR:-/tmp}/omg-devicectl.XXXXXX.json")
derived_data=$(mktemp -d "${TMPDIR:-/tmp}/omg-mobile-install.XXXXXX")
trap 'rm -f "$tmp_json"; rm -rf "$derived_data"' EXIT

xcrun devicectl list devices --json-output "$tmp_json" >/dev/null 2>&1 || {
  echo "error: failed to query connected iOS devices via 'xcrun devicectl'." >&2
  exit 1
}

device_info=$(python3 - "$tmp_json" "$device_query" <<'PY'
import json, sys

path, query = sys.argv[1], sys.argv[2].strip()
data = json.loads(open(path, encoding="utf-8").read())
devices = data.get("result", {}).get("devices", [])

candidates = []
paired_offline = []
for d in devices:
    hw = d.get("hardwareProperties") or {}
    conn = d.get("connectionProperties") or {}
    props = d.get("deviceProperties") or {}
    if hw.get("reality") != "physical":
        continue
    if hw.get("platform") not in ("iOS", "iPadOS"):
        continue
    udid = hw.get("udid") or ""
    core_id = d.get("identifier") or udid
    name = props.get("name") or "iPhone"
    if query and query not in (udid, core_id, name) and query.lower() not in name.lower():
        continue
    tunnel = conn.get("tunnelState") or ""
    transport = conn.get("transportType")
    if conn.get("pairingState") == "paired" and (
        transport is not None or tunnel in ("connected", "availableForTunnel", "connecting")
    ):
        candidates.append((udid, core_id, name))
    else:
        paired_offline.append((udid, core_id, name, tunnel))

if not candidates:
    if paired_offline:
        names = ", ".join(f"{n} ({u})" for u, _, n, _ in paired_offline)
        sys.stderr.write(
            f"error: found paired iOS device(s) [{names}], but none are currently reachable.\n"
            "Connect your iPhone via USB, unlock it, trust this Mac, and ensure Developer Mode is enabled\n"
            "(Settings -> Privacy & Security -> Developer Mode).\n"
        )
    else:
        sys.stderr.write(
            "error: no connected physical iPhone or iPad found.\n"
            "1. Connect your iPhone to this Mac via USB and unlock the screen.\n"
            "2. Tap 'Trust' on the iPhone if prompted.\n"
            "3. Enable Settings -> Privacy & Security -> Developer Mode on the iPhone.\n"
        )
    sys.exit(1)

udid, core_id, name = candidates[0]
print(f"{udid}\t{core_id}\t{name}")
PY
)

IFS=$'\t' read -r device_udid device_core_id device_name <<<"$device_info"

if [[ -z "$bundle_id" ]]; then
  team_lower=$(printf '%s' "$team_id" | tr '[:upper:]' '[:lower:]')
  bundle_id="com.jischeng.omg.mobile.${team_lower}"
fi

echo "==> Target device : $device_name ($device_udid)"
echo "==> Bundle ID     : $bundle_id"
echo "==> Building & signing OMG Mobile (Release)..."

unset SDKROOT
xcodebuild \
  -project "$ios_dir/OMGMobile.xcodeproj" \
  -scheme OMGMobile \
  -configuration Release \
  -destination "platform=iOS,id=$device_udid" \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  "DEVELOPMENT_TEAM=$team_id" \
  "OMG_MOBILE_BUNDLE_ID=$bundle_id" \
  "CODE_SIGN_STYLE=Automatic" \
  build

app_path="$derived_data/Build/Products/Release-iphoneos/OMGMobile.app"
[[ -d "$app_path" ]] || {
  echo "error: expected built app at $app_path" >&2
  exit 1
}

echo "==> Installing OMG Mobile onto $device_name..."
xcrun devicectl device install app --device "$device_core_id" "$app_path"

if [[ "$launch_after_install" == true ]]; then
  echo "==> Launching OMG Mobile..."
  if ! xcrun devicectl device process launch --device "$device_core_id" "$bundle_id" >/dev/null 2>&1; then
    cat <<EOF

Installed OMG Mobile onto '$device_name'!
Note: If this is your first install with a personal Apple ID, unlock your iPhone and trust
your developer profile once under:
  Settings -> General -> VPN & Device Management
Then open 'OMG Mobile' and pair with your Mac by running 'omg +mobile' (or opening OMG Settings -> Mobile Devices).
EOF
    exit 0
  fi
fi

cat <<EOF

Successfully installed and launched OMG Mobile on '$device_name'!
Next step: run 'omg +mobile' in an OMG terminal (or open OMG Settings -> Mobile Devices)
and scan the pairing QR code from OMG Mobile.
EOF
