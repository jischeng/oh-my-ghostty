#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 OMG_VERSION" >&2
  exit 64
fi

omg_version=$1
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

plist="macos/Ghostty-Info.plist"
ghostty_version=$(plutil -extract GhosttyBaseVersion raw "$plist")
build_root="$repo_root/.release-build/$omg_version"

for config in Debug Release ReleaseLocal; do
  settings=$(xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -target Ghostty \
    -configuration "$config" \
    -showBuildSettings 2>/dev/null)
  marketing=$(awk '/MARKETING_VERSION =/{print $3; exit}' <<<"$settings")
  [[ "$marketing" == "$omg_version" ]] || {
    echo "$config MARKETING_VERSION is $marketing, expected $omg_version" >&2
    exit 1
  }
done

rm -rf "$build_root"
mkdir -p "$build_root"

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Demit-macos-app=false \
    -Dversion-string="$ghostty_version"

core_archs=$(lipo -archs \
  macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a)
[[ " $core_archs " == *" arm64 "* && " $core_archs " == *" x86_64 "* ]] || {
  echo "GhosttyKit is not universal: $core_archs" >&2
  exit 1
}

for arch in arm64 x86_64; do
  xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -target Ghostty \
    -configuration Release \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    SYMROOT="$build_root/$arch" \
    OBJROOT="$build_root/obj-$arch" \
    build
done

xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -target Ghostty \
  -configuration Release \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  SYMROOT="$build_root/universal" \
  OBJROOT="$build_root/obj-universal" \
  build

bundle_version=""
for arch in arm64 x86_64 universal; do
  app="$build_root/$arch/Release/OMG.app"
  bin="$app/Contents/MacOS/omg"
  [[ -x "$bin" ]] || { echo "missing $app" >&2; exit 1; }

  actual_archs=$(lipo -archs "$bin")
  if [[ "$arch" == universal ]]; then
    [[ " $actual_archs " == *" arm64 "* && " $actual_archs " == *" x86_64 "* ]] || {
      echo "universal app has wrong architectures: $actual_archs" >&2
      exit 1
    }
  else
    [[ "$actual_archs" == "$arch" ]] || {
      echo "$arch app has wrong architecture: $actual_archs" >&2
      exit 1
    }
  fi

  actual_id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
  actual_version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
  actual_build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
  [[ "$actual_id" == "com.jischeng.omg" ]] || { echo "wrong bundle ID: $actual_id" >&2; exit 1; }
  [[ "$actual_version" == "$omg_version" ]] || { echo "wrong OMG version: $actual_version" >&2; exit 1; }
  if [[ -z "$bundle_version" ]]; then bundle_version=$actual_build; fi
  [[ "$actual_build" == "$bundle_version" ]] || { echo "bundle versions differ" >&2; exit 1; }

  printf '[%s] archs=%s omg=%s bundle=%s ghostty=%s\n' \
    "$arch" "$actual_archs" "$actual_version" "$actual_build" "$ghostty_version"
done

printf 'build_root=%s\n' "$build_root"
