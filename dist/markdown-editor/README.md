# OMG live Markdown editor

The Preview surface uses Milkdown Crepe (ProseMirror) for normal WYSIWYG editing,
CommonMark input rules, GFM tables/task lists, CodeMirror code blocks, and KaTeX.
All runtime assets are bundled offline. Existing Markdown-it, Mermaid, DOMPurify,
KaTeX CSS and fonts remain shared with the read-only renderer.

```sh
npm ci --prefix dist/markdown-editor
npm run build --prefix dist/markdown-editor
node dist/tests/markdown_live_editor.cjs
```

The checked-in package lock pins dependencies. Build writes `live-editor.js`,
`live-editor.css`, bundled legal comments, and `licenses/milkdown-editor.txt` under
`macos/Resources/MarkdownPreview`. No runtime CDN or font service is used.

`renderMarkdown(text, options)` creates/updates the live editor. Matching native
acknowledgements do not reset selection or history. `getMarkdown()` synchronously
returns the current source, including the last transaction. Every document edit
sends `{type: "edit", text, baseText}` through `markdownPreview`; `focus` is sent
on focus entry. `ready` is emitted only after this API is installed.
`renderMarkdownReadonly` remains available for read-only rendering and tests.

Standard blocks use Milkdown's Markdown parser and serializer, which may normalize
Markdown formatting after edits. Opening a file does not serialize or mark it dirty.
HTML/SVG, GitHub alert blocks, MkDocs/container admonitions and bracket-delimited math
are preserved as source-backed atoms so editing another block cannot discard them.
They reuse sanitized Markdown-it previews and expose a local source editor on double
click (Apply/blur/Command-Enter to commit, Escape to cancel). Mermaid and dollar math
use Crepe's editable code/inline math controls. Relative image sources stay unchanged
in the document and resolve through the existing local/SSH image scheme in node views.
