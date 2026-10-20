# OMG 0.16.7 · Ghostty 1.3.2-dev

OMG 0.16.7 organizes Settings around what you are trying to do instead of
internal modules, gives every page the same control vocabulary, and turns Agent
integration into something you set up once per account and then forget. Agent
Hook setup now runs where you started it, reports progress and failures in place,
and keeps CLI maintenance separate from Hook state. The editor no longer loses
content or crashes after deleting large ranges. The upstream Ghostty core is
unchanged.

## Highlights

- **Task-oriented Settings** — the sidebar is arranged as **General**, **Shell &
  Sessions**, **Input & Controls**, **Editor**, **Views & Tabs**, **Appearance**,
  **Shortcuts**, and **Advanced**, plus an expandable **Integrations** group with
  **Agent**, **Git**, **SSH**, and **Plugins**. Existing navigation identifiers and
  JSON keys still resolve, so nothing is migrated or renamed on disk.
- **Sidebar search** — search matches English and Chinese labels, aliases, and
  persisted setting IDs, then navigates to the owning section rather than
  rendering a second editable copy of the same control. Every descriptor has
  exactly one destination, and unknown future keys fall back to Advanced.
- **Optional core overrides** — 18 behaviors Ghostty already implements
  (close confirmation, last-window quit, working-directory and font inheritance,
  shell integration, selection clearing, copy-on-select, clipboard read/write,
  trimming and paste safety, pointer focus and hiding, Option-as-Alt, terminal
  notifications, cursor blinking) are reachable from the GUI as
  `core.<ghostty-key>`. An empty value means **Follow Ghostty Config**; explicit
  choices are appended to the existing generated `appearance.ghostty` overlay, so
  the baseline configuration file, unrelated keys, and unknown hand-edited values
  are preserved. Only catalogued keys and listed values can reach the overlay,
  and resetting removes only the OMG override.
- **One control vocabulary** — pickers, segmented controls, numeric fields, and
  buttons share a 32-point action height, themed background and border, and
  trailing alignment. The picker draws its own trigger over a transparent native
  button that opens an `NSMenu`, which keeps type-ahead, keyboard navigation, and
  VoiceOver while no longer dropping custom label layout through the SwiftUI
  menu bridge. Menu items capture their values rather than list positions, and
  the entire trigger is a hit target.
- **Agent setup, once per account** — the SSH banner's **Enable All Detected**
  now queues a manager-owned job, waits for any in-flight inventory, discovers
  CLIs when needed, installs missing or stale Hooks, and reports queued,
  running, complete, or retryable failure in the same banner. It no longer opens
  Settings or needs a second click; repeated clicks coalesce into one job and
  only **Customize** navigates. Choices, dismissals, and known CLI IDs persist
  per account, so reconnects, app restarts, and Hook upgrades do not re-prompt —
  only a newly detected CLI does.
- **Failure reports that stay separate** — Hook and CLI maintenance errors are
  recorded independently, so a failed `npm` upgrade is no longer presented as a
  Hook installation failure. The first line stays short and actionable, affected
  Agents are named, authentication and package-manager guidance appear where they
  apply, and vendor output, tracebacks, and updater logs are collapsed behind a
  disclosure instead of dominating the controls. OMG does not log into vendor
  accounts or bypass updater authentication; Reasonix npm installations take the
  npm update path from the outset because its native updater refuses to run under
  a package manager.
- **Honest connection state** — a plain `ssh host` registration, whether from
  config or from a live pane, recognizes the same account after reconnecting
  from another local directory. Destination, alias, and executable still have to
  match with both option lists empty; explicit options, user, port, and jump
  changes keep separate identities, and only the selected matching record is
  marked connected. "Not connected in OMG" describes the absence of a matching
  ready pane, not a failed network probe.
- **Editor reliability after large deletes** — CodeEditSourceEditor moves
  0.9.1 → 0.15.2 and CodeEditTextView 0.7.7 → 0.12.1. Deleting a few hundred lines
  could corrupt the line-storage tree and leave only part of the file visible, and
  the highlighter's style store could index past the end of its rope while syncing
  a deletion, trapping the process. Both fixes ship only in the newer tags, so the
  editor packages move together. The migration folds presentation options into one
  `SourceEditorConfiguration`/`SourceEditorState`, moves theme colors to
  `EditorTheme.Attribute`, and derives layout from `rectForOffset`. Three
  upgrade regressions are fixed with it: the minimap backdrop uses a transparent
  sRGB color for `NSColor.clear`, multi-caret edits open their undo group before
  the first mutation lands, and `EditorSelectionClamp` trims selections after the
  storage shrinks so undo cannot scroll stale carets.
- **Reconnect hygiene** — a reconnected SSH workspace waits for a fresh remote
  working directory before it is exposed, stale foreground observations are
  rejected, and abandoned mouse reporting is cleared at session boundaries, so a
  dropped connection can no longer leave a pane reporting positions for a
  directory or application it left behind.
- **Public documentation** — the README is replaced with bilingual product and
  setup introductions, and workspace screenshots, editor, command-history, ACP
  commit-draft, and SSH capability guides were added alongside reporting and
  contribution policies, issue forms, and a pull-request template. The plugin
  system is documented as beta.

## Version and scope

- OMG version: **0.16.7**; bundle version: **40**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.6.
- Plugin capabilities, permissions, and the user-consent model are unchanged.
  `docs/PLUGIN_DEVELOPMENT.md` and `docs/settings/ORGANIZATION.md` record the
  navigation layout, search destinations, Agent setup ownership, and the closed
  core-override catalog in the same commits as the code.
- Settings controls beyond the 18 catalogued options remain available through the
  original Ghostty configuration file; unsupported controls are not fabricated
  for visual parity with other terminals.

## Validation status

- SwiftLint `--strict`: zero violations across 455 Swift files. Zig formatting,
  settings JSON, documentation contract, plist, and XIB checks passed, as did the
  signing/keychain/test-plan contracts (`test_omg_signing.py` 17 tests, 2 smoke
  skips; `test_omg_keychain.py` 15 tests, 1 skip; `test_omg_test_plan.py` 41
  tests).
- Routine Swift tests passed for all commits since **v0.16.6**: 1012 tests in 121
  suites, `TEST SUCCEEDED` (scope `all`). Benchmarks are skipped by default and
  the `.interactiveDesktop` native input tier is **NOT RUN** (default exclusion;
  XCUITest remains excluded). The Settings reorganization, unified controls, and
  Agent setup flow were exercised in this sweep, not only in isolation.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.7 / build 40**, Ghostty base **1.3.2-dev**. Each binary
  carries exactly its named architecture (universal: `x86_64 arm64`); bundle ID,
  OMG version, bundle version, and Ghostty base version verified on all three.
- Signed with the persistent self-signed identity; the designated requirement is
  identical to 0.16.6 and identical across all three architectures
  (`identifier "com.jischeng.omg" and certificate leaf = H"9b2e176c…"`), with the
  mutual-compatibility check against the preserved 0.16.6 universal app passing.
- Launch probes: arm64 and universal apps and their read-only mounted DMG apps
  launched with `.ReleaseFast`. **Rosetta 2 is not installed on the build
  machine**, so the x86_64 binary was verified by Mach-O slice inspection and the
  `.ReleaseFast` build marker instead of a launch; its DMG mounted and passed
  signature and designated-requirement identity checks. Intel hardware launch was
  **NOT RUN**.
- All three DMGs mounted read-only and passed signature checks; the SHA-256
  manifest covers every image.
- Appcast metadata verified **0.16.7 / build 40**, minimum macOS **13.0**, one
  universal enclosure with a Sparkle EdDSA signature, a strictly larger numeric
  bundle version, and retained 0.16.6 / 0.16.5 entries.
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
