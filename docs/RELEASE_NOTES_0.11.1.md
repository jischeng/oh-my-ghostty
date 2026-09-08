# OMG 0.11.1

OMG 0.11.1 is a patch release for the built-in editor and terminal workflow.
It keeps the Ghostty base at `1.3.2-dev` and focuses on Markdown preview
correctness and terminal color behavior.

## Highlights

- **Markdown live preview:** Recognizes fenced code blocks nested inside lists,
  including indented shell blocks, while preserving their source ranges and
  language-specific rendering.
- **Markdown source editing:** Keeps the CodeMirror source-first editor aligned
  with the existing markdown-it renderer for tables, formulas, Mermaid,
  alerts, admonitions, images, and HTML/SVG blocks.
- **Terminal colors:** Removes inherited `NO_COLOR` from the OMG host environment
  so color-capable tools such as `eza` and `ll` retain their color output.

## Verification

- Markdown model, widget, live-editor, and preview integration tests pass.
- The complete macOS app-hosted test suite passes.
- arm64, x86_64, and universal ReleaseFast applications are built and checked.

## Distribution status

Release artifacts are signed according to the local maintainer release workflow.
Notarization status is reported with the generated artifacts.
