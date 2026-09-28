---
name: omg-debug
description: Diagnose Oh My Ghostty (OMG Dev) runtime problems on macOS, including memory growth, CPU activity, lifecycle retention, and crashes. Uses safe app metadata markers, bounded external footprint/CPU samples, Time Profiler and debuggable-build Instruments/LLDB when appropriate. Never touches the user's release OMG installation.
compatibility: macOS, OMG Dev Debug bundle; optional Xcode command-line tools.
---

# OMG debugging

Use this skill for OMG Dev runtime diagnosis. For memory/event schema and
sampling commands, read `docs/omg-dev-memory-diagnostics.md` from the repo root.
If building, testing, or preparing a separate debuggable app, also read
`.agents/skills/omg-build/SKILL.md` **before** running commands.

## Safety

- Do not quit, rebuild over, replace, or modify `/Applications/OMG.app`.
  Do not kill, relaunch, install over, or attach invasive tools to an existing
  OMG Dev process without the user's consent. A Dev install requires a clean
  committed tree; never commit/install merely to start diagnosis.
- Observe the *current* app/bundle/PID; old PIDs and `/tmp` files in a prior
  conversation are historical. For analysis-only requests, do not launch or
  change apps. Check process identity again before interpreting a later sample.
- The app logger is **off by default** and works only for Debug bundle
  `com.jischeng.omg.debug` when `OMG_DEV_MEMORY_DIAGNOSTICS=1` was in the
  environment at process launch. Setting it now does not enable an existing
  process. Never assume a source build or installed Dev is eligible without
  verifying its bundle identifier.
- Never write terminal text, commands, titles, session paths, env dumps, or
  stacks into persistent app logs. Fixed JSONL fields are time, event,
  surface-view/tab-controller/window-group counts, **not** resource bytes.
- Footprint/CPU and allocation stacks come from **external** system tools,
  not the app JSONL. CPU hot spots and coincident memory growth do not prove
  causality; a short peak or idle plateau does not establish a leak.

## Triage

1. Define symptom, process, workload, and whether the user permits profiling.
   Check current bundle/PID and log switch; inspect any existing bounded logs.
2. For memory, first check the two owner-only JSONL files under
   `~/Library/Application Support/OMG/MemoryDiagnostics/`. Sort by UTC `time`,
   keep `start` boundaries, and don't dump raw records. For CPU, distinguish
   current CPU-time delta from lifetime averages.
3. With approval, collect a separate **bounded, low-frequency** system trace
   using `python3 .agents/skills/omg-debug/scripts/observe.py sample --pid PID
   --output-dir /tmp/unique-private-dir --interval 60 --duration-minutes 120`.
   It verifies the Debug bundle, identity and private output location, stops
   automatically, and saves `system-samples.csv` with heap/graphics/IOSurface
   and CPU deltas. Use `observe.py report --csv PATH` to join action events to
   the nearest sample; the report marks timing offsets and excludes other runs.
   For a user-provided CSV, verify units/timezone/identity before joining.
4. Ask for a controlled idle baseline, opening/closing a window, native tab,
   and split, then a quiet settling interval after each. Compare *similar*
   states and report baseline, peak, post-close, sample interval, count changes
   and missing measures. Distinguish retained views from retained Zig/Metal
   resources; don't infer image/cache/scrollback bytes from view counts.
5. For reproducible CPU use, ask before recording a bounded Time Profiler
   trace. For specific retained allocation call sites, prepare a **separately
   debuggable** OMG Dev and use Instruments Allocations / LLDB as permitted.
   LLDB is not a logging switch. Don't repeatedly attempt to attach
   Allocations to an unentitled app. `leaks` is incomplete for still-referenced
   memory. Keep raw traces private and do not copy stacks into app JSONL.
6. State evidence, uncertainty and next experiment; never claim a root cause
   solely from correlation. In particular, the `AgentLogoStatus.swift`
   TimelineView is a hypothesis, not a proven cause.

## When changing the implementation

- Validate focused Swift tests:
  `macos/build.nu --action test --only-testing GhosttyTests/DevMemoryDiagnosticsTests`.
- Validate Swift lint:
  `swiftlint lint --strict --config macos/.swiftlint.yml macos/Sources/Features/Terminal/DevMemoryDiagnostics.swift macos/Tests/Terminal/DevMemoryDiagnosticsTests.swift`.
- Validate sampler: `python3 -m unittest discover -s .agents/skills/omg-debug/scripts -p 'test_*.py'`.
- Check `python3 dist/check_omg_docs.py`. The skill is not a plugin API. If
  later work changes plugin APIs, manifests, wire messages, capabilities,
  lifecycle, loading/discovery, package layout, Inspector provider behavior
  or permissions, update `docs/PLUGIN_DEVELOPMENT.md` and relevant tests in
  the same commit.
