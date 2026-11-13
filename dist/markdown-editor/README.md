# OMG Markdown Preview Renderer Tests

Markdown documents use two clean, zero-mutation surfaces:

- **Edit mode**: OMG's native `CodeEditorView` (`CodeEditSourceEditor` + Tree-sitter + `MarkdownHighlightProvider`) with word-wrap enabled by default and full viewport resize reflow.
- **Preview mode**: `MarkdownPreviewView` (`WKWebView` + offline `markdown-it`, `Highlight.js`, `KaTeX`, `Mermaid`, and `DOMPurify` under `macos/Resources/MarkdownPreview/`).

No rich-text or CodeMirror DOM editor re-serializes the Markdown document. Opening or rendering never rewrites source text. Task-list checkboxes in active previews toggle only their exact `[ ]` / `[x]` character offset through the version-checked `{type: "edit", text, baseText}` bridge; `file://` and workspace-relative file links route through `{type: "openLink", href}`; fenced code blocks copy through `{type: "copy", text}`; and Antigravity ````carousel```` blocks render interactive slide cards.

```sh
npm test --prefix dist/markdown-editor
```
