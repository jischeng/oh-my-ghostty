// npm ci --prefix dist/markdown-editor && npm run build --prefix dist/markdown-editor
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {JSDOM} = require('../markdown-editor/node_modules/jsdom');
const resources = path.resolve(__dirname, '../../macos/Resources/MarkdownPreview');
const dom = new JSDOM('<!doctype html><link id="highlight-theme"><main id="content" class="markdown-body"></main>', {
    url: 'https://preview.invalid/template.html', runScripts: 'outside-only', pretendToBeVisual: true
});
const w = dom.window, messages = [];
w.CSS = {supports: () => true};
w.matchMedia = () => ({matches: false, addEventListener() {}, removeEventListener() {}});
w.ResizeObserver = class {observe() {} unobserve() {} disconnect() {}};
w.IntersectionObserver = class {
    constructor(callback) { this.callback = callback; }
    observe(target) { queueMicrotask(() => this.callback([{target, isIntersecting: true}])); }
    unobserve() {} disconnect() {}
};
w.Range.prototype.getBoundingClientRect = () => ({top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0});
w.Range.prototype.getClientRects = () => [];
w.webkit = {messageHandlers: {markdownPreview: {postMessage: message => messages.push(message)}}};
w.mermaid = {initialize(options) {
    assert.equal(options.htmlLabels, false);
    assert.equal(options.flowchart.htmlLabels, false);
    assert.ok(options.secure.includes('htmlLabels'));
}, async render() {return {svg: '<svg><text>Diagram</text></svg>'};}};
for (const file of ['markdown-it.min.js', 'markdown-it-task-lists.min.js', 'markdownItAnchor.umd.js', 'highlight.min.js', 'katex.min.js', 'texmath.min.js', 'purify.min.js', 'render.js', 'live-editor.js']) {
    vm.runInContext(fs.readFileSync(path.join(resources, file), 'utf8'), dom.getInternalVMContext(), {filename: file});
}
(async () => {
    const sample = fs.readFileSync(process.argv[2] || path.join(__dirname, 'fixtures/markdown-preview.md'), 'utf8');
    const original = '# Heading\n\nParagraph **bold**.\n\n- [ ] Task\n\n| a | b |\n| - | - |\n| x | y |\n';
    await w.renderMarkdown(original);
    assert.ok(w.omgLiveEditor, JSON.stringify(messages.filter(message => message.type === 'editorError')));
    const view = w.omgLiveEditorView();
    assert.equal(view.dom.contentEditable, undefined); // jsdom models contenteditable as an attribute.
    assert.equal(view.dom.getAttribute('contenteditable'), 'true');
    assert.ok(view.dom.querySelector('h1'));
    assert.ok(view.dom.querySelector('table'));
    assert.equal(messages.filter(message => message.type === 'edit').length, 0, 'opening must not normalize or dirty a file');
    view.dispatch(view.state.tr.insertText('New ', 1));
    let last = messages.filter(message => message.type === 'edit').at(-1);
    assert.equal(last.baseText, original);
    assert.match(last.text, /^# New Heading/);
    const afterFirst = last.text;
    view.dispatch(view.state.tr.insertText('More ', 1));
    last = messages.filter(message => message.type === 'edit').at(-1);
    assert.equal(last.baseText, afterFirst, 'each update chains from last sent Markdown');
    const selection = view.state.selection;
    await w.renderMarkdown(afterFirst, {theme: 'dark'});
    assert.equal(w.omgLiveEditorView(), view, 'old native acknowledgement must not rebuild editor');
    assert.ok(view.state.selection.eq(selection), 'acknowledgement preserves selection');
    assert.match(view.state.doc.firstChild.textContent, /^More New/);
    const taskLabel = view.dom.querySelector('.label-wrapper');
    assert.ok(taskLabel);
    taskLabel.dispatchEvent(new w.MouseEvent('pointerdown', {bubbles: true, cancelable: true}));
    assert.match(messages.filter(message => message.type === 'edit').at(-1).text, /\[x\] Task/);
    assert.equal(w.getMarkdown(), messages.filter(message => message.type === 'edit').at(-1).text);
    await w.renderMarkdown(w.getMarkdown());
    await w.renderMarkdown(last.text);
    assert.ok(!w.getMarkdown().includes('[x] Task'), 'cumulative acknowledgement releases older snapshots, allowing a later external revert');

    await w.renderMarkdown('');
    const empty = w.omgLiveEditorView();
    empty.dispatch(empty.state.tr.insertText('#', 1));
    const headingRule = empty.someProp('handleTextInput', handler => handler(empty, 2, 2, ' '));
    assert.equal(headingRule, true, 'Markdown # + space input rule is installed');
    assert.equal(empty.state.doc.firstChild.type.name, 'heading');
    empty.dispatch(empty.state.tr.insertText('标题', 1));
    assert.match(messages.filter(message => message.type === 'edit').at(-1).text, /^# 标题/);
    empty.dispatch(empty.state.tr.setSelection(empty.state.selection.constructor.create(empty.state.doc, 1, 3)));
    empty.focus();
    await w.renderMarkdown(sample, {theme: 'dark'});
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.ok(w.document.querySelector('.ProseMirror table'), 'empty → heading input → selected heading → sample keeps table');
    assert.ok(w.document.querySelector('.ProseMirror .katex'), 'selected heading → sample keeps math');
    assert.ok(w.document.querySelector('.ProseMirror .mermaid svg'), 'selected heading → sample renders Mermaid');

    const rich = '> [!Tips]\n> Preserve alert\n\n!!! warning\n    Preserve admonition\n\n<svg xmlns="http://www.w3.org/2000/svg"><text>SVG</text></svg>\n\nTail\n';
    await w.renderMarkdown(rich);
    assert.equal(messages.filter(message => message.type === 'editorError').length, 0);
    assert.ok(w.document.querySelector('.markdown-alert-tip'));
    assert.ok(w.document.querySelector('.markdown-alert-warning'));
    assert.ok(w.document.querySelector('.omg-preserved-markdown svg'));
    const alert = w.document.querySelector('.markdown-alert-tip');
    alert.dispatchEvent(new w.MouseEvent('dblclick', {bubbles: true, cancelable: true}));
    const input = w.document.querySelector('.omg-preserved-source');
    assert.ok(input);
    input.value = '> [!Tips]\n> Updated alert';
    input.dispatchEvent(new w.KeyboardEvent('keydown', {key: 'Enter', metaKey: true, bubbles: true, cancelable: true}));
    assert.ok(w.getMarkdown().includes('> Updated alert'));
    assert.equal(w.document.querySelector('.omg-preserved-source'), null);
    const richView = w.omgLiveEditorView();
    let tail;
    richView.state.doc.descendants((node, position) => {if (node.isText && node.text === 'Tail') tail = position;});
    assert.notEqual(tail, undefined);
    richView.dispatch(richView.state.tr.insertText('Edited ', tail));
    last = messages.filter(message => message.type === 'edit').at(-1);
    assert.ok(last.text.includes('> [!Tips]\n> Updated alert'));
    assert.ok(last.text.includes('!!! warning\n    Preserve admonition'));
    assert.ok(last.text.includes('<svg xmlns="http://www.w3.org/2000/svg"><text>SVG</text></svg>'));
    await w.renderMarkdown(last.text, {editable: false});
    assert.equal(richView.dom.getAttribute('contenteditable'), 'false');
    await w.renderMarkdown('![relative](images/example.svg)\n\n[relative link](docs/readme.md)\n\nTail', {baseURL: 'omg-markdown-image://document/project/'});
    const imageView = w.omgLiveEditorView();
    assert.equal(imageView.dom.querySelector('img').getAttribute('src'), 'omg-markdown-image://document/project/images/example.svg');
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.ok(w.getMarkdown().includes('](images/example.svg)'), 'loading a resource never rewrites its source URL');
    assert.ok(!w.getMarkdown().includes('omg-markdown-image:'));
    assert.equal(imageView.dom.querySelector('a').getAttribute('href'), 'omg-markdown-image://document/project/docs/readme.md');
    imageView.dispatch(imageView.state.tr.insertText('text ', 1));
    assert.ok(w.getMarkdown().includes('](docs/readme.md)'), 'editing text does not rewrite the original link target');
    await w.renderMarkdown(sample);
    assert.equal(messages.filter(message => message.type === 'editorError').length, 0);
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.ok(w.document.querySelector('.ProseMirror table'), 'sample table after dynamic replacement');
    assert.ok(w.document.querySelector('.ProseMirror .katex'), 'sample math after dynamic replacement');
    assert.ok(w.document.querySelector('.ProseMirror .mermaid svg'), 'sample diagram after dynamic replacement');
    await w.omgLiveEditor.destroy();
    console.log('PASS: live WYSIWYG, heading input rules, table, chained bridge edits, acknowledgement/selection stability, lossless rich blocks, readonly');
    w.close();
})().catch(error => {console.error(error); console.error(messages.filter(message => message.type === 'editorError')); process.exitCode = 1; w.close();});
