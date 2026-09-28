#!/usr/bin/env python3
"""Bounded, read-only OMG Dev system sampler and metadata-only event correlation.

No terminal/session content is collected. Requires macOS `ps` and `footprint`.
"""
import argparse
import bisect
import csv
import datetime as dt
import pathlib
import plistlib
import re
import statistics
import subprocess
import sys
import time

FIELDS = ("time", "pid", "footprint_mb", "malloc_small_mb", "malloc_large_mb",
          "iosurface_mb", "iosurface_regions", "graphics_unmapped_mb",
          "ioaccelerator_mb", "cpu_seconds", "cpu_percent", "note")
CATEGORIES = {
    "Malloc Small": "malloc_small_mb",
    "Malloc Large": "malloc_large_mb",
    "IOSurface": "iosurface_mb",
    "Owned physical footprint (unmapped) (graphics)": "graphics_unmapped_mb",
    "IOAccelerator (graphics)": "ioaccelerator_mb",
}
EVENTS = frozenset(("start", "sample", "surface_created", "surface_destroyed",
                    "tab_created", "tab_closed", "split_added", "split_removed",
                    "window_opened", "window_focused", "window_closing"))
UTC = dt.timezone.utc


def run(*args, timeout=45):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=True).stdout.strip()


def process_identity(pid):
    exe = pathlib.Path(run("ps", "-p", str(pid), "-o", "comm=", timeout=5)).resolve()
    started = run("ps", "-p", str(pid), "-o", "lstart=", timeout=5)
    if exe.name != "omg" or exe.parents[1].name != "Contents":
        raise ValueError("PID is not an OMG app executable")
    info_path = exe.parents[2] / "Contents" / "Info.plist"
    with info_path.open("rb") as file:
        bundle_id = plistlib.load(file).get("CFBundleIdentifier")
    if bundle_id != "com.jischeng.omg.debug":
        raise ValueError("PID does not belong to Debug OMG Dev (com.jischeng.omg.debug)")
    return str(exe), started


def to_mb(number, unit):
    return round(float(number) * {"B": 1 / 1048576, "KB": 1 / 1024,
                                  "MB": 1, "GB": 1024}[unit], 2)


def parse_footprint(text):
    result = {}
    for line in text.splitlines():
        amount = re.match(r"^\s*([\d.]+)\s+(B|KB|MB|GB)\s+", line)
        if not amount:
            continue
        if line.rstrip().endswith(" TOTAL"):
            result["footprint_mb"] = to_mb(*amount.groups())
        for category, field in CATEGORIES.items():
            if line.rstrip().endswith(" " + category):
                result[field] = to_mb(*amount.groups())
                if category == "IOSurface":
                    regions = re.search(r"\s(\d+)\s+IOSurface\s*$", line)
                    if regions:
                        result["iosurface_regions"] = int(regions.group(1))
                break
    if "footprint_mb" not in result:
        raise ValueError("footprint TOTAL missing")
    return result


def cpu_seconds(text):
    # ps time: [[days-]hours:]minutes:seconds.fraction
    days, sep, clock = text.strip().rpartition("-")
    parts = clock.split(":") if sep else text.strip().split(":")
    if len(parts) not in (2, 3):
        raise ValueError("unrecognized ps CPU time")
    seconds = float(parts[-1]) + int(parts[-2]) * 60
    if len(parts) == 3:
        seconds += int(parts[0]) * 3600
    return seconds + (int(days) * 86400 if sep else 0)


def sample(args):
    if args.interval < 15 or not 1 <= args.duration_minutes <= 360:
        raise ValueError("interval must be >=15 seconds; duration must be 1–360 minutes")
    identity = process_identity(args.pid)
    directory = args.output_dir.expanduser()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.stat().st_mode & 0o077:
        raise ValueError("output directory must be owner-only (0700)")
    output = directory / "system-samples.csv"
    # Exclusive create; don't overwrite a previous experiment.
    deadline = time.monotonic() + args.duration_minutes * 60
    previous = None
    with output.open("x", encoding="utf-8", newline="") as file:
        output.chmod(0o600)
        writer = csv.DictWriter(file, fieldnames=FIELDS)
        writer.writeheader()
        while True:
            started = time.monotonic()
            row = {"time": dt.datetime.now(UTC).isoformat(timespec="milliseconds"), "pid": args.pid}
            try:
                if process_identity(args.pid) != identity:
                    row["note"] = "process_changed"
                    writer.writerow(row)
                    file.flush()
                    break
                row.update(parse_footprint(run("footprint", "-p", str(args.pid))))
                current = cpu_seconds(run("ps", "-p", str(args.pid), "-o", "time=", timeout=5))
                row["cpu_seconds"] = round(current, 3)
                if previous is not None:
                    elapsed = started - previous[0]
                    row["cpu_percent"] = round(max(0, current - previous[1]) / elapsed * 100, 2)
                previous = (started, current)
            except (OSError, subprocess.SubprocessError, ValueError):
                row["note"] = "sample_failed"
            writer.writerow(row)
            file.flush()
            if started + args.interval > deadline:
                break
            time.sleep(max(0, args.interval - (time.monotonic() - started)))
    print(f"Samples: {output}")


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp missing timezone")
    return parsed.astimezone(UTC)


def load_events(directory):
    events = []
    for filename in ("events.previous.jsonl", "events.jsonl"):
        path = directory / filename
        if not path.exists():
            continue
        if path.stat().st_size > 1048576:
            raise ValueError("diagnostic JSONL exceeds documented 1 MiB cap")
        import json
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                obj = json.loads(line)
                if (isinstance(obj, dict) and
                        set(obj) == {"time", "event", "surfaces", "tabs", "windows"} and
                        obj["event"] in EVENTS and
                        all(type(obj[key]) is int and obj[key] >= 0
                            for key in ("surfaces", "tabs", "windows"))):
                    events.append((timestamp(obj["time"]), obj))
            except (ValueError, TypeError, KeyError):
                continue
    return sorted(events, key=lambda item: item[0])


def report(args):
    with args.csv.expanduser().open(newline="", encoding="utf-8") as file:
        rows = [r for r in csv.DictReader(file) if r.get("footprint_mb")]
    if not rows:
        raise ValueError("no successful footprint samples")
    if len({row["pid"] for row in rows}) != 1:
        raise ValueError("CSV contains samples from multiple processes")
    points = [(timestamp(row["time"]), row) for row in rows]
    points.sort(key=lambda item: item[0])
    events = load_events(args.events_dir.expanduser())
    boundaries = [t for t, event in events if event["event"] == "start" and t <= points[-1][0]]
    if boundaries:
        run_start = boundaries[-1]
        points = [(t, row) for t, row in points if t >= run_start]
        events = [(t, event) for t, event in events if t >= run_start]
    else:
        events = []  # Never join a previous run to an unmarked run.
    if not points:
        raise ValueError("no system samples after latest start event")
    first, last = points[0], points[-1]
    peak = max(points, key=lambda item: float(item[1]["footprint_mb"]))
    print(f"Run: {first[0].isoformat()} – {last[0].isoformat()} UTC; samples={len(points)}")
    for label, (when, row) in (("baseline", first), ("peak", peak), ("final", last)):
        print(f"{label}: {when.isoformat()} footprint={row['footprint_mb']} MB "
              f"heap=({row['malloc_small_mb']}+{row['malloc_large_mb']}) MB "
              f"IOSurface={row['iosurface_mb']} MB/{row['iosurface_regions']} regions "
              f"graphics=({row['graphics_unmapped_mb']}+{row['ioaccelerator_mb']}) MB")
    times = [t for t, _ in points]
    intervals = [(b - a).total_seconds() for a, b in zip(times, times[1:])]
    tolerance = max(60, 1.5 * statistics.median(intervals)) if intervals else 60
    matched = 0
    for when, event in events:
        if event["event"] in ("start", "sample") or when < times[0] or when > times[-1]:
            continue
        index = bisect.bisect_left(times, when)
        nearest = min((i for i in (index - 1, index) if 0 <= i < len(points)),
                      key=lambda i: abs((times[i] - when).total_seconds()))
        age = abs((times[nearest] - when).total_seconds())
        if age > tolerance:
            continue
        row = points[nearest][1]
        print(f"event: {when.isoformat()} {event['event']} "
              f"views={event.get('surfaces')} tabs={event.get('tabs')} "
              f"windows={event.get('windows')} nearest={row['footprint_mb']} MB "
              f"CPU={row.get('cpu_percent') or 'n/a'}% offset={age:.0f}s")
        matched += 1
        if matched >= args.max_events:
            print("event output limit reached")
            break
    if not boundaries:
        print("No matching start boundary: events from other runs were excluded.")
    elif not matched:
        print("No action events matched the sample window.")
    print("Correlation only: compare settled post-close levels; view counts are not retained GPU/Zig resources.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sampler = sub.add_parser("sample", help="sample a running Debug OMG Dev; no launch/attach")
    sampler.add_argument("--pid", type=int, required=True)
    sampler.add_argument("--output-dir", type=pathlib.Path, required=True)
    sampler.add_argument("--interval", type=int, default=60)
    sampler.add_argument("--duration-minutes", type=int, default=120)
    reporter = sub.add_parser("report", help="join an existing CSV to bounded action events")
    reporter.add_argument("--csv", type=pathlib.Path, required=True)
    reporter.add_argument("--events-dir", type=pathlib.Path,
                          default=pathlib.Path.home() / "Library/Application Support/OMG/MemoryDiagnostics")
    reporter.add_argument("--max-events", type=int, default=40)
    args = parser.parse_args()
    try:
        if args.command == "sample":
            sample(args)
        else:
            report(args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
