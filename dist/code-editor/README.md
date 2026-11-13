# OMG Code Editor & Diff Bundle (`dist/code-editor`)

Lightweight, 100% offline Web Editor & Diff bundle for Oh My Ghostty (`macos/Resources/CodeEditor/`), inspired by `JetBrains/thinkrail`:

- **Surgical Monaco Editor (`monaco-editor`)**: imports `editor/editor.api.js` and cherry-picked editing, diffing, search, folding, multi-cursor, sticky scroll, quick outline, hover, suggest, and reference widgets — excluding heavy TypeScript/CSS/HTML/JSON compiler workers and 80 Monarch regex grammars.
- **`@pierre/highlights` WASM/SIMD Syntax Highlighting**: incremental per-model `LiveTokenizer` (`packed24` token records -> Monaco `TokensProvider`) with ThinkRail safety caps (`MAX_LINE_LENGTH = 20_000`, `MAX_MODEL_LINES = 300_000`) and 150+ built-in grammars (including `.ghostty`, `.conf`, `.toml`, `.zig`, `.swift`, `.rs`, `.py`, `.ts`, `.tsx`, `.js`, `.json`, `.yaml`, `.md`, `.sh`, `.c`, `.cpp`, `.go`, `.html`, `.css`, `.xml`, `.sql`, and graceful `plaintext` fallback).
- **Transparent Glass Backdrop**: `#00000000` editor/gutter/minimap theme surfaces so OMG's native `EditorBackdrop` vibrancy shines through.
- **Native Swift Bridge**: `window.omgEditor` inbound API and `window.webkit.messageHandlers.codeEditor.postMessage(...)` outbound events for multi-model tab pooling, external File-Watcher `preserveView` reloads, Git gutter bars, inline/side-by-side diffs, Ask-Agent (`⌘⇧L` / `⌘⇧I`), and LSP intelligence (`completion`, `hover`, `definition` / `⌘+Click`, `references`, `documentSymbol` / `⌘⇧O`).

## Commands

```sh
npm run build --prefix dist/code-editor
npm test --prefix dist/code-editor
```
