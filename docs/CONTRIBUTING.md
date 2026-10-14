# Contributing to Oh My Ghostty

Thanks for helping improve OMG. This guide governs contributions to
[jischeng/oh-my-ghostty](https://github.com/jischeng/oh-my-ghostty), an independent
Ghostty fork. **OMG does not require Ghostty's upstream vouch process.**
English and Chinese issues/PR descriptions are welcome.

For bug reports and feature requests, use [Reporting problems](REPORTING.md).
For contributions to official Ghostty instead, follow its
[current upstream guide](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md).
The retained upstream text in the root [CONTRIBUTING.md](../CONTRIBUTING.md)
is reference material, not an instruction to seek approval in Ghostty for OMG
work. Inherited Vouch jobs are restricted to the official upstream repository.

## Before coding

- Search [OMG issues](https://github.com/jischeng/oh-my-ghostty/issues) and
  [pull requests](https://github.com/jischeng/oh-my-ghostty/pulls) for related work.
- Small, focused bug fixes, documentation improvements and regression tests can
  be proposed directly. Explain the problem and link related issues when present.
- Discuss major features, architecture changes, plugin boundaries, migration or
  changes to user-data handling in an OMG issue before doing extensive work.
- Keep fixes separate from unrelated refactors, formatting and version bumps.
  A proposal does not imply a maintainer has committed to accepting it.

## Preserve the host architecture

Read [Architecture](oh-my-ghostty-architecture.md), [AGENTS.md](../AGENTS.md)
and [macos/AGENTS.md](../macos/AGENTS.md).

- Keep the complete Ghostty macOS application as the host. Do not replace it
  with a private embedding layer without an explicitly approved migration.
- Prefer fork-owned feature files; keep upstream-owned edits to small adapters
  and the minimum necessary lower-level capability.
- Keep the terminal, native tab model, input, renderer and session lifecycle
  intact. Do not fabricate terminal output to represent application UI.
- Preserve independent OMG/Ghostty identities and version metadata, including
  copyright and MIT attribution.

## Build from source

Use Xcode's command-line tools; opening the Xcode GUI is not required. You need
Xcode, Zig 0.16.0 (the examples use `mise`), Nushell and SwiftLint. The app targets
macOS 13+, while the current app-hosted Swift test target requires macOS 15.5+.

On a clean checkout, or after affected Zig/core/build changes, build GhosttyKit:

```bash
mise exec zig@0.16.0 -- zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Dversion-string=1.3.2-dev
```

Use the current `GhosttyBaseVersion` in `macos/Ghostty-Info.plist` if the base
changes. Then build the Swift app:

```bash
macos/build.nu --configuration Debug --action build
```

The output is `macos/build/Debug/OMG.app`; the internal Xcode scheme and Swift
module remain named `Ghostty`. Development installs use **OMG Dev**, a separate
bundle identity/storage. Do not install a test build over, quit, or modify a
user's `/Applications/OMG.app`. Ask before changing or profiling an existing
OMG Dev instance. Development installation is governed by [Releasing](RELEASING.md).

## Test the affected behavior

Build and test **serially**. See [Testing](TESTING.md) for the executable
module map, dependent suites and optional desktop tier.

```bash
# Preview the selection before running it; choose the relevant base reference.
macos/build.nu --action test --changed-since origin/main --test-plan-only
macos/build.nu --action test --changed-since origin/main

# Alternatively, select relevant modules explicitly.
macos/build.nu --action test --test-modules quick-input
```

Shared host/core, test infrastructure and unmapped changes may select all routine
Swift suites. Swift tests do not replace affected Zig, Python, shell, JavaScript
or artifact checks. For example:

```bash
mise exec zig@0.16.0 -- zig build test -Dversion-string=1.3.2-dev -Dtest-filter='<affected test>'
python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'
# When changing the Markdown renderer/source bundle:
npm run build --prefix dist/markdown-editor
npm test --prefix dist/markdown-editor
```

After native tab, drag, focus or event-routing changes, also schedule relevant
`.interactiveDesktop` tests on an unlocked desktop with the test app foreground.
If they cannot run, record **NOT RUN** and the reason; a missing prerequisite is
not a pass. Do not increase timeouts, skip assertions, narrow a required selection
or repeatedly retry to hide a failing gate. Investigate and report intermittent
failures as well as successful reruns.

## Quality and documentation checks

Run relevant format/lint checks and the documentation contract:

```bash
swiftlint lint --strict --config macos/.swiftlint.yml macos
python3 dist/check_omg_docs.py
git diff --check
```

Use the repository's Zig/other formatting commands in [AGENTS.md](../AGENTS.md)
where applicable. Changes to user-facing settings must keep the UI, localization,
settings descriptors, [JSON schema](settings/schema.json), tests and
[configuration guide](settings/configuration.md) consistent.

Any change to plugin APIs, manifests, wire messages, capabilities, lifecycle,
loading/discovery, package layout, Inspector provider behavior or permissions
must update [Plugin Development](PLUGIN_DEVELOPMENT.md) and relevant tests in the
same commit. Do not advertise planned or internal APIs as a working third-party
plugin runtime.

## Pull-request checklist

Use the repository's PR template and include:

- the problem, the chosen approach and any user-visible behavior change;
- the affected layers: OMG host, upstream adapter/core, settings, plugin boundary;
- a regression test when practical (ideally a reproducible failure before the fix);
- exact test commands, scope/results and explicit not-run coverage/reasons;
- documentation/schema/localization updates, or why they are unnecessary;
- redacted screenshots for visible UI changes, without private terminal content;
- any known limitation, uncertainty or follow-up. Passing tests do not establish
  an unobserved historical root cause.

The author must understand and be able to explain the patch. AI assistance is
allowed, but disclose the tool and extent of assistance and review the output;
unverified generated code, diagnostics or test claims are not acceptable.
For upstream submissions, also follow Ghostty's stricter [AI policy](../AI_POLICY.md).
Do not use OMG's reporting helper to bypass upstream requirements.

## Releases and automation

Ordinary contributions do not authorize version bumps, release signing, tagging,
pushing, GitHub publication or replacing installed apps. Maintainers follow
[Releasing OMG](RELEASING.md), including persistent self-signing, identity
continuity, no notarization and independent Sparkle signing.

Agent tools/skills are optional execution aids. These public guides and applicable
repository instructions remain the policy reference. Publishing an issue/PR,
pushing or merging requires explicit user authorization; the dedicated report
skill has only the narrow authorization described in [Reporting](REPORTING.md).
