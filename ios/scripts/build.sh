#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
sdk=${1:-iphonesimulator}
"$root/ios/scripts/build-vt.sh" "$sdk"
unset SDKROOT
xcodegen generate --spec "$root/ios/project.yml"
args=(-project "$root/ios/OMGMobile.xcodeproj" -scheme OMGMobile
      -configuration Debug -sdk "$sdk" -derivedDataPath "$root/ios/.build/app"
      "ARCHS=arm64" "ONLY_ACTIVE_ARCH=YES")
if [[ "$sdk" == iphonesimulator ]]; then
  # Simulator Keychain also needs Xcode's simulated application-identifier.
  # Disabling signing entirely omits that metadata and makes SecItemAdd fail.
  args+=("CODE_SIGNING_ALLOWED=YES" "CODE_SIGN_IDENTITY=-")
elif [[ -n "${OMG_IOS_DEVELOPMENT_TEAM:-}" ]]; then
  args+=("DEVELOPMENT_TEAM=$OMG_IOS_DEVELOPMENT_TEAM")
else
  args+=("CODE_SIGNING_ALLOWED=NO")
fi
xcodebuild "${args[@]}" build
