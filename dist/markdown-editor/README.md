# OMG live Markdown editor

The Preview surface uses CodeMirror 6 with Markdown source as the single source
of truth. Ordinary lines use live decorations for rendered styling while editing
the underlying text. Complex blocks reuse the existing sanitized Markdown-it
renderer in widgets mapped to source ranges: tables, Mermaid, math, alerts,
admonitions and HTML/SVG keep the existing preview rendering path. Runtime assets
are bundled offline, sharing Markdown-it, Mermaid, DOMPurify, KaTeX CSS and fonts
with the read-only renderer.

```sh
npm ci --prefix dist/markdown-editor
npm run build --prefix dist/markdown-editor
node dist/tests/markdown_live_editor.cjs
```

The checked-in package lock pins dependencies. Build writes `live-editor.js`,
`live-editor.css` and bundled license notices under
`macos/Resources/MarkdownPreview`. No runtime CDN or font service is used.

`renderMarkdown(text, options)` creates/updates the live editor. Matching native
acknowledgements do not reset selection or history. `getMarkdown()` synchronously
returns the current source, including the last transaction. Document changes
send `{type: "edit", text, baseText}` through `markdownPreview`; `focus` is sent
on focus entry. `ready` is emitted only after this API is installed.
`renderMarkdownReadonly` remains available for read-only rendering and tests.
The internal `window.omgLiveEditorView()` hook returns a CodeMirror `EditorView`,
not a ProseMirror view.

Editing changes the same source document through CodeMirror transactions; it does
not parse and serialize a separate rich-text document. Opening, rendering, and
editing another block must preserve unrelated Markdown spelling and whitespace.
Native save and conflict detection continue to operate on that same document.

Complex widgets are views over source ranges, not independent editable documents.
Editing a complex block targets its source range. Reference link/image definitions
must remain in the source and participate in the shared rendering context even
when they have no visible block; splitting only by visible HTML blocks is not a
complete source-range model. Relative image sources remain unchanged in Markdown
and resolve through the existing local/SSH image scheme.

This is a source-based live preview, not a complete Typora-style rich-text editor.
Ordinary-line input and complex-block source editing have different interactions.
Table editing, reference definitions, nested block ranges, Chinese composition,
cross-block selection/copy, undo, and narrow-window layout require explicit
regression coverage; rendering a widget alone does not establish those editing
behaviors.
