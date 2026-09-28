# OMG Dev memory diagnostics

This is an opt-in, metadata-only aid for correlating user actions with an **external**
footprint sampler. It is not a leak detector and does not attribute allocations.

Run the Debug OMG Dev bundle with `OMG_DEV_MEMORY_DIAGNOSTICS=1` in its environment
**before launch**. A Release build or a Debug build with another bundle identifier
cannot enable it. Unset the variable and restart to disable it (the default).
For example, from a terminal:

```sh
OMG_DEV_MEMORY_DIAGNOSTICS=1 '/Applications/OMG Dev.app/Contents/MacOS/omg'
```

The JSONL files are in
`~/Library/Application Support/OMG/MemoryDiagnostics/events.jsonl` and
`events.previous.jsonl`. Each is capped at 1 MiB, with owner-only permissions.
The current file rotates into the previous file; older samples are discarded.
Each entry has an ISO 8601 UTC timestamp, a fixed event name, a count of live
macOS surface views, and the numbers of open terminal tab controllers and
native window groups observed at that instant. Events include start, surface
creation/destruction, tab creation, window opening/closing and one sample per
minute. The counts are **not** measurements of retained Zig surfaces: disposal
of the underlying resources may lag view destruction, and controllers may lag
window closure. Window-group counts are a best-effort AppKit snapshot.

The file intentionally contains no terminal text, commands, titles, paths,
process IDs, or allocation stacks. Renderer allocations, framebuffers,
IOSurfaces, image cache and scrollback bytes are **not available** from this
macOS host instrumentation; correlate with `footprint`, Instruments and other
system tools instead of interpreting view counts as graphics/heap bytes.
For concrete allocation call stacks, use a separately prepared debuggable Dev
build and Instruments Allocations, not persistent production instrumentation.

Compare an idle baseline with repeated opening/closing of windows, native tabs,
and splits; wait for the counters and the external footprint to settle before
interpreting retained memory. Transient peaks alone do not establish a leak.
