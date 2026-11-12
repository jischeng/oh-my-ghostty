#!/usr/bin/env python3
"""Reject incomplete native SSH bundles before replacing a development app."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess


def validate(root: Path, native: str, *, all_macos: bool = False, linux_archs=("x86_64", "aarch64")):
    revision = (root / "revision").read_text().strip()
    snapshot = (root / "snapshot-revision").read_text().strip()
    if not revision or not snapshot:
        raise ValueError("empty runtime revision")
    for name in ("omgd", "askpass"):
        path = root / name
        if not path.is_file() or not path.stat().st_mode & 0o111:
            raise ValueError(f"missing executable: {name}")
    macos_targets = ("macos-aarch64", "macos-x86_64") if all_macos else (f"macos-{native}",)
    linux_targets = tuple(f"linux-{arch}" for arch in linux_archs)
    for target in (*macos_targets, *linux_targets):
        directory = root / target
        manifest = json.loads((directory / "manifest.json").read_text())
        if manifest["revision"] != revision or manifest["platform"] != target:
            raise ValueError(f"mismatched runtime manifest: {target}")
        names = {item["name"] for item in manifest["files"]}
        if "omgd" not in names or not any(name.startswith("libghostty-vt") for name in names):
            raise ValueError(f"missing runtime binary or dependency: {target}")
        for item in manifest["files"]:
            name = item["name"]
            if Path(name).name != name:
                raise ValueError("invalid manifest filename")
            if hashlib.sha256((directory / name).read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError(f"runtime hash mismatch: {target}/{name}")
        if target == f"macos-{native}":
            for name in names:
                if not (root / name).is_file():
                    raise ValueError(f"missing local runtime dependency: {name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--all-macos", action="store_true")
    parser.add_argument("--linux", default="x86_64,aarch64", help="comma separated Linux arches bundled in the app")
    args = parser.parse_args()
    native = "aarch64" if platform.machine() == "arm64" else "x86_64"
    linux_archs = tuple(arch for arch in args.linux.split(",") if arch)
    validate(args.root, native, all_macos=args.all_macos, linux_archs=linux_archs)
    if args.all_macos:
        archs = subprocess.check_output(
            ["/usr/bin/lipo", "-archs", str(args.root.resolve() / "omgd")], text=True
        ).split()
        if set(archs) != {"arm64", "x86_64"}:
            raise SystemExit(f"expected universal local omgd, got: {' '.join(archs)}")
    subprocess.run([str(args.root.resolve() / "omgd"), "version"], check=True, timeout=10)
    print("Session runtime bundle verified")


if __name__ == "__main__":
    main()
