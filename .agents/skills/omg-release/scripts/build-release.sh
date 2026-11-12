#!/bin/bash
set -euo pipefail

clean_build=0
no_cache=${OMG_RELEASE_NO_CACHE:-0}
omg_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) clean_build=1; shift ;;
    --no-cache) no_cache=1; shift ;;
    -*)
      echo "usage: $0 [--clean] [--no-cache] OMG_VERSION" >&2
      exit 64
      ;;
    *)
      if [[ -n "$omg_version" ]]; then
        echo "usage: $0 [--clean] [--no-cache] OMG_VERSION" >&2
        exit 64
      fi
      omg_version=$1
      shift
      ;;
  esac
done

if [[ ! "$omg_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 [--clean] [--no-cache] OMG_VERSION" >&2
  exit 64
fi

export OMG_RELEASE_NO_CACHE="$no_cache"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Credential/ACL failures must be discovered before deleting or building apps.
mode=$(bash dist/macos/signing-python.sh policy)
[[ "$mode" == self-signed || "$mode" == developer-id ]] || {
  echo "public release builds require persistent signing configuration" >&2; exit 1;
}
if [[ "$mode" == self-signed ]]; then
  bash dist/macos/signing-python.sh unlock
fi

plist="macos/Ghostty-Info.plist"
ghostty_version=$(plutil -extract GhosttyBaseVersion raw "$plist")
build_root="$repo_root/.release-build/$omg_version"
cache_root="$repo_root/.release-build/_cache"

expected_build=""
for config in Debug Release ReleaseLocal; do
  settings=$(xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -target Ghostty \
    -configuration "$config" \
    -showBuildSettings 2>/dev/null)
  marketing=$(awk '/MARKETING_VERSION =/{print $3; exit}' <<<"$settings")
  current_proj=$(awk '/CURRENT_PROJECT_VERSION =/{print $3; exit}' <<<"$settings")
  [[ "$marketing" == "$omg_version" ]] || {
    echo "$config MARKETING_VERSION is $marketing, expected $omg_version" >&2
    exit 1
  }
  if [[ -z "$expected_build" ]]; then expected_build=$current_proj; fi
  [[ "$current_proj" == "$expected_build" ]] || {
    echo "$config CURRENT_PROJECT_VERSION ($current_proj) differs from $expected_build" >&2
    exit 1
  }
done

rm -rf "$build_root"
mkdir -p "$build_root" "$cache_root"

# 1. Universal GhosttyKit.xcframework (content-addressed cache across patch releases).
zig_ver=$(mise exec zig@0.16.0 -- zig version)
gk_key=$(python3 - "$repo_root" "$ghostty_version" "$zig_ver" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
h = hashlib.sha256()
for token in sys.argv[2:]:
    h.update(token.encode())
    h.update(b"\0")
for base in ("src", "include", "pkg"):
    d = root / base
    if not d.is_dir():
        continue
    for path in sorted(d.rglob("*")):
        if path.is_file():
            h.update(str(path.relative_to(root)).encode())
            h.update(path.read_bytes())
for rel in ("build.zig", "build.zig.zon"):
    p = root / rel
    if p.is_file():
        h.update(rel.encode())
        h.update(p.read_bytes())
print(h.hexdigest()[:24])
PY
)
gk_cache_dir="$cache_root/ghosttykit-universal/$gk_key"
gk_cached_xcf="$gk_cache_dir/GhosttyKit.xcframework"
gk_target_xcf="$repo_root/macos/GhosttyKit.xcframework"
gk_target_lib="$gk_target_xcf/macos-arm64_x86_64/ghostty-internal.a"
gk_cached_lib="$gk_cached_xcf/macos-arm64_x86_64/ghostty-internal.a"

if [[ "$no_cache" == "0" && -s "$gk_cached_lib" ]]; then
  if [[ ! -s "$gk_target_lib" ]] || ! cmp -s "$gk_cached_lib" "$gk_target_lib"; then
    rm -rf "$gk_target_xcf"
    ditto "$gk_cached_xcf" "$gk_target_xcf"
    printf '[ghosttykit] cache=restored key=%s\n' "$gk_key"
  else
    printf '[ghosttykit] cache=in-place key=%s\n' "$gk_key"
  fi
  touch "$gk_cache_dir"
else
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u ALL_PROXY -u all_proxy \
    mise exec zig@0.16.0 -- zig build \
      -Doptimize=ReleaseFast \
      -Demit-xcframework=true \
      -Dxcframework-target=universal \
      -Demit-macos-app=false \
      -Dversion-string="$ghostty_version"
  if [[ "$no_cache" == "0" ]]; then
    rm -rf "$gk_cache_dir"
    mkdir -p "$gk_cache_dir"
    ditto "$gk_target_xcf" "$gk_cached_xcf"
    python3 - "$cache_root/ghosttykit-universal" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
entries = sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime, reverse=True)
for stale in entries[2:]:
    shutil.rmtree(stale, ignore_errors=True)
PY
  fi
  printf '[ghosttykit] cache=built key=%s\n' "$gk_key"
fi

core_archs=$(lipo -archs "$gk_target_lib")
[[ " $core_archs " == *" arm64 "* && " $core_archs " == *" x86_64 "* ]] || {
  echo "GhosttyKit is not universal: $core_archs" >&2
  exit 1
}

# 2. Build universal OMG.app once (reusing incremental SYMROOT/OBJROOT unless --clean/--no-cache),
#    then derive single-architecture arm64 and x86_64 apps via lipo -thin.
if [[ "$clean_build" == "1" || "$no_cache" == "1" ]]; then
  xcode_sym="$build_root/universal"
  xcode_obj="$build_root/obj-universal"
  rm -rf "$cache_root/xcode-universal"
else
  xcode_sym="$cache_root/xcode-universal/sym"
  xcode_obj="$cache_root/xcode-universal/obj"
  mkdir -p "$xcode_sym" "$xcode_obj"
fi

DISABLE_SWIFTLINT=1 \
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -target Ghostty \
  -configuration Release \
  -skipPackagePluginValidation \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  SYMROOT="$xcode_sym" \
  OBJROOT="$xcode_obj" \
  build

if [[ "$xcode_sym" != "$build_root/universal" ]]; then
  mkdir -p "$build_root/universal/Release"
  ditto "$xcode_sym/Release/OMG.app" "$build_root/universal/Release/OMG.app"
fi

# 3. Package all supported remote runtimes and a universal local relay (cached when unchanged).
runtime_args=(--output "$build_root/session-runtime" --macos all)
if [[ "$no_cache" == "1" ]]; then
  runtime_args+=(--no-cache)
fi
python3 dist/macos/build-session-runtime.py "${runtime_args[@]}"
ditto "$build_root/session-runtime" "$build_root/universal/Release/OMG.app/Contents/Resources/session-runtime"

# 4. Derive arm64 and x86_64 apps by thinning Xcode-built universal Mach-O slices.
#    Sparkle.framework (prebuilt universal) and session-runtime (multi-platform payload) stay intact.
for arch in arm64 x86_64; do
  mkdir -p "$build_root/$arch/Release"
  ditto "$build_root/universal/Release/OMG.app" "$build_root/$arch/Release/OMG.app"
done

python3 - "$build_root" <<'PY'
from pathlib import Path
import subprocess
import sys

build_root = Path(sys.argv[1])


def is_preserved_subpath(rel: Path) -> bool:
    parts = rel.parts
    if len(parts) >= 3 and parts[:3] == ("Contents", "Frameworks", "Sparkle.framework"):
        return True
    if len(parts) >= 3 and parts[:3] == ("Contents", "Resources", "session-runtime"):
        return True
    return False


for arch in ("arm64", "x86_64"):
    app = build_root / arch / "Release" / "OMG.app"
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        rel = path.relative_to(app)
        if is_preserved_subpath(rel):
            continue
        desc = subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True)
        if "Mach-O" not in desc:
            continue
        slices = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if arch not in slices:
            raise SystemExit(f"{rel} in {arch} app is missing {arch} slice: {slices}")
        if len(slices) > 1:
            thin = path.with_name(path.name + f".{arch}.thin")
            subprocess.run(["/usr/bin/lipo", "-thin", arch, str(path), "-output", str(thin)], check=True)
            thin.chmod(path.stat().st_mode)
            thin.replace(path)
    # Restore valid ad-hoc signatures on thinned bundles prior to persistent release signing.
    for fw in sorted((app / "Contents/Frameworks").glob("*.framework")):
        if fw.name != "Sparkle.framework":
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(fw)], check=True)
    for plugin in sorted((app / "Contents/PlugIns").glob("*.plugin")):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(plugin)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True)
PY

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
  actual_omg=$(plutil -extract OMGVersion raw "$app/Contents/Info.plist")
  actual_build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
  [[ "$actual_id" == "com.jischeng.omg" ]] || { echo "wrong bundle ID: $actual_id" >&2; exit 1; }
  [[ "$actual_version" == "$omg_version" ]] || { echo "wrong OMG version: $actual_version" >&2; exit 1; }
  [[ "$actual_omg" == "$omg_version" ]] || { echo "wrong Info.plist OMGVersion: $actual_omg" >&2; exit 1; }
  [[ "$actual_build" == "$expected_build" ]] || { echo "wrong CFBundleVersion: $actual_build != $expected_build" >&2; exit 1; }
  if [[ -z "$bundle_version" ]]; then bundle_version=$actual_build; fi
  [[ "$actual_build" == "$bundle_version" ]] || { echo "bundle versions differ" >&2; exit 1; }

  printf '[%s] archs=%s omg=%s bundle=%s ghostty=%s\n' \
    "$arch" "$actual_archs" "$actual_version" "$actual_build" "$ghostty_version"
done

printf 'build_root=%s\n' "$build_root"
