# Code Editor dependencies

All editor, diff, icon font, worker, and WebAssembly syntax highlighting assets in
this directory are bundled for 100% offline use via OMG's `omg-editor://bundle/`
scheme handler. Runtime code never fetches remote scripts, stylesheets, workers,
or fonts.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| monaco-editor (surgical core + Codicons) | 0.57.0 | MIT | https://github.com/microsoft/monaco-editor |
| @pierre/highlights (LiveTokenizer WASM/SIMD) | 0.5.1 | Apache-2.0 | https://github.com/pierrecomputer/pierre |

Original copyright, license, and upstream notice files are retained in `licenses/`.
