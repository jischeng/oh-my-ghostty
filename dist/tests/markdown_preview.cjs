// Install test-only dependencies outside the checkout:
//   npm install --prefix /tmp/omg-markdown-test --no-audit --no-fund jsdom
// Run from the checkout:
//   NODE_PATH=/tmp/omg-markdown-test/node_modules node dist/tests/markdown_preview.cjs [sample.md]
// DOM integration test; native WKWebView tests cover actual Mermaid SVG and CSP.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const resources = path.resolve(__dirname, '../../macos/Resources/MarkdownPreview');
const vm = require('node:vm');
const {JSDOM} = require('jsdom');
const dom = new JSDOM('<!doctype html><link id="highlight-theme"><main id="content"></main>', {
    url: 'https://preview.invalid/template.html', runScripts: 'outside-only'
});
const w = dom.window;
w.CSS = {supports: () => true};
let diagrams = 0;
w.mermaid = {initialize(options) { assert.equal(options.securityLevel, 'strict'); }, async render(id, source) {
    if (source.includes('BROKEN')) throw new Error('invalid syntax');
    diagrams++;
    return {svg: '<svg xmlns="http://www.w3.org/2000/svg"><text>Diagram</text><script>evil()</script></svg>'};
}};
for (const file of ['markdown-it.min.js', 'markdown-it-task-lists.min.js', 'markdownItAnchor.umd.js', 'highlight.min.js', 'katex.min.js', 'texmath.min.js', 'purify.min.js', 'render.js']) {
    vm.runInContext(fs.readFileSync(path.join(resources, file), 'utf8'), dom.getInternalVMContext(), {filename: file});
}
const sample = fs.readFileSync(process.argv[2] || path.join(__dirname, 'fixtures/markdown-preview.md'), 'utf8');
const fixture = sample + '\n' + [
    '| A | B |', '| - | - |', '| one | two |', '',
    '- [x] Done', '  - [ ] Nested', '',
    '> [!Notes]', '> First paragraph', '>', '> Second paragraph', '',
    '> [!Tips] Useful hint', '> Body', '',
    '> [!IMPORTANT]', '> Important', '', '> [!WARNING]', '> Warning', '', '> [!CAUTION]', '> Caution', '',
    '!!! tip "Admonition"', '    Indented body', '',
    '::: warning', 'Container body', ':::', '',
    '```python', 'def answer(): return 42', '```', '',
    '```mermaid', 'BROKEN', '```', '', '```mermaid', 'graph TD; A-->B', '```', '',
    '$x^2$ and \\(y^2\\)', '', '$$', '\\frac{1}{2}', '$$', '',
    '![relative](./images/a.svg)', '![absolute](/images/b.svg)', '',
    '<img src="https://example.com/a.svg" onerror="window.bad = 1">',
    '<script>window.bad = 1</script><iframe src="https://example.com"></iframe>',
    '[bad](javascript:alert%281%29)', '', '---', '',
    '1. Parent', '   - Child', '     - Grandchild'
].join('\n');
(async () => {
    await w.renderMarkdown(fixture, {baseURL: 'omg-markdown-image://document/project/docs/', theme: 'dark'});
    const root = w.document.getElementById('content');
    const one = selector => assert.ok(root.querySelector(selector), selector);
    ['table td', '.hljs-keyword', '.task-list-item .task-list-item', '.katex', '.katex-display', '.mermaid svg', '.render-error', 'hr', 'ol ul ul'].forEach(one);
    for (const kind of ['note', 'tip', 'important', 'warning', 'caution']) one('.markdown-alert-' + kind);
    assert.equal(root.querySelector('.markdown-alert-note').querySelectorAll('p').length, 3);
    assert.equal(root.querySelectorAll('.markdown-alert-tip').length, 2);
    assert.equal(root.querySelectorAll('.markdown-alert-warning').length, 2);
    assert.equal(root.querySelector('img[alt="relative"]').src, 'omg-markdown-image://document/project/docs/images/a.svg');
    assert.equal(root.querySelector('img[alt="absolute"]').src, 'omg-markdown-image://document/images/b.svg');
    assert.equal(root.querySelector('script,iframe,[onerror],a[href^="javascript:"]'), null);
    assert.ok([...root.querySelectorAll('input')].every(input => input.disabled));
    assert.ok(diagrams >= 1);
    await Promise.all([w.renderMarkdown('stale'), w.renderMarkdown('newest')]);
    assert.equal(root.textContent.trim(), 'newest');
    console.log('PASS: GFM, alerts/admonitions, highlight, math, image URLs, sanitization, diagram errors, latest-render ordering');
    w.close();
})().catch(error => { console.error(error); process.exitCode = 1; w.close(); });
