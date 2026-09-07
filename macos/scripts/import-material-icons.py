#!/usr/bin/env python3
"""Import pinned official Material Icon Theme resources; no runtime network access."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

VERSION = "5.38.1"
SHA256 = "d4342dc13a24bd40c4f417337dc19d2d2c42e47f8bb42ca677109bce769f078e"
URL = f"https://registry.npmjs.org/material-icon-theme/-/material-icon-theme-{VERSION}.tgz"
ROOT = Path(__file__).resolve().parents[1] / "Assets.xcassets" / "MaterialIcons"
KEYS = ("fileNames", "fileExtensions", "folderNames", "folderNamesExpanded")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    archive = urllib.request.urlopen(URL).read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise RuntimeError("Material Icon Theme archive checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive)) as package:
        def read(path):
            return package.extractfile("package/" + path).read()

        theme = json.loads(read("dist/material-icons.json"))
        manifest = {key: theme[key] for key in KEYS}
        manifest["light"] = {key: theme["light"].get(key, {}) for key in KEYS}
        manifest.update({key: theme[key] for key in ("file", "folder", "folderExpanded")})
        icons = {manifest[key] for key in ("file", "folder", "folderExpanded")}
        for variant in (manifest, manifest["light"]):
            for key in KEYS:
                icons.update(variant[key].values())
        write_json(ROOT / "Contents.json", {"info": {"author": "xcode", "version": 1}})
        for icon in sorted(icons):
            # The upstream generated manifest refers to ../icons/*.svg from dist/.
            source = theme["iconDefinitions"][icon]["iconPath"].split("icons/", 1)[1]
            folder = ROOT / f"material-{icon}.imageset"
            write_json(folder / "Contents.json", {
                "images": [{"filename": "icon.svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                "properties": {"preserves-vector-representation": True},
            })
            (folder / "icon.svg").write_bytes(read("icons/" + source))
        for name, filename, data in (
            ("material-icon-associations", "associations.json", json.dumps(manifest, sort_keys=True).encode()),
            ("material-icon-license", "LICENSE.txt", read("LICENSE")),
        ):
            folder = ROOT / f"{name}.dataset"
            write_json(folder / "Contents.json", {
                "data": [{"filename": filename, "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
            })
            (folder / filename).write_bytes(data)
        print(f"Imported {len(icons)} Material Icon Theme {VERSION} icons")


if __name__ == "__main__":
    main()
