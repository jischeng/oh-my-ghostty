# OMG 0.16.8 · Ghostty 1.3.2-dev

OMG 0.16.8 makes the editor highlight files it could not read, gives the
sidebar a uniform set of agent icons, and stops the terminal from offering to
open a file that does not exist. The upstream Ghostty core is unchanged.

## Highlights

- **Editor highlights structured files without a known extension** — opening
  `flake.lock` showed no highlighting at all: it is JSON, but the extension is
  not in the editor's language table, so the file fell back to plain text. The
  same happened to lockfiles, extension-less configs, and files with uncommon
  extensions, even when their contents were clearly JSON, YAML, or TOML.
  Language selection now resolves in three stages. Filename aliases come first,
  limited to the specific names Zed lists for these formats, so a generic
  `.lock` file is never guessed to be JSON. The library's filename, shebang, and
  modeline detection runs next. Only when both leave the buffer unrecognized
  does a content probe run, and it requires a format signature plus real
  tree-sitter structure: a top-level object or array for JSON, at least two
  mappings or sequence entries for YAML, and a pair or table for TOML. Source
  languages are additionally gated on a clean parse. Prose, a single sentence
  containing a colon, and buffers over 512KB stay plain text. A cached
  plain-text result is rechecked rather than trusted forever, because an editor
  pane can mount before its document finishes loading.
- **JSON and YAML highlighting follows Zed's capture model** — the previous fix
  recovered keys, booleans, nulls, and escapes by walking the grammar tree and
  guessing node types. It worked, but it re-derived semantics the grammars
  already express and had to special-case each node type, including JSON
  naming boolean nodes after the literal itself. The provider now runs Zed's own
  query files for these two languages and resolves names with the same
  prefix walk, then maps the result onto the slots the pinned theme can
  express. Names with no slot, such as the punctuation captures the theme
  cannot render, resolve to nil and leave the grammar's styling untouched
  rather than inventing a color. Zed deliberately captures a key twice, as both
  `@string` and `@property.json_key`, so captures are deduplicated by name
  specificity to let the key slot win instead of relying on provider ordering.
- **A bare period is not a path link** — a lone `.` in terminal output was
  parsed as a relative path and turned into a clickable link that resolved
  against the pane's working directory, so ordinary prose ending in a full stop
  offered to open a file that does not exist. The bare `.` is now rejected
  while explicit relative paths such as `./`, `./README.md`, `.gitignore`, and
  `../README.md` stay clickable, and `file://` targets keep resolving normally.
- **One icon language for every agent in the sidebar** — Reasonix, Crush, Droid,
  and Hermes appeared in the sidebar as a solid accent square while focused or
  working, and as full-colour artwork when idle. Both symptoms had one cause:
  tab icons tint by masking the icon's alpha channel with the activity colour,
  which assumes a silhouette on a transparent background. The four raster brand
  assets instead carry an opaque, fully covered canvas, so the mask filled the
  whole tile and erased the mark. Agent manifests now declare icons in two
  roles. `iconAsset` stays the full-colour product artwork rendered unchanged by
  Settings and the Inspector, while the optional `iconGlyph` is a monochrome
  template used only for tab presentation. The four raster agents gained
  transparent `Agent*Glyph` imagesets built from their projects' published
  marks, and the Hermes glyph now uses the portrait path from the project's own
  icon asset rather than an inverted recolouring of a third-party mark.
- **Terminal icons keep their colour** — a terminal or workspace icon has no
  agent activity, so the activity tint would be fully transparent, yet the
  overlay still moved the icon into the native animation host. That hosting view
  does not carry the icon's foreground style, so a system symbol fell back to
  its untinted template black and the sidebar showed a black terminal glyph
  instead of the label grey. The tint overlay now applies only to an agent
  logo, which is the only case where it draws anything.
- **Link hover clears when the Command key is released during IME input** — a
  link hover could stay active after the Command key was released while an input
  method was composing, leaving a stale highlight behind.

## Version and scope

- OMG version: **0.16.8**; bundle version: **41**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.7.
- Plugin capabilities, permissions, and the user-consent model are unchanged.
  `docs/PLUGIN_DEVELOPMENT.md` records the two-role icon contract in the same
  commits as the code.
- Settings controls beyond the 18 catalogued options remain available through
  the original Ghostty configuration file; unsupported controls are not
  fabricated for visual parity with other terminals.

## Validation status

- SwiftLint `--strict`: zero violations across 455 Swift files. Zig formatting,
  settings JSON, documentation contract, plist, and XIB checks passed, as did the
  signing/keychain/test-plan contracts (`test_omg_signing.py` 17 tests, 2 smoke
  skips; `test_omg_keychain.py` 15 tests, 1 skip; `test_omg_test_plan.py` 41
  tests).
- Routine Swift tests passed for all commits since **v0.16.7**: 1020 tests in 121
  suites, `TEST SUCCEEDED` (scope `changed-since v0.16.7`, which expands to all
  routine suites because `src/apprt/embedded.zig` changed). Benchmarks are
  skipped by default and the `.interactiveDesktop` native input tier is **NOT
  RUN** (default exclusion; XCUITest remains excluded). The editor language
  detection, JSON and YAML highlighting, path-link rejection, and the agent
  icon contract were exercised in this sweep, not only in isolation.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.8 / build 41**, Ghostty base **1.3.2-dev**. Each binary
  carries exactly its named architecture (universal: `x86_64 arm64`); bundle ID,
  OMG version, bundle version, and Ghostty base version verified on all three.
- Signed with the persistent self-signed identity; the designated requirement is
  identical to 0.16.7 and identical across all three architectures
  (`identifier "com.jischeng.omg" and certificate leaf = H"9b2e176c…"`), with the
  mutual-compatibility check against the preserved 0.16.7 universal app passing.
- Launch probes: arm64 and universal apps and their read-only mounted DMG apps
  launched with `.ReleaseFast`. **Rosetta 2 is not installed on the build
  machine**, so the x86_64 binary was verified by Mach-O slice inspection and the
  `.ReleaseFast` build marker instead of a launch; its DMG mounted and passed
  signature and designated-requirement identity checks. Intel hardware launch was
  **NOT RUN**.
- All three DMGs mounted read-only and passed signature checks; the SHA-256
  manifest covers every image.
- Appcast metadata verified **0.16.8 / build 41**, minimum macOS **13.0**, one
  universal enclosure with a Sparkle EdDSA signature, a strictly larger numeric
  bundle version, and retained 0.16.7 / 0.16.6 entries.
- Full Desktop/Documents/Downloads and Sparkle upgrade permission experiments are
  **NOT RUN**; per maintainer decision they are not a release prerequisite, and
  static signature verification does not establish end-to-end TCC behavior.

## Signing and distribution

Release apps reuse the **persistent self-signed identity; not notarized**. This
is not Apple Developer ID distribution. Gatekeeper may block the first launch;
users who trust the download can review and allow it in System Settings >
Privacy & Security. Do not disable Gatekeeper globally. DMGs are not notarized.
Sparkle updates retain their independent EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
