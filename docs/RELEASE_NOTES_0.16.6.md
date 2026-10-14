# OMG 0.16.6 · Ghostty 1.3.2-dev

OMG 0.16.6 turns Agent Quick Input into a recallable prompt surface: sent
messages are remembered per pane or tab, searchable, and reachable from the
keyboard, while the composer, its pin state, and the Inspector sidebar now
open and close immediately instead of animating. The upstream Ghostty core is
unchanged.

## Highlights

- **Sent history** — Quick Input remembers what you actually sent, not what you
  drafted. A send is recorded only after the PTY write succeeds, so drafts,
  queued-but-unsent messages, and failed writes stay out of the list, and
  consecutive identical sends refresh their timestamp instead of duplicating.
- **Persistent, bounded storage** — history survives quitting unless you turn
  retention off. It is stored as unencrypted JSON under the channel-specific
  Application Support directory (`quick-input-history/history.json`, directory
  mode `0700`, file mode `0600`), bounded to 50 messages per pane, 1,000 overall,
  8 MiB of prompt text, and 1 MiB per message. Records expire after
  `keyboard.quickInputHistoryRetentionDays` (default 7) and are pruned at launch,
  on writes and settings changes, on opening History, every minute, and on quit.
- **Scope, search, and insertion** — the picker filters by
  `keyboard.quickInputHistoryScope` (`pane`, `tab`, or `global`; the default is
  now `tab`), searches on demand from a collapsed header button, and inserts
  through `keyboard.quickInputHistoryInsertionMode`: append to the draft
  (default) or replace it. Selecting an entry never sends it; the recalled
  message still has to be submitted deliberately.
- **Keyboard navigation** — `↑`/`↓` walk the picker, `Enter` inserts, and
  `Escape` steps back out of search before closing and restores exactly the
  draft and caret position that were being typed. Unmodified `↑` in an empty
  composer still recalls the latest send, and `⌘⇧H` toggles the picker from any
  pane, opening the composer first when it is closed. `⇧⌘Z`-style IME
  composition and queued-item editing are excluded from all recall paths.
- **Pin** — the new pin control keeps the composer open across send and queue
  without taking terminal focus, so repeated prompts do not require reopening
  the dock. Visibility and pin are process-wide across tabs and windows, while
  drafts, queues, and targets stay owned by their own pane. New tabs inherit the
  current visibility, and closing one pane no longer collapses the composer in
  unrelated tabs.
- **Terminal-matched typography** — the composer and history list now use the
  active Terminal family and size, including a regular-weight conversion for
  families that only register faces such as Bold, instead of a hardcoded
  monospaced font.
- **Immediate chrome** — the composer no longer waits 0.34 seconds for a spring
  animation before the terminal resize settles; it opens and closes like a
  terminal split, and terminal layout reserves the final accessory height once.
  The Inspector sidebar follows the same rule: visibility, shell width, and the
  native titlebar accessory width update together with no slide or fade, and
  retained hidden content can no longer receive pointer events or appear in
  accessibility navigation. Provider lifecycle semantics are unchanged.
- **Honest History layout** — the picker measures its bounded preview text
  instead of trusting a scroll viewport measurement, so two short entries both
  fit and a long list grows to a 480pt scrollable cap rather than inheriting a
  one-row height.
- **Continuous History hit target** — the footer action, shortcut hints, and
  labels now share one style module, and the History button accepts clicks across
  its icon, gap, and padding instead of only the glyph.

- **Mermaid mount lifecycle** — live Markdown diagrams no longer permanently
  lose their render when widget construction precedes DOM attachment. Rendering
  waits for mounting, retries a still-live remount after discarding detached
  results, and cancels observation on destruction. Source checks and SVG
  sanitization remain intact; renderer/load errors are shown without retry loops.
  A new actual WKWebView regression reproduces the old 10-second SVG timeout and
  passes with the lifecycle fix.

- **Process lifecycle isolation** — local Git/SSH subprocess startup and stop
  ordering now use a dedicated queue instead of holding the result-state lock
  around Foundation Process APIs. This avoids blocking the caller's executor
  during spawn and removes a termination-callback lock-order hazard. Regression
  coverage exercises rapid exits racing timeout/cancellation, failed launches,
  binary pipe draining and compact-tree listing. The historical interrupted
  tree-listing run had no thread sample, so this is not claimed as proof of its
  unique cause or as cleanup of unrelated login sessions.

## Version and scope

- OMG version: **0.16.6**; bundle version: **39**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.5.
- This release is published as a **patch** at the maintainer's explicit request
  even though it contains new user-visible capabilities; `docs/RELEASING.md`
  otherwise reserves new capabilities for a minor bump.
- Plugin capabilities, permissions, and the user-consent model are unchanged.
  `docs/PLUGIN_DEVELOPMENT.md` records the Quick Input ownership split between
  process-wide chrome state and per-pane models, plus the Inspector sidebar's
  immediate presentation, in the same commits as the code.

## Validation status

- SwiftLint `--strict`: zero violations across 441 Swift files. Zig formatting,
  settings JSON, documentation contract, plist, and XIB checks passed, as did the
  signing/keychain/test-plan contracts (`test_omg_signing.py` 17 tests, 2 smoke
  skips; `test_omg_keychain.py` 15 tests, 1 skip; `test_omg_test_plan.py` 41
  tests). The `dist/markdown-editor` bundle was rebuilt and verified
  byte-identical to the checked-in `live-editor.js`, and all four Node suites
  (model, widgets, live editor, preview) passed.
- Routine Swift tests passed for all commits since **v0.16.5**: 987 tests in 118
  suites, `TEST SUCCEEDED` (scope `all`). Benchmarks are skipped by default and
  the `.interactiveDesktop` native input tier is **NOT RUN** (default exclusion;
  XCUITest remains excluded).
- Three earlier sweep attempts on this machine failed on load-sensitive tests
  that pass in isolation, which is why this release also fixes two of them:
  the live-editor Mermaid widget now waits for mount and retries discarded
  results instead of depending on a render window, and `GitProcessRunner` now
  orders Foundation launch/termination work on a dedicated queue outside its
  state lock, so a spawn or teardown callback can no longer deadlock under a
  118-suite sweep. The remaining observed flake, a vertical-tab title publication
  timing assertion, passed in isolation and in the final green sweep.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.6 / build 39**, Ghostty base **1.3.2-dev**. Each binary
  carries exactly its named architecture (universal: `arm64 x86_64`); bundle ID,
  OMG version, bundle version, and Ghostty base version verified on all three.
- Signed with the persistent self-signed identity; the designated requirement is
  identical to 0.16.5
  (`identifier "com.jischeng.omg" and certificate leaf = H"9b2e176c…"`) and
  identical across all three architectures, with the mutual-compatibility check
  against the preserved 0.16.5 universal app passing.
- Launch probes: arm64 and universal apps and their read-only mounted DMG apps
  launched with `.ReleaseFast`. **Rosetta 2 is not installed on the build
  machine**, so the x86_64 binary was verified by Mach-O slice inspection and the
  `.ReleaseFast` build marker instead of a launch; its DMG mounted and passed
  signature and designated-requirement identity checks. Intel hardware launch was
  **NOT RUN**.
- All three DMGs mounted read-only and passed signature checks; the SHA-256
  manifest covers every image.
- Appcast metadata verified **0.16.6 / build 39**, minimum macOS **13.0**, one
  universal enclosure with a Sparkle EdDSA signature, a strictly larger numeric
  bundle version, and retained 0.16.5 / 0.16.4 entries.
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
