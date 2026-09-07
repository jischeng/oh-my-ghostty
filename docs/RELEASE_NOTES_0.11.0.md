# OMG 0.11.0

OMG 0.11.0 adds the built-in code editor workflow to the macOS application,
including local and SSH file editing, GitHub-style Markdown preview and direct
Markdown editing. It also improves terminal path links and preserves the
working directory associated with historical output.

## Highlights

- **Built-in code editor:** Opens files from the Files inspector with configurable
  current-pane, tab and split destinations, plus independent Command-click folder
  behavior.
- **Markdown editing and preview:** Uses an offline Milkdown editor for direct
  editing with Markdown input rules, tables, task lists, formulas, Mermaid,
  images and preserved source-backed alert/admonition blocks.
- **Terminal path links:** Supports OSC 8 links, ordinary paths such as
  `README.md`, quoted names with spaces, historical output directories and safe
  fallback to the system default application for binary file types.
- **Editor settings:** Localizes the Editor settings in Chinese when selected
  and adds separate opening-location controls for files and Command-click folders.
- **Terminal environment:** Removes only inherited empty `NO_COLOR`, preserving
  explicit nonempty values so color-capable tools such as `eza` keep their output.

## Verification

- 581 macOS tests in 60 suites pass.
- SwiftLint, Zig formatting, JSON/schema, Plist, XIB and OMG documentation checks
  pass.
- Release artifacts target arm64, x86_64 and universal macOS applications, with
  the x86_64 path validated under Rosetta 2.

## Distribution status

Release artifacts are signed according to the local maintainer release workflow.
Notarization status is reported with the generated artifacts.
