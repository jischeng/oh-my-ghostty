#!/usr/bin/env python3
"""Compile the small mobile workspace/host helper."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--arch", default="arm64")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5",
        "-target", f"{args.arch}-apple-macos13.0",
        str(ROOT / "session-runtime/mobile-support/Support.swift"),
        "-o", str(args.output),
    ], check=True)


if __name__ == "__main__":
    main()
