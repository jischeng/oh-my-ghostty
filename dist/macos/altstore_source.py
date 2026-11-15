#!/usr/bin/env python3
"""Generate and validate an AltStore 2.0 / SideStore source feed for OMG Mobile."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
from typing import Any

RELEASE_REPO = "jischeng/oh-my-ghostty"
SOURCE_URL = f"https://github.com/{RELEASE_REPO}/releases/latest/download/altstore-source.json"
ICON_URL = f"https://raw.githubusercontent.com/{RELEASE_REPO}/main/images/icons/omg-logo-256.png"
HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ISO8601_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def read_app_info_plist(plist_path: Path) -> dict[str, Any]:
    """Load an app Info.plist (XML or binary) and return its root dictionary."""
    data = plistlib.loads(plist_path.read_bytes())
    if not isinstance(data, dict):
        raise ValueError(f"Expected dictionary root in {plist_path}")
    return data


def extract_privacy_permissions(info_plist: dict[str, Any]) -> dict[str, str]:
    """Extract all non-empty NS*UsageDescription entries verbatim from Info.plist."""
    privacy: dict[str, str] = {}
    for key in sorted(info_plist):
        if key.startswith("NS") and key.endswith("UsageDescription"):
            value = info_plist[key]
            if isinstance(value, str) and value.strip():
                privacy[key] = value
    return privacy


def sha256_and_size(path: Path) -> tuple[str, int]:
    """Return lowercase hex sha256 digest and exact byte size of a file."""
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            total += len(chunk)
    return digest.hexdigest().lower(), total


def _required_nonempty_str(mapping: dict[str, Any], key: str, source: Path) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing non-empty {key!r} in {source}")
    return value.strip()


def build_altstore_source(
    info_plist: dict[str, Any],
    ipa_path: Path,
    release_tag: str,
    *,
    info_plist_path: Path = Path("Info.plist"),
    release_date: str | None = None,
    previous_source: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build an AltStore 2.0 / SideStore JSON feed from built app Info.plist and IPA."""
    bundle_id = _required_nonempty_str(info_plist, "CFBundleIdentifier", info_plist_path)
    short_version = _required_nonempty_str(info_plist, "CFBundleShortVersionString", info_plist_path)
    build_version = _required_nonempty_str(info_plist, "CFBundleVersion", info_plist_path)
    min_os = str(info_plist.get("MinimumOSVersion") or "17.0").strip() or "17.0"
    display_name = str(
        info_plist.get("CFBundleDisplayName") or info_plist.get("CFBundleName") or "OMG Mobile"
    ).strip()
    privacy = extract_privacy_permissions(info_plist)
    if not privacy:
        raise ValueError(f"No NS*UsageDescription entries found in {info_plist_path}")

    ipa_sha256, ipa_size = sha256_and_size(ipa_path)
    if ipa_size <= 0:
        raise ValueError(f"IPA artifact is empty: {ipa_path}")

    if release_date is None:
        release_date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    elif not ISO8601_UTC_RE.match(release_date):
        raise ValueError(f"release_date must be ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ), got {release_date!r}")

    new_version = {
        "version": short_version,
        "buildVersion": build_version,
        "date": release_date,
        "localizedDescription": f"Oh My Ghostty iOS companion {release_tag} (build {build_version}).",
        "downloadURL": f"https://github.com/{RELEASE_REPO}/releases/download/{release_tag}/{ipa_path.name}",
        "size": ipa_size,
        "sha256": ipa_sha256,
        "minOSVersion": min_os,
    }

    versions = [new_version]
    if previous_source is not None:
        prev_apps = previous_source.get("apps")
        if isinstance(prev_apps, list) and prev_apps and isinstance(prev_apps[0], dict):
            prev_versions = prev_apps[0].get("versions")
            if isinstance(prev_versions, list):
                for item in prev_versions:
                    if not isinstance(item, dict):
                        continue
                    same_ver = (
                        item.get("version") == short_version
                        and item.get("buildVersion") == build_version
                    )
                    same_url = item.get("downloadURL") == new_version["downloadURL"]
                    if not same_ver and not same_url:
                        versions.append(item)

    return {
        "name": "Oh My Ghostty",
        "subtitle": "Native iOS companion for Oh My Ghostty",
        "description": "Connect from your iPhone or iPad to live Oh My Ghostty sessions, coding agents, project files, and remote hosts.",
        "identifier": f"{bundle_id}.source",
        "website": f"https://github.com/{RELEASE_REPO}",
        "sourceURL": SOURCE_URL,
        "headerURL": ICON_URL,
        "apps": [
            {
                "name": display_name,
                "bundleIdentifier": bundle_id,
                "developerName": "jischeng",
                "subtitle": "Native terminal & coding-agent companion for Oh My Ghostty",
                "localizedDescription": (
                    "Attach to live Oh My Ghostty terminal sessions, coding agents, "
                    "project files, and remote hosts from your iPhone or iPad."
                ),
                "iconURL": ICON_URL,
                "tintColor": "#141821",
                "category": "developer",
                "versions": versions,
                "appPermissions": {
                    "entitlements": [],
                    "privacy": privacy,
                },
            }
        ],
        "news": [],
    }


def validate_altstore_source(
    source: dict[str, Any],
    *,
    expected_version: str | None = None,
    expected_ipa: Path | None = None,
    expected_release_tag: str | None = None,
) -> dict[str, Any]:
    """Validate AltStore 2.0 / SideStore JSON schema and optional IPA release binding."""
    if not isinstance(source, dict):
        raise ValueError("altstore-source root must be a JSON object")
    for field in ("name", "identifier", "sourceURL"):
        val = source.get(field)
        if not isinstance(val, str) or not val.strip():
            raise ValueError(f"altstore-source missing non-empty top-level {field!r}")
    if not str(source["sourceURL"]).startswith("https://"):
        raise ValueError(f"altstore-source sourceURL must use https://: {source['sourceURL']!r}")

    apps = source.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("altstore-source must contain a non-empty 'apps' list")
    app = apps[0]
    if not isinstance(app, dict):
        raise ValueError("altstore-source apps[0] must be an object")
    for field in ("name", "bundleIdentifier", "developerName", "iconURL"):
        val = app.get(field)
        if not isinstance(val, str) or not val.strip():
            raise ValueError(f"altstore-source apps[0] missing non-empty {field!r}")

    perms = app.get("appPermissions")
    if not isinstance(perms, dict):
        raise ValueError("altstore-source apps[0] missing 'appPermissions' object")
    privacy = perms.get("privacy")
    if not isinstance(privacy, dict) or not privacy:
        raise ValueError("altstore-source apps[0].appPermissions.privacy must be non-empty")
    for key, val in privacy.items():
        if not isinstance(key, str) or not key.endswith("UsageDescription") or not isinstance(val, str) or not val.strip():
            raise ValueError(f"Invalid privacy permission entry {key!r}: {val!r}")

    versions = app.get("versions")
    if not isinstance(versions, list) or not versions:
        raise ValueError("altstore-source apps[0] missing non-empty 'versions' array")
    for idx, entry in enumerate(versions):
        if not isinstance(entry, dict):
            raise ValueError(f"altstore-source version[{idx}] must be an object")
        for key in ("version", "buildVersion", "date", "downloadURL", "minOSVersion"):
            val = entry.get(key)
            if not isinstance(val, str) or not val.strip():
                raise ValueError(f"altstore-source version[{idx}] missing non-empty {key!r}")
        if not ISO8601_UTC_RE.match(entry["date"]):
            raise ValueError(f"altstore-source version[{idx}] invalid UTC date {entry['date']!r}")
        if not entry["downloadURL"].startswith("https://"):
            raise ValueError(f"altstore-source version[{idx}] downloadURL must use https://")
        size = entry.get("size")
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise ValueError(f"altstore-source version[{idx}] size must be a positive integer")
        digest = entry.get("sha256")
        if not isinstance(digest, str) or not HEX_SHA256_RE.match(digest):
            raise ValueError(f"altstore-source version[{idx}] sha256 must be 64 lowercase hex chars")

    latest = versions[0]
    if expected_version is not None and latest["version"] != expected_version:
        raise ValueError(
            f"altstore-source versions[0].version is {latest['version']!r}, expected {expected_version!r}"
        )
    if expected_ipa is not None:
        actual_sha256, actual_size = sha256_and_size(expected_ipa)
        if latest["size"] != actual_size:
            raise ValueError(
                f"altstore-source versions[0].size is {latest['size']}, expected {actual_size}"
            )
        if latest["sha256"] != actual_sha256:
            raise ValueError(
                f"altstore-source versions[0].sha256 is {latest['sha256']}, expected {actual_sha256}"
            )
        if expected_release_tag is not None:
            expected_suffix = f"/releases/download/{expected_release_tag}/{expected_ipa.name}"
            if not latest["downloadURL"].endswith(expected_suffix):
                raise ValueError(
                    f"altstore-source downloadURL {latest['downloadURL']!r} does not end with {expected_suffix!r}"
                )
    return source


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info-plist", type=Path, help="Path to built OMGMobile.app/Info.plist")
    parser.add_argument("--ipa", type=Path, required=True, help="Path to packaged unsigned .ipa")
    parser.add_argument("--tag", required=True, help="GitHub release tag, e.g. v0.21.0")
    parser.add_argument("--output", type=Path, help="Output altstore-source.json path")
    parser.add_argument("--previous-source", type=Path, help="Optional previous altstore-source.json to prepend to")
    parser.add_argument("--release-date", help="Optional explicit ISO-8601 UTC date (YYYY-MM-DDTHH:MM:SSZ)")
    parser.add_argument("--validate", type=Path, help="Validate an existing altstore-source.json against --ipa")
    parser.add_argument("--expected-version", help="Expected CFBundleShortVersionString during validation")
    args = parser.parse_args(argv)

    if args.validate is not None:
        payload = json.loads(args.validate.read_text(encoding="utf-8"))
        validate_altstore_source(
            payload,
            expected_version=args.expected_version,
            expected_ipa=args.ipa,
            expected_release_tag=args.tag,
        )
        return 0

    if args.info_plist is None or args.output is None:
        parser.error("--info-plist and --output are required when not using --validate")

    info = read_app_info_plist(args.info_plist)
    previous: dict[str, Any] | None = None
    if args.previous_source is not None and args.previous_source.is_file():
        previous = json.loads(args.previous_source.read_text(encoding="utf-8"))

    source = build_altstore_source(
        info,
        args.ipa,
        args.tag,
        info_plist_path=args.info_plist,
        release_date=args.release_date,
        previous_source=previous,
    )
    validate_altstore_source(
        source,
        expected_version=info["CFBundleShortVersionString"],
        expected_ipa=args.ipa,
        expected_release_tag=args.tag,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
