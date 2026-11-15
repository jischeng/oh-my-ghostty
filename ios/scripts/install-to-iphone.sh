#!/bin/bash
# Build (or re-sign an IPA) and install OMGMobile onto a paired physical iPhone/iPad
# over USB or Wi-Fi without opening Xcode GUI.
#
# Usage:
#   ios/scripts/install-to-iphone.sh [--device <name-or-udid>] [--bundle-id <id>]
#       [--team <team-id>] [--ipa <path>] [--refresh] [--no-launch] [--timeout <sec>]
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-to-iphone.sh [options] [device-name-or-udid]

Options:
  --device <name-or-udid>  Target paired iPhone/iPad (default: auto-select unique iOS device)
  --team <team-id>         Apple Developer 10-char Team ID (default: auto-detect)
  --bundle-id <id>         Explicit bundle identifier override (default: preserve installed)
  --ipa <path>             Install/refresh from an existing .ipa or .app bundle (fast resign)
  --refresh                Force Apple Developer portal profile refresh (-allowProvisioningUpdates)
  --no-launch              Skip launching OMG Mobile on the device after installation
  --timeout <seconds>      devicectl command timeout in seconds (default: 60)
  --dry-run                Resolve device, team, bundle ID, and signing plan without modifying device
  -h, --help               Show this help
EOF
}

device_query=""
explicit_team=""
explicit_bundle_id=""
ipa_input=""
force_refresh=0
no_launch=0
timeout_seconds=60
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "error: --device requires an argument" >&2; exit 64; }
      device_query=$2
      shift 2
      ;;
    --team)
      [[ $# -ge 2 ]] || { echo "error: --team requires an argument" >&2; exit 64; }
      explicit_team=$2
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || { echo "error: --bundle-id requires an argument" >&2; exit 64; }
      explicit_bundle_id=$2
      shift 2
      ;;
    --ipa)
      [[ $# -ge 2 ]] || { echo "error: --ipa requires a path" >&2; exit 64; }
      ipa_input=$2
      shift 2
      ;;
    --refresh)
      force_refresh=1
      shift
      ;;
    --no-launch)
      no_launch=1
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "error: --timeout requires seconds" >&2; exit 64; }
      timeout_seconds=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      if [[ -n "$device_query" ]]; then
        echo "error: unexpected positional argument: $1" >&2
        exit 64
      fi
      device_query=$1
      shift
      ;;
  esac
done

script_dir=$(cd "$(dirname "$0")" && pwd)
if [[ -f "$script_dir/ios/project.yml" ]]; then
  ios_dir="$script_dir/ios"
elif [[ -f "$script_dir/../project.yml" ]]; then
  ios_dir=$(cd "$script_dir/.." && pwd)
elif [[ -d "$script_dir/../OMGMobile.xcodeproj" ]]; then
  ios_dir=$(cd "$script_dir/.." && pwd)
else
  ios_dir="$script_dir"
fi

for tool in xcrun security codesign python3 plutil; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required macOS developer tool not found: $tool" >&2
    exit 1
  }
done
if [[ -z "$ipa_input" || "$force_refresh" == "1" ]]; then
  command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required (install Xcode from the App Store)" >&2
    exit 1
  }
fi
if [[ -n "$ipa_input" && ! -e "$ipa_input" ]]; then
  echo "error: --ipa path not found: $ipa_input" >&2
  exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/omg-mobile-install.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

devices_json="$work_dir/devices.json"
if ! xcrun devicectl list devices --timeout 20 --json-output "$devices_json" >/dev/null 2>&1; then
  # Retry once without --timeout in case an older devicectl lacks --timeout on list
  xcrun devicectl list devices --json-output "$devices_json" >/dev/null
fi

device_info=$(python3 - "$devices_json" "$device_query" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
query = sys.argv[2].strip()
raw_devices = payload.get("result", {}).get("devices", [])

parsed = []
for dev in raw_devices:
    props = dev.get("properties") if isinstance(dev.get("properties"), dict) else {}
    hw = props.get("hardware") if isinstance(props.get("hardware"), dict) else {}
    if not hw and isinstance(dev.get("hardwareProperties"), dict):
        hw = dev["hardwareProperties"]
    dev_props = dev.get("deviceProperties") if isinstance(dev.get("deviceProperties"), dict) else {}
    conn = props.get("connection") if isinstance(props.get("connection"), dict) else {}
    if not conn and isinstance(dev.get("connectionProperties"), dict):
        conn = dev["connectionProperties"]
    state_obj = props.get("state") if isinstance(props.get("state"), dict) else {}

    udid = str(hw.get("udid") or "").strip()
    identifier = str(dev.get("identifier") or "").strip()
    name = str(dev.get("name") or dev_props.get("name") or props.get("name") or "").strip()
    platform = str(hw.get("platform") or "").strip()
    device_type = str(hw.get("deviceType") or "").strip()
    reality = str(hw.get("reality") or dev.get("reality") or "").strip().lower()
    transport = str(conn.get("transportType") or conn.get("interfaceType") or "unknown").strip()
    raw_transport = transport.lower()
    pairing_state = str(conn.get("pairingState") or "").strip()
    pairing_low = pairing_state.lower()
    state_name = str(
        state_obj.get("name")
        or (dev.get("state") if isinstance(dev.get("state"), str) else "")
        or conn.get("tunnelState")
        or ""
    ).strip()
    os_ver = str(dev_props.get("osVersionNumber") or props.get("osVersionNumber") or "").strip()

    if (reality and reality != "physical") or raw_transport == "samemachine" or pairing_low == "unpaired":
        continue

    is_ios = (
        "iOS" in platform
        or "iPadOS" in platform
        or device_type.lower() in ("iphone", "ipad")
        or (not platform and not device_type and bool(udid))
    )
    if not is_ios or not (udid or identifier):
        continue
    parsed.append({
        "udid": udid or identifier,
        "identifier": identifier or udid,
        "name": name or (udid or identifier),
        "platform": platform,
        "os": os_ver,
        "transport": transport,
        "pairing": pairing_state,
        "state": state_name,
    })

if not parsed:
    sys.stderr.write(
        "error: no paired iPhone or iPad found via `xcrun devicectl list devices`.\n"
        "Next steps:\n"
        "  1. Connect your iPhone to this Mac via USB and tap 'Trust' on the iPhone.\n"
        "  2. Enable Settings -> Privacy & Security -> Developer Mode on the iPhone.\n"
        "  3. Open Xcode -> Window -> Devices and Simulators once to complete pairing (and enable 'Connect via network').\n"
    )
    sys.exit(2)

matches = parsed
if query:
    q_low = query.lower()
    exact = [
        d for d in parsed
        if d["udid"].lower() == q_low or d["identifier"].lower() == q_low or d["name"].lower() == q_low
    ]
    if exact:
        matches = exact
    else:
        sub = [
            d for d in parsed
            if q_low in d["udid"].lower() or q_low in d["identifier"].lower() or q_low in d["name"].lower()
        ]
        matches = sub

if not matches:
    sys.stderr.write(f"error: no paired iOS device matching {query!r}. Available devices:\n")
    for d in parsed:
        sys.stderr.write(f"  - {d['name']} ({d['udid']}, transport={d['transport']})\n")
    sys.exit(2)

if len(matches) > 1:
    # Prefer wired over localNetwork if not explicitly queried by multiple, unless still ambiguous
    if not query:
        wired = [d for d in matches if "wired" in d["transport"].lower() or "usb" in d["transport"].lower()]
        if len(wired) == 1:
            matches = wired
    if len(matches) > 1:
        sys.stderr.write("error: multiple paired iOS devices found; pass --device <name-or-udid>:\n")
        for d in matches:
            sys.stderr.write(f"  - {d['name']} ({d['udid']}, transport={d['transport']})\n")
        sys.exit(2)

sel = matches[0]
print(json.dumps(sel))
PY
)

{
  IFS= read -r DEVICE_UDID
  IFS= read -r DEVICE_ID
  IFS= read -r DEVICE_NAME
  IFS= read -r DEVICE_TRANSPORT
} < <(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for key in ("udid", "identifier", "name", "transport"):
    print(str(d[key]).replace("\n", " "))
' "$device_info")

echo "[ios] target device: $DEVICE_NAME ($DEVICE_UDID, transport=$DEVICE_TRANSPORT)" >&2

# Probe installed com.jischeng.omg.mobile* app on device so we never wipe Keychain/UserDefaults pairings.
apps_json="$work_dir/apps.json"
INSTALLED_BUNDLE_ID=""
if xcrun devicectl device info apps --device "$DEVICE_ID" --timeout 15 --json-output "$apps_json" >/dev/null 2>&1; then
  INSTALLED_BUNDLE_ID=$(python3 - "$apps_json" <<'PY'
import json, sys
try:
    payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    sys.exit(0)
apps = payload.get("result", {}).get("apps", [])
found = []
for app in apps:
    props = app.get("properties") if isinstance(app.get("properties"), dict) else {}
    bid = str(app.get("bundleIdentifier") or props.get("bundleIdentifier") or "").strip()
    if bid.startswith("com.jischeng.omg.mobile"):
        found.append(bid)
if "com.jischeng.omg.mobile" in found:
    print("com.jischeng.omg.mobile")
elif found:
    print(sorted(found)[0])
PY
)
fi
if [[ -n "$INSTALLED_BUNDLE_ID" ]]; then
  echo "[ios] detected installed app bundle ID on device: $INSTALLED_BUNDLE_ID" >&2
fi

# Discover valid Keychain signing identities & matching Apple Development teams + cached profiles.
signing_plan=$(python3 - "$explicit_team" "$explicit_bundle_id" "$INSTALLED_BUNDLE_ID" "$DEVICE_UDID" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

explicit_team = sys.argv[1].strip()
explicit_bundle = sys.argv[2].strip()
installed_bundle = sys.argv[3].strip()
device_udid = sys.argv[4].strip()

# 1. Inspect valid Keychain "Apple Development" identities.
ident_out = subprocess.run(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    capture_output=True, text=True
).stdout

identities = []
pem_blocks = {}
all_certs_out = subprocess.run(
    ["security", "find-certificate", "-a", "-Z", "-p"],
    capture_output=True, text=True
).stdout
cur_sha1 = ""
cur_pem = []
in_pem = False
for cline in all_certs_out.splitlines():
    m_hash = re.match(r'^SHA-1 hash:\s*([0-9A-Fa-f]{40})', cline)
    if m_hash:
        cur_sha1 = m_hash.group(1).upper()
        continue
    if "-----BEGIN CERTIFICATE-----" in cline:
        in_pem = True
        cur_pem = [cline]
    elif "-----END CERTIFICATE-----" in cline and in_pem:
        cur_pem.append(cline)
        if cur_sha1:
            pem_blocks[cur_sha1] = "\n".join(cur_pem) + "\n"
        in_pem = False
        cur_sha1 = ""
        cur_pem = []
    elif in_pem:
        cur_pem.append(cline)

for line in ident_out.splitlines():
    if "CSSMERR_" in line or "REVOKED" in line:
        continue
    m = re.match(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', line)
    if not m:
        continue
    sha1, name = m.group(1).upper(), m.group(2)
    if "Apple Development" not in name and "iPhone Developer" not in name:
        continue
    cert_pem = pem_blocks.get(sha1, "")
    if not cert_pem:
        cert_pem = subprocess.run(
            ["security", "find-certificate", "-c", name, "-p"],
            capture_output=True, text=True
        ).stdout
    ou = ""
    if cert_pem.strip():
        subj = subprocess.run(
            ["openssl", "x509", "-noout", "-subject"],
            input=cert_pem, capture_output=True, text=True
        ).stdout
        m_ou = re.search(r'\bOU\s*=\s*([A-Z0-9]{10})\b', subj)
        if m_ou:
            ou = m_ou.group(1)
    identities.append({"sha1": sha1, "name": name, "team": ou})

# 2. Read Xcode configured teams fallback.
xcode_teams = []
defaults_res = subprocess.run(
    ["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeams"],
    capture_output=True, text=True
)
if defaults_res.returncode == 0:
    xcode_teams = sorted(set(re.findall(r'teamID\s*=\s*"?([A-Z0-9]{10})"?', defaults_res.stdout)))

# Select team
team_id = explicit_team
if not team_id:
    cert_teams = sorted({i["team"] for i in identities if i["team"]})
    if len(cert_teams) == 1:
        team_id = cert_teams[0]
    elif len(cert_teams) > 1:
        # Narrow against xcode_teams if possible
        overlap = sorted(set(cert_teams) & set(xcode_teams))
        if len(overlap) == 1:
            team_id = overlap[0]
        else:
            sys.stderr.write(f"error: multiple Apple Development teams in Keychain ({', '.join(cert_teams)}); pass --team <TEAM_ID>\n")
            sys.exit(2)
    elif len(xcode_teams) == 1:
        team_id = xcode_teams[0]
    elif len(xcode_teams) > 1:
        sys.stderr.write(f"error: multiple Xcode teams found ({', '.join(xcode_teams)}); pass --team <TEAM_ID>\n")
        sys.exit(2)

if not team_id:
    sys.stderr.write(
        "error: could not detect an Apple Developer Team ID or Apple Development certificate.\n"
        "Next steps:\n"
        "  1. Open Xcode -> Settings -> Accounts and add your Apple ID (free Personal Team works).\n"
        "  2. Click 'Manage Certificates...' -> '+' -> 'Apple Development'.\n"
    )
    sys.exit(2)

matching_idents = [i for i in identities if i["team"] == team_id]
if not matching_idents:
    # Fall back to any Apple Development identity only if OU extraction missed
    matching_idents = [i for i in identities if not i["team"]]
cert_sha1 = matching_idents[0]["sha1"] if matching_idents else ""

# 3. Scan Provisioning Profiles directories (Xcode 15 + Xcode 16+).
profile_dirs = [
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
]
now_utc = datetime.now(timezone.utc)
valid_profiles = []
for pdir in profile_dirs:
    if not pdir.is_dir():
        continue
    for pfile in sorted(pdir.glob("*.mobileprovision")):
        cms = subprocess.run(["security", "cms", "-D", "-i", str(pfile)], capture_output=True)
        if cms.returncode != 0:
            continue
        try:
            plist = plistlib.loads(cms.stdout)
        except Exception:
            continue
        teams = plist.get("TeamIdentifier") or []
        if team_id not in teams:
            continue
        exp = plist.get("ExpirationDate")
        if isinstance(exp, datetime):
            if exp.tzinfo is None:
                exp = exp.replace(tzinfo=timezone.utc)
            if exp.timestamp() <= now_utc.timestamp() + 60:
                continue
        else:
            continue
        devices = plist.get("ProvisionedDevices") or []
        all_devs = bool(plist.get("ProvisionsAllDevices", False))
        if not all_devs and device_udid not in devices:
            continue
        prof_certs = set()
        for raw_cert in plist.get("DeveloperCertificates") or []:
            if isinstance(raw_cert, (bytes, bytearray)):
                prof_certs.add(hashlib.sha1(raw_cert).hexdigest().upper())
        if cert_sha1 and prof_certs and cert_sha1 not in prof_certs:
            # Also check if any valid identity matches prof_certs for this team
            matched_cert = next((i["sha1"] for i in matching_idents if i["sha1"] in prof_certs), "")
            if not matched_cert:
                continue
            ident_sha1 = matched_cert
        else:
            ident_sha1 = cert_sha1

        entitlements = plist.get("Entitlements") if isinstance(plist.get("Entitlements"), dict) else {}
        app_id = str(entitlements.get("application-identifier") or "")
        prefix = f"{team_id}."
        if not app_id.startswith(prefix):
            continue
        prof_bundle = app_id[len(prefix):]
        valid_profiles.append({
            "path": str(pfile),
            "uuid": str(plist.get("UUID") or ""),
            "bundle_id": prof_bundle,
            "is_wildcard": prof_bundle == "*",
            "expires_at": exp.isoformat(),
            "seconds_left": int(exp.timestamp() - now_utc.timestamp()),
            "cert_sha1": ident_sha1,
            "entitlements": entitlements,
        })

# 4. Determine target bundle ID preserving installed app / existing profile pairings.
bundle_id = explicit_bundle or installed_bundle
if not bundle_id:
    omg_profiles = [
        p for p in valid_profiles
        if p["bundle_id"].startswith("com.jischeng.omg.mobile")
    ]
    if any(p["bundle_id"] == "com.jischeng.omg.mobile" for p in omg_profiles):
        bundle_id = "com.jischeng.omg.mobile"
    elif omg_profiles:
        bundle_id = sorted(p["bundle_id"] for p in omg_profiles)[0]
    else:
        bundle_id = "com.jischeng.omg.mobile"

# Find exact or wildcard matching profile for bundle_id
chosen_profile = None
exact_matches = [p for p in valid_profiles if p["bundle_id"] == bundle_id]
wildcard_matches = [p for p in valid_profiles if p["is_wildcard"]]
if exact_matches:
    chosen_profile = sorted(exact_matches, key=lambda p: p["seconds_left"], reverse=True)[0]
elif wildcard_matches:
    chosen_profile = sorted(wildcard_matches, key=lambda p: p["seconds_left"], reverse=True)[0]

print(json.dumps({
    "team_id": team_id,
    "bundle_id": bundle_id,
    "installed_bundle_id": installed_bundle,
    "cert_sha1": (chosen_profile["cert_sha1"] if chosen_profile and chosen_profile["cert_sha1"] else cert_sha1),
    "profile": chosen_profile,
}))
PY
)

{
  IFS= read -r TEAM_ID
  IFS= read -r BUNDLE_ID
  IFS= read -r INSTALLED_BUNDLE_ID
  IFS= read -r CERT_SHA1
  IFS= read -r PROFILE_PATH
  IFS= read -r PROFILE_UUID
  IFS= read -r PROFILE_EXPIRES
} < <(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
p = d.get("profile") or {}
for v in (
    d["team_id"],
    d["bundle_id"],
    d.get("installed_bundle_id") or "",
    d.get("cert_sha1") or "",
    p.get("path") or "",
    p.get("uuid") or "",
    p.get("expires_at") or "",
):
    print(str(v).replace("\n", " "))
' "$signing_plan")

echo "[ios] team=$TEAM_ID bundle_id=$BUNDLE_ID cert=${CERT_SHA1:-none}" >&2

if [[ "$dry_run" == "1" ]]; then
  python3 -c '
import json, sys
print(json.dumps({
    "device_udid": sys.argv[1],
    "device_name": sys.argv[2],
    "transport": sys.argv[3],
    "team_id": sys.argv[4],
    "bundle_id": sys.argv[5],
    "installed_bundle_id": sys.argv[6],
    "cert_sha1": sys.argv[7],
    "cached_profile_uuid": sys.argv[8],
    "cached_profile_expires": sys.argv[9],
    "refresh_requested": sys.argv[10] == "1",
}))
' "$DEVICE_UDID" "$DEVICE_NAME" "$DEVICE_TRANSPORT" "$TEAM_ID" "$BUNDLE_ID" "$INSTALLED_BUNDLE_ID" "$CERT_SHA1" "$PROFILE_UUID" "$PROFILE_EXPIRES" "$force_refresh"
  exit 0
fi

resign_app_inside_out() {
  local src_app=$1
  local dest_app=$2
  local profile_file=$3
  local target_bundle=$4
  local sign_identity=$5

  rm -rf "$dest_app"
  mkdir -p "$(dirname "$dest_app")"
  ditto "$src_app" "$dest_app"

  python3 - "$dest_app" "$profile_file" "$target_bundle" "$work_dir/entitlements.plist" <<'PY'
import plistlib
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
prof_path = Path(sys.argv[2])
target_bundle = sys.argv[3]
ent_out = Path(sys.argv[4])

cms = subprocess.run(["security", "cms", "-D", "-i", str(prof_path)], check=True, capture_output=True)
prof = plistlib.loads(cms.stdout)
ent = prof.get("Entitlements") or {}
if isinstance(ent, dict) and "application-identifier" in ent:
    teams = prof.get("TeamIdentifier") or []
    if teams:
        ent = dict(ent)
        app_id = str(ent["application-identifier"])
        if app_id.endswith(".*"):
            ent["application-identifier"] = f"{teams[0]}.{target_bundle}"
ent_out.write_bytes(plistlib.dumps(ent))

info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
if info.get("CFBundleIdentifier") != target_bundle:
    info["CFBundleIdentifier"] = target_bundle
url_types = info.get("CFBundleURLTypes")
if isinstance(url_types, list) and url_types and isinstance(url_types[0], dict):
    url_types[0]["CFBundleURLName"] = target_bundle
info_path.write_bytes(plistlib.dumps(info))

stream_plist = app / "Frameworks" / "TermioStream.framework" / "Info.plist"
if stream_plist.is_file():
    s_info = plistlib.loads(stream_plist.read_bytes())
    desired_stream = f"{target_bundle}.stream"
    if s_info.get("CFBundleIdentifier") != desired_stream:
        s_info["CFBundleIdentifier"] = desired_stream
        stream_plist.write_bytes(plistlib.dumps(s_info))
PY

  find "$dest_app" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
  cp "$profile_file" "$dest_app/embedded.mobileprovision"

  while IFS= read -r item; do
    codesign --force --sign "$sign_identity" --timestamp=none "$item"
  done < <(find "$dest_app" \( -path "$dest_app/Frameworks/*" -o -path "$dest_app/PlugIns/*" \) \( -name "*.dylib" -o -name "*.framework" -o -name "*.appex" \) 2>/dev/null | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

  codesign --force --sign "$sign_identity" --entitlements "$work_dir/entitlements.plist" --generate-entitlement-der --timestamp=none "$dest_app"
  codesign --verify --deep --strict "$dest_app"
}

run_portal_refresh_xcodebuild() {
  local target_bundle=$1
  local build_log="$work_dir/xcodebuild-refresh.log"

  if [[ -d "$ios_dir/OMGMobile.xcodeproj" && -z "$ipa_input" ]]; then
    ensure_project_and_vt
    local derived_data="$ios_dir/.build/iphoneos-release"
    mkdir -p "$derived_data"
    set +e
    (
      unset SDKROOT
      xcodebuild \
        -project "$ios_dir/OMGMobile.xcodeproj" \
        -scheme OMGMobile \
        -configuration Release \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$derived_data" \
        -allowProvisioningUpdates \
        "DEVELOPMENT_TEAM=$TEAM_ID" \
        "CODE_SIGN_STYLE=Automatic" \
        "OMG_MOBILE_BUNDLE_ID=$target_bundle" \
        build
    ) >"$build_log" 2>&1
    local status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      built_app="$derived_data/Build/Products/Release-iphoneos/OMGMobile.app"
      return 0
    fi
    cat "$build_log" >&2
    return $status
  else
    # IPA mode requiring portal profile renewal: generate minimal ProvisioningStub project
    local stub_dir="$work_dir/stub"
    mkdir -p "$stub_dir/StubApp.xcodeproj" "$stub_dir/Sources"
    cat > "$stub_dir/Sources/main.c" <<'C'
int main(void) { return 0; }
C
    cat > "$stub_dir/Sources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleExecutable</key>
  <string>StubApp</string>
  <key>CFBundleName</key>
  <string>StubApp</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>
PLIST
    cat > "$stub_dir/StubApp.xcodeproj/project.pbxproj" <<PBX
// !\$*UTF8*\$!
{
  archiveVersion = 1;
  classes = {};
  objectVersion = 56;
  objects = {
    AA000001 = { isa = PBXBuildFile; fileRef = AA000002; };
    AA000002 = { isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = Sources/main.c; sourceTree = "<group>"; };
    AA000003 = { isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = StubApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
    AA000004 = { isa = PBXGroup; children = (AA000002, AA000003); sourceTree = "<group>"; };
    AA000005 = { isa = PBXNativeTarget; buildConfigurationList = AA000008; buildPhases = (AA000006); buildRules = (); dependencies = (); name = StubApp; productName = StubApp; productReference = AA000003; productType = "com.apple.product-type.application"; };
    AA000006 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (AA000001); runOnlyForDeploymentPostprocessing = 0; };
    AA000007 = { isa = PBXProject; attributes = { LastUpgradeCheck = 1500; }; buildConfigurationList = AA000009; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; mainGroup = AA000004; productRefGroup = AA000004; projectDirPath = ""; projectRoot = ""; targets = (AA000005); };
    AA000008 = { isa = XCConfigurationList; buildConfigurations = (AA000010); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    AA000009 = { isa = XCConfigurationList; buildConfigurations = (AA000011); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    AA000010 = { isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = "$TEAM_ID"; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Sources/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = "$target_bundle"; PRODUCT_NAME = StubApp; SDKROOT = iphoneos; }; name = Release; };
    AA000011 = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
  };
  rootObject = AA000007;
}
PBX
    set +e
    (
      unset SDKROOT
      xcodebuild \
        -project "$stub_dir/StubApp.xcodeproj" \
        -target StubApp \
        -configuration Release \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$stub_dir/derived" \
        -allowProvisioningUpdates \
        build
    ) >"$build_log" 2>&1
    local status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      return 0
    fi
    cat "$build_log" >&2
    return $status
  fi
}

ensure_project_and_vt() {
  if [[ -x "$ios_dir/scripts/build-vt.sh" && ! -f "$ios_dir/.build/vt/iphoneos/libghostty-vt.a" ]]; then
    if command -v zig >/dev/null 2>&1; then
      "$ios_dir/scripts/build-vt.sh" iphoneos
    else
      echo "error: missing $ios_dir/.build/vt/iphoneos/libghostty-vt.a and zig is not installed" >&2
      exit 1
    fi
  fi
  if [[ -f "$ios_dir/project.yml" ]]; then
    if [[ ! -f "$ios_dir/OMGMobile.xcodeproj/project.pbxproj" || "$ios_dir/project.yml" -nt "$ios_dir/OMGMobile.xcodeproj/project.pbxproj" ]]; then
      if command -v xcodegen >/dev/null 2>&1; then
        (unset SDKROOT; xcodegen generate --spec "$ios_dir/project.yml")
      elif [[ ! -d "$ios_dir/OMGMobile.xcodeproj" ]]; then
        echo "error: OMGMobile.xcodeproj missing and xcodegen is not installed (run: brew install xcodegen)" >&2
        exit 1
      fi
    fi
  fi
}

extract_ipa_app() {
  local input_path=$1
  local extract_dir="$work_dir/ipa_extract"
  mkdir -p "$extract_dir"
  if [[ -d "$input_path" ]]; then
    echo "$input_path"
    return 0
  fi
  /usr/bin/ditto -xk "$input_path" "$extract_dir"
  local candidate="$extract_dir/Payload/OMGMobile.app"
  if [[ ! -d "$candidate" ]]; then
    candidate=$(find "$extract_dir/Payload" -maxdepth 1 -name "*.app" -print -quit 2>/dev/null || true)
  fi
  [[ -n "$candidate" && -d "$candidate" ]] || {
    echo "error: no Payload/*.app found inside IPA $input_path" >&2
    exit 1
  }
  echo "$candidate"
}

find_latest_profile_for_bundle() {
  local target_bundle=$1
  python3 - "$TEAM_ID" "$target_bundle" "$DEVICE_UDID" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess
import sys

team_id, bundle_id, device_udid = sys.argv[1:4]
now_ts = datetime.now(timezone.utc).timestamp()
candidates = []
for pdir in [
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
]:
    if not pdir.is_dir():
        continue
    for pfile in pdir.glob("*.mobileprovision"):
        cms = subprocess.run(["security", "cms", "-D", "-i", str(pfile)], capture_output=True)
        if cms.returncode != 0:
            continue
        try:
            plist = plistlib.loads(cms.stdout)
        except Exception:
            continue
        if team_id not in (plist.get("TeamIdentifier") or []):
            continue
        exp = plist.get("ExpirationDate")
        if not isinstance(exp, datetime):
            continue
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=timezone.utc)
        if exp.timestamp() <= now_ts + 60:
            continue
        if not plist.get("ProvisionsAllDevices") and device_udid not in (plist.get("ProvisionedDevices") or []):
            continue
        app_id = str((plist.get("Entitlements") or {}).get("application-identifier") or "")
        if app_id in (f"{team_id}.{bundle_id}", f"{team_id}.*"):
            candidates.append((exp.timestamp(), str(pfile), str(plist.get("UUID") or ""), exp.isoformat()))

if not candidates:
    sys.exit(1)
candidates.sort(reverse=True)
_, path, uuid, exp_iso = candidates[0]
print(path)
print(uuid)
print(exp_iso)
PY
}

built_app=""
signed_app="$work_dir/signed/OMGMobile.app"
used_offline_profile=0

if [[ "$force_refresh" == "0" && -n "$PROFILE_PATH" && -n "$CERT_SHA1" ]]; then
  echo "[ios] using cached provisioning profile $PROFILE_UUID (expires $PROFILE_EXPIRES); offline signing without portal updates" >&2
  used_offline_profile=1
  if [[ -n "$ipa_input" ]]; then
    source_app=$(extract_ipa_app "$ipa_input")
  else
    ensure_project_and_vt
    derived_data="$ios_dir/.build/iphoneos-release"
    mkdir -p "$derived_data"
    (
      unset SDKROOT
      xcodebuild \
        -project "$ios_dir/OMGMobile.xcodeproj" \
        -scheme OMGMobile \
        -configuration Release \
        -sdk iphoneos \
        -derivedDataPath "$derived_data" \
        "ARCHS=arm64" \
        "ONLY_ACTIVE_ARCH=YES" \
        "CODE_SIGN_STYLE=Manual" \
        "CODE_SIGN_IDENTITY=" \
        "CODE_SIGNING_REQUIRED=NO" \
        "CODE_SIGNING_ALLOWED=NO" \
        "OMG_MOBILE_BUNDLE_ID=$BUNDLE_ID" \
        build
    )
    source_app="$derived_data/Build/Products/Release-iphoneos/OMGMobile.app"
  fi
  resign_app_inside_out "$source_app" "$signed_app" "$PROFILE_PATH" "$BUNDLE_ID" "$CERT_SHA1"
  app_to_install="$signed_app"
else
  if [[ "$force_refresh" == "1" ]]; then
    echo "[ios] --refresh requested; contacting Apple portal for provisioning profile renewal..." >&2
  else
    echo "[ios] no valid cached provisioning profile for ($TEAM_ID, $BUNDLE_ID, $DEVICE_UDID); renewing via Xcode portal..." >&2
  fi
  if ! run_portal_refresh_xcodebuild "$BUNDLE_ID"; then
    refresh_log="$work_dir/xcodebuild-refresh.log"
    if [[ -z "$explicit_bundle_id" && -z "$INSTALLED_BUNDLE_ID" && "$BUNDLE_ID" == "com.jischeng.omg.mobile" ]] && \
       grep -Eqi "cannot be registered to your development team|is not available|already registered|No profiles for 'com\.jischeng\.omg\.mobile'" "$refresh_log"; then
      team_lower=$(printf '%s' "$TEAM_ID" | tr '[:upper:]' '[:lower:]')
      fallback_bundle="com.jischeng.omg.mobile.$team_lower"
      echo "[ios] warning: Apple portal rejected '$BUNDLE_ID'; falling back to '$fallback_bundle' (note: isolated Keychain/UserDefaults scope)" >&2
      BUNDLE_ID="$fallback_bundle"
      if ! run_portal_refresh_xcodebuild "$BUNDLE_ID"; then
        echo "[ios] provisioning failed. Check Xcode -> Settings -> Accounts (re-sign in) or connect iPhone via USB to register UDID $DEVICE_UDID." >&2
        exit 1
      fi
    else
      echo "[ios] provisioning/build failed. Common fixes:" >&2
      echo "  - Apple ID session expired: open Xcode -> Settings -> Accounts and sign in again" >&2
      echo "  - Missing Apple Development cert: Xcode -> Settings -> Accounts -> Manage Certificates -> '+' -> Apple Development" >&2
      echo "  - Device not registered: connect $DEVICE_NAME once via USB with Xcode -> Window -> Devices and Simulators open" >&2
      exit 1
    fi
  fi

  # Capture renewed profile info & refresh CERT_SHA1 if Xcode portal just created one.
  if [[ -z "$CERT_SHA1" ]]; then
    CERT_SHA1=$(security find-identity -v -p codesigning | python3 -c 'import re,sys; print(next((m.group(1).upper() for l in sys.stdin if "Apple Development" in l and "CSSMERR_" not in l for m in [re.match(r"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+", l)] if m), ""))')
  fi
  if prof_lines=$(find_latest_profile_for_bundle "$BUNDLE_ID" 2>/dev/null); then
    PROFILE_PATH=$(printf '%s\n' "$prof_lines" | sed -n '1p')
    PROFILE_UUID=$(printf '%s\n' "$prof_lines" | sed -n '2p')
    PROFILE_EXPIRES=$(printf '%s\n' "$prof_lines" | sed -n '3p')
  fi

  if [[ -n "$ipa_input" ]]; then
    [[ -n "$PROFILE_PATH" && -n "$CERT_SHA1" ]] || {
      echo "error: portal provisioning succeeded, but matching profile/cert could not be located to re-sign IPA" >&2
      exit 1
    }
    source_app=$(extract_ipa_app "$ipa_input")
    resign_app_inside_out "$source_app" "$signed_app" "$PROFILE_PATH" "$BUNDLE_ID" "$CERT_SHA1"
    app_to_install="$signed_app"
  else
    app_to_install="$built_app"
  fi
fi

echo "[ios] installing $BUNDLE_ID onto $DEVICE_NAME ($DEVICE_UDID, timeout=${timeout_seconds}s)..." >&2
xcrun devicectl device install app --device "$DEVICE_ID" --timeout "$timeout_seconds" "$app_to_install"

if [[ "$no_launch" == "0" ]]; then
  echo "[ios] launching $BUNDLE_ID on $DEVICE_NAME..." >&2
  if ! xcrun devicectl device process launch --device "$DEVICE_ID" --timeout "$timeout_seconds" "$BUNDLE_ID"; then
    echo "[ios] installed successfully, but launch failed (if iPhone screen is locked, unlock and open OMG Mobile manually)." >&2
  fi
fi

echo "[ios] done: bundle_id=$BUNDLE_ID device=$DEVICE_UDID transport=$DEVICE_TRANSPORT offline_cached=$used_offline_profile profile_expires=${PROFILE_EXPIRES:-unknown}" >&2
