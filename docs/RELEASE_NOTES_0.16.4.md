# OMG 0.16.4 · Ghostty 1.3.2-dev

OMG 0.16.4 improves link hover and click UX, fixes AppKit cursor flicker issues
on macOS, and adds support for Nerd Font file path recognition without changing
the upstream Ghostty core version.

## Highlights

- **Link hover follower chip** — replace the pointing-hand cursor with a sleek
  follower chip ("⌘ Click to open" / "⌘ 点击打开"). On macOS, changing AppKit
  cursor rects repeatedly during link hovers causes cursor flicker; the hint
  chip keeps the current cursor stable and clearly indicates the shortcut.
- **Deduplicated link hover updates** — prevent redundant republishing of the
  link URL and cursor shape when the mouse moves across cells of the same link,
  avoiding unnecessary SwiftUI overlay re-renders.
- **Cwd-aware relative hover preview** — resolve relative path candidates against
  the command output's current working directory for hover previews, ensuring
  the displayed path matches exactly what Cmd-click opens.
- **Cmd-link bypass for terminal mouse capture** — macOS mouse protocols cannot
  encode Command modifiers, so Cmd-clicks on hovered links are now kept within
  OMG rather than incorrectly sent to mouse-reporting terminal applications.
- **Nerd Font icon path detection** — recognize bare file and directory candidates
  preceded by Nerd Font Private Use Area (PUA) glyphs (such as those output by
  `eza` or `lsd`).
- **Cursor and layout stability fixes** — hide dismissed quick input composers
  from AppKit cursor handling so the terminal cursor is not reset to an I-beam,
  and elevate the quick input dock divider zIndex so drag handles respond reliably.
- **Accent-highlighted dividers** — highlight sidebar, inspector, and split dividers
  with the theme accent color during hover or drag using stable `inVisibleRect`
  tracking areas.

## Version and scope

- OMG version: **0.16.4**; bundle version: **37**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.3.
- This is a feature and bug-fix release. Plugin capabilities, permissions, and the
  user-consent model are unchanged.

## Validation status

- SwiftLint `--strict`: zero violations across all Swift files. Zig formatting,
  settings JSON, plist/XIB, documentation contract, and shell syntax checks passed.
- Signing and keychain automation tests passed using the authorized persistent identity.
- Routine Swift tests passed for all commits since **v0.16.3**.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.4 / build 37**. All passed architecture, version, base revision,
  icon, exact signer/DR, and nested-signature checks. Designated requirements match
  0.16.3 and satisfy mutual identity compatibility.
- Arm64 and universal signed apps and read-only mounted DMG apps launched with
  `.ReleaseFast`. Intel slices and build markers verified.
- All three DMGs passed checksum verification and read-only mount inspection; the
  SHA-256 manifest verified every image.
- Appcast metadata verified **0.16.4 / build 37**, minimum macOS **13.0**, one universal
  enclosure of the expected length, strictly increased bundle version, and retained older
  entries with valid Sparkle Ed25519 signature.

## Signing and distribution

Release apps reuse the **persistent self-signed identity from 0.16.3; not notarized**.
This is not Apple Developer ID distribution. Gatekeeper may block the first launch;
users who trust the download can review and allow it in System Settings > Privacy &
Security. Do not disable Gatekeeper globally. DMGs are not notarized. Sparkle updates
retain their independent EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and `appcast.xml`.
The universal DMG is the single Sparkle updater enclosure.
