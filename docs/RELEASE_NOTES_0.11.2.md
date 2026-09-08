# OMG 0.11.2

OMG 0.11.2 is a patch release focused on remote SSH image paste handling and
built-in editor improvements. It keeps the Ghostty base at `1.3.2-dev`.

## Highlights

- **SSH image paste handling:** Images copied from external applications such as
  Lark/Feishu or Finder as file URLs are now recognized by the image paste
  pipeline instead of being treated as plain local strings. In active SSH
  sessions, they are automatically uploaded to the remote host via SFTP and
  pasted as the remote path, preserving the file extension (e.g. `.jpg`,
  `.png`, `.webp`).
- **Unified image resolution:** Routes image paste consistently across the
  terminal surface, the Agent Quick Input composer, and terminal drag-and-drop.
- **Built-in editor polish:** Contains the editor backdrop within its pane,
  corrects syntax highlighting and completion popup placement, and repairs
  editor completion behavior.

## Verification

- Image paste, local file URL detection, and SFTP extension tests pass.
- Editor completion, backdrop containment, and layout tests pass.
- The complete macOS app-hosted test suite passes.
- arm64, x86_64, and universal ReleaseFast applications are built and checked.

## Distribution status

Release artifacts are signed according to the local maintainer release workflow.
Notarization status is reported with the generated artifacts.
