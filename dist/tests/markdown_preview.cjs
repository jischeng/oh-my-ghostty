// npm ci --prefix dist/markdown-editor
// node dist/tests/markdown_preview.cjs [sample.md]
// DOM integration test; native WKWebView tests cover actual Mermaid SVG and CSP.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const resources = path.resolve(__dirname, '../../macos/Resources/MarkdownPreview');
const vm = require('node:vm');
const {JSDOM} = require('../markdown-editor/node_modules/jsdom');
const template = fs.readFileSync(path.join(resources, 'template.html'), 'utf8');
const dom = new JSDOM(template, {
    url: 'https://preview.invalid/template.html', runScripts: 'outside-only', pretendToBeVisual: true
});
const w = dom.window;
const messages = [];
w.CSS = {supports: () => true};
w.webkit = {messageHandlers: {markdownPreview: {postMessage: message => messages.push(message)}}};
let diagrams = 0;
w.mermaid = {initialize(options) { assert.equal(options.securityLevel, 'strict'); }, async render(id, source) {
    if (source.includes('BROKEN')) throw new Error('invalid syntax');
    diagrams++;
    return {svg: '<svg xmlns="http://www.w3.org/2000/svg"><text>Diagram</text><script>evil()</script></svg>'};
}};
for (const script of w.document.querySelectorAll('script[src]')) {
    const file = script.getAttribute('src');
    vm.runInContext(fs.readFileSync(path.join(resources, file), 'utf8'), dom.getInternalVMContext(), {filename: file});
}
assert.equal(messages.filter(m => m.type === 'ready').length, 1, 'shipped template emits ready once');
assert.equal(w.document.querySelector('script[src="live-editor.js"]'), null, 'CodeMirror live-editor is no longer loaded');

const sample = fs.readFileSync(process.argv[2] || path.join(__dirname, 'fixtures/markdown-preview.md'), 'utf8');
const fixture = sample + '\n' + [
    '| 场景编号 | 场景名称与代表策略 | 核心代码入口 | 输入源与核心算子特征 |',
    '| :--- | :--- | :--- | :--- |',
    '| **S0** | 元数据 / Schema 探测 | [lance_metadata.py](file:///home/user/repo/lance_metadata.py#L35-L101) | 直调 LakeForge HTTP + 本地 `sqlglot`，已不走 Spark |',
    '',
    '- [x] Done', '  - [ ] Nested', '',
    '> [!Notes]', '> First paragraph', '>', '> Second paragraph', '',
    '> [!Tips] Useful hint', '> Body', '',
    '> [!IMPORTANT]', '> Important', '', '> [!WARNING]', '> Warning', '', '> [!CAUTION]', '> Caution', '',
    '!!! tip "Admonition"', '    Indented body', '',
    '::: warning', 'Container body', ':::', '',
    '```python', 'def answer(): return 42', '```', '',
    '````carousel',
    '### Slide One',
    '```js',
    'const s = 1;',
    '```',
    '<!-- slide -->',
    '### Slide Two',
    '| Col | Val |',
    '| - | - |',
    '| K | V |',
    '````',
    '',
    '```mermaid', 'BROKEN', '```', '', '```mermaid', 'graph TD; A-->B', '```', '',
    '$x^2$ and \\(y^2\\)', '', '$$', '\\frac{1}{2}', '$$', '',
    '![relative](./images/a.svg)', '![absolute](/images/b.svg)', '![fileimg](file:///Users/demo/pic.png)', '',
    '<img src="https://example.com/a.svg" onerror="window.bad = 1">',
    '<script>window.bad = 1</script><iframe src="https://example.com"></iframe>',
    '[bad](javascript:alert%281%29)', '', '---', '',
    '1. Parent', '   - Child', '     - Grandchild'
].join('\n');
(async () => {
    await w.renderMarkdown(fixture, {baseURL: 'omg-markdown-image://document/project/docs/', theme: 'dark'});
    const root = w.document.getElementById('content');
    const one = selector => assert.ok(root.querySelector(selector), selector);
    [
        '.omg-table-wrap table td', '.omg-col-compact', '.omg-col-medium', '.omg-col-wide',
        'a.omg-file-link .omg-file-line', '.omg-code-card .omg-code-copy', '.hljs-keyword',
        '.omg-carousel .omg-carousel-slide.active',
        '.task-list-item .task-list-item', '.katex', '.katex-display', '.mermaid svg', '.render-error', 'hr', 'ol ul ul'
    ].forEach(one);
    for (const kind of ['note', 'tip', 'important', 'warning', 'caution']) one('.markdown-alert-' + kind);
    assert.equal(root.querySelector('.markdown-alert-note').querySelectorAll('p').length, 3);
    assert.equal(root.querySelectorAll('.markdown-alert-tip').length, 2);
    assert.equal(root.querySelectorAll('.markdown-alert-warning').length, 2);
    assert.equal(root.querySelector('img[alt="relative"]').src, 'omg-markdown-image://document/project/docs/images/a.svg');
    assert.equal(root.querySelector('img[alt="absolute"]').src, 'omg-markdown-image://document/images/b.svg');
    assert.equal(root.querySelector('img[alt="fileimg"]').src, 'omg-markdown-image://document/Users/demo/pic.png');
    assert.equal(root.querySelector('script,iframe,[onerror],a[href^="javascript:"]'), null);
    assert.ok([...root.querySelectorAll('input')].every(input => input.disabled));
    assert.ok(diagrams >= 1);

    // File capsule click posts openLink without mutating source
    const fileLink = root.querySelector('a.omg-file-link');
    assert.equal(fileLink.querySelector('.omg-file-line').textContent, ':L35-L101');
    fileLink.click();
    assert.equal(messages.at(-1).type, 'openLink');
    assert.equal(messages.at(-1).href, 'file:///home/user/repo/lance_metadata.py#L35-L101');

    // Code copy button posts copy message with exact fence content
    const pythonCard = [...root.querySelectorAll('.omg-code-card')].findLast(c => c.querySelector('.omg-code-lang')?.textContent === 'python');
    assert.ok(pythonCard);
    pythonCard.querySelector('.omg-code-copy').click();
    assert.equal(messages.at(-1).type, 'copy');
    assert.equal(messages.at(-1).text, 'def answer(): return 42\n');

    // Carousel navigation switches active slide
    const carousel = root.querySelector('.omg-carousel');
    const slides = carousel.querySelectorAll('.omg-carousel-slide');
    assert.equal(slides.length, 2);
    assert.ok(slides[0].classList.contains('active'));
    const nextBtn = carousel.querySelectorAll('.omg-carousel-btn')[1];
    nextBtn.click();
    assert.ok(slides[1].classList.contains('active'));
    assert.ok(!slides[0].classList.contains('active'));

    // Editable task list checkbox toggles exact character without normalizing surrounding Markdown
    const rawTasks = '# Heading  with  two spaces\n\n- [ ] first task\n  - [x] second task\n';
    await w.renderMarkdown(rawTasks, {editable: true, theme: 'dark'});
    const checkboxes = root.querySelectorAll('input.task-list-item-checkbox');
    assert.equal(checkboxes.length, 2);
    assert.equal(checkboxes[0].disabled, false);
    checkboxes[0].checked = true;
    checkboxes[0].dispatchEvent(new w.Event('change', {bubbles: true}));
    assert.equal(messages.at(-1).type, 'edit');
    assert.equal(messages.at(-1).baseText, rawTasks);
    assert.equal(messages.at(-1).text, '# Heading  with  two spaces\n\n- [x] first task\n  - [x] second task\n');

    // Codex <proposed_plan>, Codex path:line capsules, and OMP bare \begin{align}...\end{align}
    const agentExtensions = [
        '<proposed_plan>',
        '# Codex Plan Heading',
        '',
        '- [ ] Plan step referencing [app.py](/home/user/repo/app.py:12), [My Report.md](</home/user/My Project/My Report.md:3>), and [rel.py](rel.py:9)',
        '',
        '\\begin{align}',
        'y &= x^2 + 1',
        '\\end{align}',
        '</proposed_plan>',
        ''
    ].join('\n');
    await w.renderMarkdown(agentExtensions, {editable: true, baseURL: 'omg-markdown-image://document/home/user/repo/', theme: 'dark'});
    assert.equal(root.querySelector('h1')?.textContent, 'Codex Plan Heading');
    const codexLinks = root.querySelectorAll('a.omg-file-link');
    assert.equal(codexLinks.length, 3);
    assert.equal(codexLinks[0].querySelector('.omg-file-line')?.textContent, ':L12');
    assert.equal(codexLinks[1].querySelector('.omg-file-line')?.textContent, ':L3');
    assert.equal(codexLinks[2].querySelector('.omg-file-line')?.textContent, ':L9');
    codexLinks[2].click();
    assert.equal(messages.at(-1).type, 'openLink');
    assert.equal(messages.at(-1).href, 'rel.py:9');
    assert.ok(root.querySelector('.katex-display'), 'bare \\begin{align} renders via KaTeX');
    const planCheckbox = root.querySelector('input.task-list-item-checkbox');
    planCheckbox.checked = true;
    planCheckbox.dispatchEvent(new w.Event('change', {bubbles: true}));
    assert.equal(messages.at(-1).type, 'edit');
    assert.ok(messages.at(-1).text.includes('<proposed_plan>\n# Codex Plan Heading\n\n- [x] Plan step'));

    await Promise.all([w.renderMarkdown('stale'), w.renderMarkdown('newest')]);
    assert.equal(root.textContent.trim(), 'newest');
    console.log('PASS: GFM, smart tables, file:// capsules, code copy, carousel, task toggle, alerts/admonitions, highlight, math, image URLs, sanitization, diagram errors, latest-render ordering');
    w.close();
})().catch(error => { console.error(error); process.exitCode = 1; w.close(); });
