// NODE_PATH=/tmp/omg-markdown-test/node_modules node dist/markdown-editor/model-test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {JSDOM} = require('jsdom');
const resources = path.resolve(__dirname, '../../macos/Resources/MarkdownPreview');
const dom = new JSDOM('<!doctype html><main id="content"></main>', {url: 'https://preview.invalid/', runScripts: 'outside-only'});
for (const file of ['markdown-it.min.js', 'markdown-it-task-lists.min.js', 'markdownItAnchor.umd.js', 'highlight.min.js', 'katex.min.js', 'texmath.min.js', 'purify.min.js', 'render.js']) {
    vm.runInContext(fs.readFileSync(path.join(resources, file), 'utf8'), dom.getInternalVMContext());
}
const {parseBlocks, renderFragment} = dom.window.omgMarkdownModel;
const text = '# 标题 😀\r\n\r\nParagraph [ref][target].\r\n\r\n| A | B |\r\n| - | - |\r\n| x\\|y | `a\\|b` |\r\n| 😀 | ``x`y`` |\r\n\r\n> [!Tips]\r\n> Alert\r\n\r\n!!! warning\r\n    Content\r\n\r\n```mermaid\r\ngraph TD; A-->B\r\n```\r\n\r\n$$\r\nx^2\r\n$$\r\n\r\n![svg](image.svg)\r\n\r\n---\r\n\r\n[target]: https://example.com\r\n';
const blocks = parseBlocks(text);
for (const block of blocks) assert.equal(block.source, text.slice(block.from, block.to));
for (const kind of ['heading', 'paragraph', 'table', 'callout', 'code', 'math', 'image', 'hr']) {
    assert.ok(blocks.some(block => block.kind === kind), 'block kind: ' + kind);
}
assert.equal(blocks.filter(block => block.kind === 'callout').length, 2);
assert.equal(blocks.find(block => block.kind === 'code').language, 'mermaid');
const table = blocks.find(block => block.kind === 'table');
assert.equal(table.rows.length, 4);
assert.equal(table.cells.length, 6);
assert.equal(table.cells[2].source, 'x\\|y');
assert.equal(table.cells[3].source, '`a\\|b`');
for (const cell of table.cells) assert.equal(text.slice(cell.from, cell.to), cell.source);
const cell = table.cells[4];
const updated = text.slice(0, cell.from) + 'changed' + text.slice(cell.to);
assert.equal(updated, text.replace('| 😀 |', '| changed |'));
const unusual = parseBlocks('| A | B |\n| - | - |\n| `x|y` | z |\n').find(block => block.kind === 'table');
assert.equal(unusual.cells[2].source, '`x|y`');
assert.equal(unusual.cells[3].source, 'z');
assert.match(renderFragment('[ref][target]', {documentText: text}), /href="https:\/\/example.com\/?"/);
assert.ok(!renderFragment('<img src="x" onerror="evil()"><script>evil()</script>').includes('onerror'));
assert.match(renderFragment('![svg](image.svg)', {baseURL: 'omg-markdown-image://document/project/'}), /omg-markdown-image:\/\/document\/project\/image.svg/);
assert.ok(blocks.some(block => block.sourceOnly && block.source.includes('[target]:')));
const all = parseBlocks('- one\n  - nested\n\n> quote\n\n<div>HTML</div>\n');
assert.deepEqual(Array.from(all, block => block.kind), ['list', 'quote', 'html']);
const nestedCode = parseBlocks('- explanation\n\n  ```sh\n  zig build -Demit-lib-vt -Dtarget=wasm32-freestanding \\\n    -Doptimize=ReleaseSmall -Dvt-features=-all,+render-state\n  ```\n');
const listWithCode = nestedCode.find(block => block.kind === 'list');
assert.equal(listWithCode.codeBlocks.length, 1, 'nested fenced code is exposed as a source range');
assert.equal(listWithCode.codeBlocks[0].language, 'sh');
assert.match(renderFragment(listWithCode.codeBlocks[0].source), /<pre class="hljs"><code>/);
console.log('PASS: exact UTF-16/CRLF block and table-cell ranges, escaped pipes/code spans, reference environment, all block kinds, sanitization');
dom.window.close();
