#!/usr/bin/env python3
"""Build matching native and Linux runtime artifacts, serially, without remote tools."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CACHE_ROOT = ROOT / ".release-build" / "_cache" / "session-runtime"


def load_validator():
    spec = importlib.util.spec_from_file_location(
        "check_session_runtime", Path(__file__).with_name("check-session-runtime.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.validate


def compute_cache_key(revision: str, macos_mode: str, linux_archs: str, zig_ver: str, rustc_ver: str) -> str:
    h = hashlib.sha256()
    for token in (revision, macos_mode, linux_archs, platform.machine(), zig_ver, rustc_ver):
        h.update(token.encode())
        h.update(b"\0")
    for base in ("src", "include"):
        for path in sorted((ROOT / base).rglob("*")):
            if path.is_file():
                h.update(str(path.relative_to(ROOT)).encode())
                h.update(path.read_bytes())
    for rel in ("build.zig", "build.zig.zon", "dist/macos/session-runtime-askpass.sh"):
        p = ROOT / rel
        if p.is_file():
            h.update(rel.encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def prune_cache(prefix: str, keep: int = 2) -> None:
    if not CACHE_ROOT.is_dir():
        return
    entries = sorted(
        (p for p in CACHE_ROOT.iterdir() if p.is_dir() and p.name.startswith(prefix)),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for stale in entries[keep:]:
        shutil.rmtree(stale, ignore_errors=True)


def run(args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def sign_adhoc(paths):
    """Re-sign copied Mach-O files after load-command edits.

    install_name_tool and lipo invalidate the linker's ad-hoc signature, and
    Apple silicon refuses to execute a Mach-O whose pages no longer match it.
    The installing script runs these artifacts before the app bundle is signed,
    so they must carry a usable signature here.
    """
    for path in paths:
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(path)])


def snapshot_revision(source_digest, compatibility):
    """Only exact, verified source trees may share an earlier snapshot epoch."""
    hexadecimal = set("0123456789abcdef")
    if len(source_digest) != 64 or not set(source_digest) <= hexadecimal:
        raise ValueError("invalid snapshot source digest")
    if not isinstance(compatibility, dict) or any(
        not isinstance(key, str) or len(key) != 64 or not set(key) <= hexadecimal
        or not isinstance(value, str) or len(value) != 20 or not set(value) <= hexadecimal
        for key, value in compatibility.items()
    ):
        raise ValueError("invalid snapshot compatibility map")
    return compatibility.get(source_digest, source_digest[:20])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--linux', default='x86_64,aarch64')
    parser.add_argument('--macos', default='native', choices=['native', 'all'])
    parser.add_argument('--no-cache', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    use_cache = not args.no_cache and os.environ.get('OMG_RELEASE_NO_CACHE') != '1'
    # Content-derived revision also distinguishes uncommitted development builds.
    digest = hashlib.sha256()
    snapshot_digest = hashlib.sha256()
    for base in ['session-runtime/src', 'session-runtime/mobile-support', 'include/ghostty/vt', 'src/terminal']:
        for path in sorted((ROOT / base).rglob('*')):
            if path.is_file():
                digest.update(str(path.relative_to(ROOT)).encode())
                contents = path.read_bytes()
                digest.update(contents)
                if base in ['include/ghostty/vt', 'src/terminal']:
                    snapshot_digest.update(str(path.relative_to(ROOT)).encode())
                    snapshot_digest.update(contents)
    for path in [
        ROOT/'dist/macos/build-mobile-support.py',
        ROOT/'session-runtime/Cargo.toml', ROOT/'session-runtime/Cargo.lock',
        ROOT/'session-runtime/build.rs', ROOT/'session-runtime/LICENSE.herdr',
        ROOT/'src/shell-integration/omg/omg.py',
        ROOT/'session-runtime/LICENSE.termio',
        ROOT/'session-runtime/THIRD-PARTY-NOTICES', Path(__file__).resolve(),
        ROOT/'dist/macos/session-runtime-snapshot-compatibility.json',
    ]:
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    revision = digest.hexdigest()[:20]
    zig = Path(subprocess.check_output(['mise', 'exec', 'zig@0.16.0', '--', 'which', 'zig'], text=True).strip())
    zig_ver = subprocess.check_output([str(zig), 'version'], text=True).strip()
    rustc = subprocess.check_output(['rustup', 'which', 'rustc'], text=True).strip()
    rustc_ver = subprocess.check_output([rustc, '--version'], text=True).strip()
    native = 'aarch64' if platform.machine() == 'arm64' else 'x86_64'
    validate = load_validator()
    cache_prefix = f'{args.macos}-'
    cache_dir = CACHE_ROOT / f'{cache_prefix}{compute_cache_key(revision, args.macos, args.linux, zig_ver, rustc_ver)[:24]}'
    if use_cache and cache_dir.is_dir():
        try:
            validate(cache_dir, native, all_macos=(args.macos == 'all'))
            if output.exists():
                shutil.rmtree(output)
            shutil.copytree(cache_dir, output)
            os.utime(cache_dir, None)
            print(f'runtime artifacts (cached {revision}): {output}', flush=True)
            return
        except Exception:
            shutil.rmtree(cache_dir, ignore_errors=True)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    targets = [(f'macos-{native}', None, None)]
    if args.macos == 'all':
        other = 'x86_64' if native == 'aarch64' else 'aarch64'
        targets.append((f'macos-{other}', f'{other}-apple-darwin', f'{other}-macos.13.0'))
    for arch in filter(None, args.linux.split(',')):
        if arch not in {'x86_64', 'aarch64'}: raise ValueError('invalid Linux architecture')
        targets.append((f'linux-{arch}', f'{arch}-unknown-linux-gnu', f'{arch}-linux-gnu.2.28'))
    for name, rust_target, zig_target in targets:
        destination = output/name
        destination.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='omg-runtime-build-') as tmp:
            tmp = Path(tmp)
            prefix = tmp/'vt'
            command = [str(zig), 'build', '-Demit-lib-vt', '-Demit-macos-app=false',
                       '-Doptimize=ReleaseFast', '-Dversion-string=1.3.2-dev', '--prefix', str(prefix)]
            if zig_target: command.append('-Dtarget=' + zig_target)
            run(command)
            env = os.environ.copy()
            env['RUSTC'] = rustc
            env['OMG_VT_LIB_DIR'] = str(prefix/'lib')
            cargo = ['cargo', 'build', '--manifest-path', 'session-runtime/Cargo.toml', '--release']
            if rust_target:
                run(['rustup', 'target', 'add', rust_target])
                cc = tmp/'cc'
                ar = tmp/'ar'
                if name.startswith('macos-'):
                    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
                    apple_arch = 'arm64' if name.endswith('aarch64') else 'x86_64'
                    cc.write_text(f'#!/bin/sh\nexec /usr/bin/clang -arch {apple_arch} -isysroot "{sdk}" -mmacosx-version-min=13.0 "$@"\n')
                else:
                    cc.write_text(f'#!/bin/sh\nexec "{zig}" cc -target {zig_target} "$@"\n')
                ar.write_text(f'#!/bin/sh\nexec "{zig}" ar "$@"\n')
                cc.chmod(0o700)
                ar.chmod(0o700)
                env['OMG_RUNTIME_CC'] = str(cc)
                env['OMG_RUNTIME_AR'] = str(ar)
                env['CARGO_TARGET_' + rust_target.upper().replace('-', '_') + '_LINKER'] = str(cc)
                cargo += ['--target', rust_target]
            run(cargo, env=env)
            binary = ROOT/'session-runtime/target'
            if rust_target: binary /= rust_target
            binary /= 'release/omgd'
            shutil.copy2(binary, destination/'omgd')
            if name.startswith('linux-'):
                library = next(p for p in (prefix/'lib').glob('libghostty-vt.so.*') if not p.is_symlink())
                shutil.copy2(library, destination/'libghostty-vt.so.0')
            else:
                library = next(p for p in (prefix/'lib').glob('libghostty-vt.*.dylib') if not p.is_symlink())
                shutil.copy2(library, destination/library.name)
                run(['/usr/bin/install_name_tool', '-id', '@rpath/' + library.name, str(destination/library.name)])
                dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(destination/'omgd')], text=True)
                for line in dependencies.splitlines()[1:]:
                    dependency = line.strip().split(' (')[0]
                    if 'libghostty-vt' in dependency:
                        run(['/usr/bin/install_name_tool', '-change', dependency, '@rpath/' + library.name, str(destination/'omgd')])
                sign_adhoc([destination/library.name, destination/'omgd'])
            if name.startswith('macos-'):
                apple_arch = 'arm64' if name == 'macos-aarch64' else 'x86_64'
                run([sys.executable, str(ROOT/'dist/macos/build-mobile-support.py'),
                     '--output', str(destination/'omg-mobile-support'), '--arch', apple_arch])
                sign_adhoc([destination/'omg-mobile-support'])
            for notice in ('LICENSE.herdr', 'LICENSE.termio', 'THIRD-PARTY-NOTICES'):
                shutil.copy2(ROOT/'session-runtime'/notice, destination/notice)
            files = [{'name': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                     for p in sorted(destination.iterdir()) if p.name != 'manifest.json' and p.is_file()]
            (destination/'manifest.json').write_text(json.dumps({'revision': revision, 'platform': name, 'files': files}, indent=2)+'\n')
        print(f'built {name} {revision}', flush=True)
    for path in (output/f'macos-{native}').iterdir():
        if path.name != 'manifest.json': shutil.copy2(path, output/path.name)
    if args.macos == 'all':
        for path in (output/f'macos-{native}').iterdir():
            if path.name not in ('omgd', 'omg-mobile-support') and path.suffix != '.dylib': continue
            run(['/usr/bin/lipo', '-create', str(output/'macos-aarch64'/path.name),
                 str(output/'macos-x86_64'/path.name), '-output', str(output/path.name)])
            sign_adhoc([output/path.name])
    shutil.copy2(ROOT/'dist/macos/session-runtime-askpass.sh', output/'askpass')
    (output/'askpass').chmod(0o755)
    (output/'revision').write_text(revision+'\n')
    compatibility = json.loads((ROOT/'dist/macos/session-runtime-snapshot-compatibility.json').read_text())
    (output/'snapshot-revision').write_text(snapshot_revision(snapshot_digest.hexdigest(), compatibility)+'\n')
    validate(output, native, all_macos=(args.macos == 'all'))
    if use_cache:
        CACHE_ROOT.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='.stage-', dir=CACHE_ROOT))
        try:
            shutil.copytree(output, stage / 'bundle')
            if cache_dir.exists():
                shutil.rmtree(cache_dir, ignore_errors=True)
            (stage / 'bundle').rename(cache_dir)
        finally:
            shutil.rmtree(stage, ignore_errors=True)
        prune_cache(cache_prefix)
    print(f'runtime artifacts: {output}', flush=True)


if __name__ == '__main__': main()
