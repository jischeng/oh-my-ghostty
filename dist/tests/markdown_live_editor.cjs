// npm ci --prefix dist/markdown-editor && npm run build --prefix dist/markdown-editor
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {JSDOM} = require('../markdown-editor/node_modules/jsdom');
const resources = path.resolve(__dirname, '../../macos/Resources/MarkdownPreview');
const template = fs.readFileSync(path.join(resources, 'template.html'), 'utf8');
const dom = new JSDOM(template, {
    url: 'https://preview.invalid/template.html', runScripts: 'outside-only', pretendToBeVisual: true
});
const w = dom.window, messages = [];
w.CSS = {supports: () => true};
w.matchMedia = () => ({matches: false, addEventListener() {}, removeEventListener() {}});
w.ResizeObserver = class {observe() {} unobserve() {} disconnect() {}};
w.Range.prototype.getBoundingClientRect = () => ({top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0});
w.Range.prototype.getClientRects = () => [];
w.webkit = {messageHandlers: {markdownPreview: {postMessage: message => messages.push(message)}}};
w.mermaid = {initialize(options) {assert.equal(options.securityLevel, 'strict');}, async render() {
    return {svg: '<svg xmlns="http://www.w3.org/2000/svg"><text>diagram</text></svg>'};
}};
// Exercise the shipped entry point: manually injecting the editor concealed
// regressions where template.html stopped loading it altogether.
for (const script of w.document.querySelectorAll('script[src]')) {
    const file = script.getAttribute('src');
    vm.runInContext(fs.readFileSync(path.join(resources, file), 'utf8'), dom.getInternalVMContext(), {filename: file});
}
assert.equal(messages.filter(message => message.type === 'ready').length, 1, 'one readiness notification after the editing API is installed');
assert.equal(typeof w.getMarkdown, 'function', 'the shipped template must load the live editor');
assert.ok(w.document.querySelector('link[href="live-editor.css"]'), 'the shipped template must load editor styles');
const delay = () => new Promise(resolve => setTimeout(resolve, 30));
(async () => {
    const original = '# Existing  heading\n\nA **bold** sentence.\n\n[ref]: https://example.com\n';
    await w.renderMarkdown(original);
    const view = w.omgLiveEditorView();
    assert.equal(w.getMarkdown(), original, 'opening cannot normalize Markdown');
    assert.equal(messages.filter(message => message.type === 'edit').length, 0);
    assert.ok(w.document.querySelector('.cm-md-h1'), 'headings retain preview typography');
    const at = original.indexOf('sentence');
    view.dispatch({changes: {from: at, to: at + 8, insert: 'paragraph'}, userEvent: 'input'});
    const edited = original.slice(0, at) + 'paragraph' + original.slice(at + 8);
    assert.equal(w.getMarkdown(), edited, 'only the edited source range changes');
    assert.equal(messages.at(-1).baseText, original);
    const selection = view.state.selection.main.head;
    await w.renderMarkdown(edited);
    assert.equal(view.state.selection.main.head, selection);
    w.undoMarkdown(); assert.equal(w.getMarkdown(), original, 'one shared text undo history');
    w.redoMarkdown(); assert.equal(w.getMarkdown(), edited);

    await w.renderMarkdown('');
    view.dispatch({changes: {from: 0, insert: '# '}, selection: {anchor: 2}, userEvent: 'input'});
    assert.equal(w.getMarkdown(), '# ');
    assert.ok(w.document.querySelector('.cm-md-h1'), '# plus space formats a heading without removing source');
    view.dispatch({changes: {from: 2, insert: 'Hello 中文'}, userEvent: 'input'});
    assert.equal(w.getMarkdown(), '# Hello 中文');
    await w.renderMarkdown('~~strike~~ and **bold**');
    assert.ok(w.document.querySelector('.cm-md-strike'), 'GFM strikethrough remains formatted');
    assert.equal(w.getMarkdown(), '~~strike~~ and **bold**');
    await w.renderMarkdown('[link][ref]\n\n[ref]: https://example.com\n');
    assert.equal(w.document.querySelector('.cm-md-link')?.getAttribute('href'), 'https://example.com/');

    await w.renderMarkdown('| A | B |\n| - | - |\n| one | two |\n\n- [ ] task\n');
    await delay();
    const cell = w.document.querySelector('td');
    assert.ok(cell, 'table uses the original HTML renderer');
    w.getSelection().removeAllRanges(); cell.click();
    cell.textContent = 'changed'; Object.defineProperty(cell, 'innerText', {value: 'changed', configurable: true});
    cell.dispatchEvent(new w.KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
    assert.ok(w.getMarkdown().includes('| changed | two |'));
    const checkbox = w.document.querySelector('.cm-md-checkbox');
    assert.ok(checkbox); checkbox.click();
    assert.ok(w.getMarkdown().includes('- [x] task'));

    const sample = fs.readFileSync(path.join(__dirname, 'fixtures/markdown-preview.md'), 'utf8');
    view.dispatch({selection: {anchor: 0, head: view.state.doc.length}});
    await w.renderMarkdown(sample + '\n> [!TIP]\n> Preserved alert\n');
    assert.ok(view.state.selection.main.empty, 'a replaced host document cannot select and expand every source block');
    view.contentDOM.blur(); await delay();
    assert.ok(w.document.querySelector('.cm-editor .markdown-alert-tip'));
    assert.equal(w.getMarkdown(), sample + '\n> [!TIP]\n> Preserved alert\n');
    await w.renderMarkdown('readonly', {editable: false});
    assert.equal(view.state.readOnly, true);
    w.destroyMarkdown();
    console.log('PASS: CodeMirror source preservation, live heading, native echoes, undo, table ranges, tasks, rich blocks, readonly');
    w.close();
})().catch(error => {console.error(error); w.destroyMarkdown?.(); w.close(); process.exitCode = 1;});
