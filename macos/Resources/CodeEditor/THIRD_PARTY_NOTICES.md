# Code Editor dependencies

All editor, diff, icon font, worker, and WebAssembly syntax highlighting assets in
this directory are bundled for 100% offline use via OMG's local custom URL scheme
handlers (`omg-code://app/` / `omg-editor://bundle/`). Runtime code never fetches
remote scripts, stylesheets, workers, grammars, or fonts.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| monaco-editor (surgical core + Codicons) | 0.57.0 | MIT | https://github.com/microsoft/monaco-editor |
| @pierre/diffs (vanilla FileDiff + patch parser) | 1.6.4 | Apache-2.0 | https://github.com/pierrecomputer/pierre |
| @pierre/highlights (LiveTokenizer WASM/SIMD) | 0.5.1 | Apache-2.0 | https://github.com/pierrecomputer/pierre |
| @pierre/theming (Zed CSS-variable theme resolver) | 1.0.2 | Apache-2.0 | https://github.com/pierrecomputer/pierre |
| diff (jsdiff unified patch engine) | 9.0.0 | BSD-3-Clause | https://github.com/kpdecker/jsdiff |
| hast-util-to-html & syntax-tree/unified HAST helpers | 9.0.5 | MIT | https://github.com/syntax-tree/hast-util-to-html |

Original copyright, license, and upstream notice files are retained in `licenses/`.
