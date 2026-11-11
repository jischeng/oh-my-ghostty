#!/bin/bash
# Build and package OMG Mobile release artifacts:
#   1. OMG-Mobile-<version>-ios-installer.tar.gz (self-contained Xcode + prebuilt VT kit)
#   2. OMG-Mobile-<version>-ios-unsigned.ipa      (for SideStore / AltStore / Sideloadly / TrollStore)
set -euo pipefail

if [[ $# -ne 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 OMG_VERSION OUTPUT_DIR" >&2
  exit 64
fi

omg_version=$1
output_dir=$2
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
ios_dir="$repo_root/ios"

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

# 1. Build ReleaseFast libghostty-vt.a for both device and simulator so users of
#    the installer kit never need Zig, mise, or full Ghostty core compilation.
"$ios_dir/scripts/build-vt.sh" iphoneos
"$ios_dir/scripts/build-vt.sh" iphonesimulator

# 2. Generate OMGMobile.xcodeproj and .build/Info.plist via XcodeGen.
(unset SDKROOT; xcodegen generate --spec "$ios_dir/project.yml")

actual_marketing=$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' "$ios_dir/project.yml")
[[ "$actual_marketing" == "$omg_version" ]] || {
  echo "ios/project.yml MARKETING_VERSION is $actual_marketing, expected $omg_version" >&2
  exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/omg-mobile-pkg.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# 3. Compile unsigned Release iphoneos app to verify Release compilation and package unsigned .ipa.
unset SDKROOT
xcodebuild \
  -project "$ios_dir/OMGMobile.xcodeproj" \
  -scheme OMGMobile \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$work_dir/derived" \
  "ARCHS=arm64" \
  "ONLY_ACTIVE_ARCH=YES" \
  "CODE_SIGNING_ALLOWED=NO" \
  build

built_app="$work_dir/derived/Build/Products/Release-iphoneos/OMGMobile.app"
[[ -f "$built_app/OMGMobile" ]] || {
  echo "missing built OMGMobile executable in $built_app" >&2
  exit 1
}
app_short_ver=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$built_app/Info.plist")
[[ "$app_short_ver" == "$omg_version" ]] || {
  echo "OMGMobile.app CFBundleShortVersionString is $app_short_ver, expected $omg_version" >&2
  exit 1
}
lipo -archs "$built_app/OMGMobile" | grep -qw arm64 || {
  echo "OMGMobile binary is missing arm64 architecture" >&2
  exit 1
}

ipa_stage="$work_dir/ipa"
mkdir -p "$ipa_stage/Payload"
ditto "$built_app" "$ipa_stage/Payload/OMGMobile.app"
ipa_path="$output_dir/OMG-Mobile-$omg_version-ios-unsigned.ipa"
rm -f "$ipa_path"
(cd "$ipa_stage" && /usr/bin/zip -qry "$ipa_path" Payload)

# 4. Assemble clean self-contained installer kit (no Zig, Rust, or XcodeGen required).
kit_name="OMG-Mobile-$omg_version-ios"
kit_root="$work_dir/$kit_name"
mkdir -p "$kit_root/ios/.build/vt/iphoneos" "$kit_root/ios/.build/vt/iphonesimulator"

cp "$repo_root/LICENSE" "$kit_root/LICENSE"
cp "$ios_dir/scripts/install-to-iphone.sh" "$kit_root/install-to-iphone.sh"
chmod +x "$kit_root/install-to-iphone.sh"

for item in Assets.xcassets Core GhosttyVt Licenses OMGMobile.xcodeproj Sources UITests Vendor project.yml Package.swift README.md; do
  rsync -a \
    --exclude '.build' \
    --exclude '.swiftpm' \
    --exclude '*.xcuserstate' \
    --exclude 'xcuserdata' \
    --exclude '.DS_Store' \
    "$ios_dir/$item" "$kit_root/ios/"
done

mkdir -p "$kit_root/ios/scripts"
cp "$ios_dir/scripts/install-to-iphone.sh" "$kit_root/ios/scripts/install-to-iphone.sh"
chmod +x "$kit_root/ios/scripts/install-to-iphone.sh"

cp -R "$ios_dir/.build/headers" "$kit_root/ios/.build/"
cp "$ios_dir/.build/Info.plist" "$kit_root/ios/.build/Info.plist"
if [[ -f "$ios_dir/.build/UITest-Info.plist" ]]; then
  cp "$ios_dir/.build/UITest-Info.plist" "$kit_root/ios/.build/UITest-Info.plist"
fi
cp "$ios_dir/.build/vt/iphoneos/libghostty-vt.a" "$kit_root/ios/.build/vt/iphoneos/"
cp "$ios_dir/.build/vt/iphonesimulator/libghostty-vt.a" "$kit_root/ios/.build/vt/iphonesimulator/"

cat > "$kit_root/INSTALL.md" <<EOF
# Installing OMG Mobile $omg_version on iPhone / iPad

This archive contains prebuilt Ghostty VT libraries (\`libghostty-vt.a\`) and the
generated Xcode project. **Zig, Rust, and XcodeGen are not required.**

## Prerequisites

1. A Mac with **Xcode** installed (sign in with any Apple ID under **Xcode → Settings → Accounts**; a free Personal Team Apple ID works).
2. An iPhone or iPad running **iOS 17+**, connected via USB, unlocked, with **Settings → Privacy & Security → Developer Mode** enabled.

## One-command install

\`\`\`bash
./install-to-iphone.sh
\`\`\`

Optional flags:
- \`--team <TEAM_ID>\`: choose a specific 10-character Apple Team ID when multiple accounts exist.
- \`--device <UDID_OR_NAME>\`: target a specific iPhone/iPad when multiple devices are connected.
- \`--bundle-id <BUNDLE_ID>\`: override the default per-team bundle identifier (\`com.jischeng.omg.mobile.<team>\`).

On a first install with a free Apple ID, trust your developer profile on the iPhone under
**Settings → General → VPN & Device Management**, then launch **OMG Mobile** and run
\`omg +mobile\` on your Mac (or open **OMG Settings → Mobile Devices**) to scan the pairing QR code.
EOF

tar_path="$output_dir/OMG-Mobile-$omg_version-ios-installer.tar.gz"
rm -f "$tar_path"
COPYFILE_DISABLE=1 tar -czf "$tar_path" -C "$work_dir" "$kit_name"

printf '[ios] ipa=%s\n[ios] kit=%s\n' "$ipa_path" "$tar_path"
