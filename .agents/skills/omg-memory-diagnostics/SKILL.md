---
name: omg-memory-diagnostics
description: Diagnose Oh My Ghostty (OMG Dev) memory growth on macOS using opt-in bounded lifecycle logs and external footprint samples. Use when asked to investigate OMG memory usage, leaks, IOSurface growth, renderer resources, window/tab/split retention, or to enable and interpret OMG Dev memory diagnostics.
compatibility: macOS, OMG Dev Debug bundle; optional Instruments and command-line footprint sampler.
---

# OMG Dev memory diagnostics

Use this skill in the `oh-my-ghostty` repository. Read `docs/omg-dev-memory-diagnostics.md` (relative to the repository root) for the current schema, enable switch, file paths and limitations. If building or testing, also read `.agents/skills/omg-build/SKILL.md`.

## Safety and scope

- Never quit, replace, rebuild over, or modify `/Applications/OMG.app`. Do not kill an existing OMG Dev process or install a new one without the user's consent. The Dev installer requires a clean committed tree; never commit or install merely to start diagnosis.
- The logger is **off by default**, only enabled in the Debug bundle `com.jischeng.omg.debug` when `OMG_DEV_MEMORY_DIAGNOSTICS=1` is present **at process launch**. Changing the variable for an already-running process does nothing.
- Treat process memory as an observation, not proof of a leak. `AgentLogoStatus.swift`'s animated `TimelineView` is only a profiling lead, not an established cause. A short-lived peak or an idle plateau is not evidence of retained resources.
- Never collect terminal text, command history, titles, environment dumps, paths from sessions, or allocation stacks in the persistent diagnostic log. The fixed JSONL schema contains timestamp, event and window/tab/surface-view counts only. It does **not** expose renderer, framebuffer, IOSurface, image cache or scrollback byte counts. Do not infer those figures from surface counts.
- Use separate debuggable Dev builds and Instruments Allocations only when specific allocation stacks are needed; Time Profiler and `leaks` do not by themselves rule out still-referenced resources.

## Workflow

1. **Inspect, don't disturb.** Confirm which app/bundle and PID the user wants sampled, whether the diagnostic switch was set at launch, and whether the logs exist. If the user only requests analysis, do not launch, restart or install anything. Treat old PIDs and `/tmp` sampling paths as historical, not current.
2. **Enable only when requested.** Build/test the Debug app following `omg-build` if needed. For a Dev app that is **not already running**, launch it explicitly from a shell so the variable reaches the process:
   ```sh
   OMG_DEV_MEMORY_DIAGNOSTICS=1 '/Applications/OMG Dev.app/Contents/MacOS/omg'
   ```
   For a source build, use `macos/build/Debug/OMG.app/Contents/MacOS/omg` instead. Verify the bundle ID before assuming a Debug build is eligible. Do not silently launch a second process if Dev is already running.
3. **Locate the bounded events.** Read `~/Library/Application Support/OMG/MemoryDiagnostics/events.jsonl` and `events.previous.jsonl` (up to 1 MiB each, owner-only). The prior file contains older samples. Parse JSONL by `time`, not by the order of a merged listing; preserve the `start` event as the run boundary. Do not publish raw logs unless the user requests them.
4. **Correlate with an independent system sample.** Prefer the user's existing footprint/IOSurface sample CSV if available, otherwise arrange a low-frequency (e.g. 60-second), read-only sample with the user's approval. Verify its units and timestamp timezone before joining it with UTC ISO-8601 JSONL events. Heap, IOSurface and total footprint must come from the system sampler, not the OMG JSONL. Do not attach Allocations to an unentitled app repeatedly or assume `get-task-allow` is present.
5. **Exercise and settle.** Record an idle baseline, a controlled period of opening/closing windows, native tabs and splits, and a post-close settling period. Compare counts and footprint after similar activity levels. Report temporary high-water marks separately from sustained post-close levels; distinguish retained views from retained underlying resources.
6. **Report evidence and uncertainty.** Give the run interval, sample interval, baseline/peak/post-close footprint, available heap/graphics breakdown, window/tab/surface-view counts around each action, and missing measurements. State whether changes persist after settling; list specific next experiments rather than claiming a root cause from correlation alone.

## Validation when the implementation changes

Run `macos/build.nu --action test --only-testing GhosttyTests/DevMemoryDiagnosticsTests` and `swiftlint lint --strict --config macos/.swiftlint.yml macos/Sources/Features/Terminal/DevMemoryDiagnostics.swift macos/Tests/Terminal/DevMemoryDiagnosticsTests.swift`. Check `python3 dist/check_omg_docs.py`. This skill is a workflow, not a new plugin API. If later work changes plugin APIs, manifests, wire messages, capabilities, lifecycle, loading/discovery, package layout, Inspector provider behavior or permissions, update `docs/PLUGIN_DEVELOPMENT.md` and relevant tests in the same commit.
