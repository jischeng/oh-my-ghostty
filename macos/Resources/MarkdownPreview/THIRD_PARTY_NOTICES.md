# Markdown Preview dependencies

All renderer dependencies and KaTeX WOFF2 fonts are bundled for offline use.
The third-party files below were reused from Markd's Web/js directory; no Markd
application renderer or style code was copied. Their original copyright and
license notices are retained in the files and in `licenses/`.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| markdown-it | 14.1.1 | MIT | https://github.com/markdown-it/markdown-it |
| markdown-it-task-lists | 2.1.0 | ISC | https://github.com/revin/markdown-it-task-lists |
| markdown-it-anchor | 9.2.0 | Unlicense | https://github.com/valeriangalliat/markdown-it-anchor |
| markdown-it-texmath | 1.0.0 | MIT | https://github.com/goessner/markdown-it-texmath |
| Highlight.js (including GitHub themes) | 11.11.1 | BSD-3-Clause | https://github.com/highlightjs/highlight.js |
| KaTeX (including fonts) | 0.16.45 | MIT | https://github.com/KaTeX/KaTeX |
| Mermaid | 11.14.0 | MIT | https://github.com/mermaid-js/mermaid |
| DOMPurify | 3.4.15 | Apache-2.0 OR MPL-2.0 | https://github.com/cure53/DOMPurify |

DOMPurify was refreshed from the pinned npm distribution rather than reusing
Markd's older copy. Mermaid's bundled dependency notices are retained at the end
of mermaid.min.js. Runtime code never downloads scripts, styles, or fonts.
Remote images load only when the Markdown document references them.
