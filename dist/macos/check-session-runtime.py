#!/usr/bin/env python3
"""Reject incomplete native SSH bundles before replacing a development app."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess


def validate(root: Path, native: str):
    revision = (root / "revision").read_text().strip()
    snapshot = (root / "snapshot-revision").read_text().strip()
    if not revision or not snapshot:
        raise ValueError("empty runtime revision")
    for name in ("omgd", "askpass"):
        path = root / name
        if not path.is_file() or not path.stat().st_mode & 0o111:
            raise ValueError(f"missing executable: {name}")
    for target in (f"macos-{native}", "linux-x86_64", "linux-aarch64"):
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
    args = parser.parse_args()
    validate(args.root, "aarch64" if platform.machine() == "arm64" else "x86_64")
    subprocess.run([str(args.root.resolve() / "omgd"), "version"], check=True, timeout=10)
    print("Session runtime bundle verified")


if __name__ == "__main__":
    main()
