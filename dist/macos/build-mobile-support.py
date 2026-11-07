#!/usr/bin/env python3
"""Compile the desktop history readers directly into the mobile host helper."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def declaration(source, name):
    start = source.index(name)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--arch", default="arm64")
    args = parser.parse_args()
    plugins = ROOT / "macos/Sources/Features/Plugins"
    definitions = (plugins / "AgentDefinition.swift").read_text()
    # Reuse the desktop's validated identity and manifest schema without its UI types.
    models = "import Foundation\n" + declaration(definitions, "struct AgentConversationID:")
    resume = declaration(definitions, "    struct ResumeSpec:")
    models += "\nstruct AgentDefinition: Decodable {\n" + resume
    models += "\nlet command: String\nlet resume: ResumeSpec\n}\n"
    with tempfile.TemporaryDirectory(prefix="omg-mobile-support-") as tmp:
        generated = Path(tmp) / "HistoryModels.swift"
        generated.write_text(models)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([
            "xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5",
            "-target", f"{args.arch}-apple-macos13.0",
            str(generated), str(ROOT / "session-runtime/mobile-support/Support.swift"),
            str(plugins / "AgentHistoryStore.swift"),
            str(plugins / "AgentHistoryRemoteAccess.swift"),
            str(ROOT / "macos/Sources/Helpers/TransientAttachmentNoise.swift"),
            "-o", str(args.output),
        ], check=True)


if __name__ == "__main__":
    main()
