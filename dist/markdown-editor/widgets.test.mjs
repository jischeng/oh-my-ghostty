import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { EditorState, StateField } from '@codemirror/state';
import { EditorView, Decoration } from '@codemirror/view';
import { history, undo } from '@codemirror/commands';
import { createBlockWidget, serializeTableCell } from './widgets.js';

const dom = new JSDOM('<body></body>', { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.MutationObserver = window.MutationObserver;
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.Window = window.Window;
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0 });
Object.defineProperties(window.HTMLElement.prototype, {
  isContentEditable: { get() { return this.contentEditable === 'true'; } },
  innerText: { get() { return this.textContent; }, set(value) { this.textContent = value; } },
});
window.omgMarkdownModel = {
  renderFragment: source => `<table><thead><tr><th>Name</th></tr></thead><tbody><tr><td>${source.split('\n')[2].slice(1, -1).trim()}</td></tr></tbody></table>`,
};

assert.equal(serializeTableCell('a|b\nc'), 'a\\|b<br>c');
assert.equal(serializeTableCell('a\\|b'), 'a\\|b');
assert.equal(serializeTableCell('a\\\\|b'), 'a\\\\\\|b');

let previousView;
function fixture() {
  previousView?.destroy();
  window.getSelection().removeAllRanges();
  const text = '| Name |\n| --- |\n| one |';
  const decorate = state => {
    const current = state.doc.toString();
    const from = current.indexOf('| Name |');
    const source = current.slice(from);
    const start = from + source.indexOf('\n', source.indexOf('\n') + 1) + 3;
    const to = current.length - 2;
    const block = { kind: 'table', from, to: current.length, source, rows: [
      { cells: [{ from: from + 2, to: from + 6, source: 'Name' }] },
      { delimiter: true, cells: [] },
      { cells: [{ from: start, to, source: current.slice(start, to) }] },
    ] };
    return Decoration.set([Decoration.replace({ widget: createBlockWidget(block), block: true }).range(from, current.length)]);
  };
  const decorations = StateField.define({ create: decorate, update: (_, tr) => decorate(tr.state), provide: field => EditorView.decorations.from(field) });
  document.body.replaceChildren();
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: text, extensions: [history(), decorations] }) });
  previousView = view;
  const cell = view.dom.querySelector('td');
  cell.click();
  return { text, view, cell };
}

{
  const { text, view, cell } = fixture();
  cell.textContent = 'a|b\nc';
  cell.dispatchEvent(new window.Event('input', { bubbles: true }));
  assert.equal(view.state.doc.toString(), text.replace('one', 'a\\|b<br>c'), 'input writes through before blur or save');
  assert.equal(view.dom.querySelector('td'), cell, 'self transaction preserves the editing DOM');
  cell.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  assert.equal(view.state.doc.toString(), text.replace('one', 'a\\|b<br>c'));
  assert.equal(undo(view), true);
  assert.equal(view.state.doc.toString(), text, 'cell edit is one undo step');
}
{
  const { text, view, cell } = fixture();
  cell.textContent = 'cancelled';
  cell.dispatchEvent(new window.Event('input', { bubbles: true }));
  cell.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  assert.equal(view.state.doc.toString(), text);
}
{
  const { text, view, cell } = fixture();
  cell.textContent = 'stale';
  view.dispatch({ changes: { from: 0, insert: 'new document\n' } });
  cell.dispatchEvent(new window.Event('blur'));
  assert.equal(view.state.doc.toString(), 'new document\n' + text, 'stale cell must not overwrite a newer document');
}
{
  const { text, view, cell } = fixture();
  cell.textContent = '中文';
  cell.dispatchEvent(new window.Event('input', { bubbles: true }));
  view.dispatch({ selection: { anchor: 0 } });
  cell.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true }));
  assert.equal(view.state.doc.toString(), text.replace('one', '中文'), 'IME input writes through without finishing editing');
  assert.equal(cell.isContentEditable, true);
  cell.dispatchEvent(new window.Event('blur'));
  assert.equal(view.state.doc.toString(), text.replace('one', '中文'), 'selection-only transaction retains the editing document');
}
console.log('Markdown widgets: escaping, precise cell changes, undo, cancel and stale edits passed');
{
  const { text, view, cell } = fixture();
  for (const value of ['a', 'ab', 'abc']) {
    cell.textContent = value;
    window.getSelection().collapse(cell.firstChild, value.length);
    cell.dispatchEvent(new window.Event('input', { bubbles: true }));
    assert.equal(view.dom.querySelector('td'), cell);
    assert.equal(window.getSelection().anchorNode, cell.firstChild);
    assert.equal(window.getSelection().anchorOffset, value.length);
    assert.equal(view.state.doc.toString(), text.replace('one', value));
  }
  cell.dispatchEvent(new window.Event('blur'));
  undo(view);
  assert.equal(view.state.doc.toString(), text, 'continuous table typing is one undo group');
}
previousView.destroy();
previousView = null;

async function diagramFixture() {
  const source = '```mermaid\ngraph LR; A-->B\n```';
  let resolveRender;
  window.omgMarkdownModel.renderFragment = () => '<pre><code class="language-mermaid">graph LR; A--&gt;B</code></pre>';
  window.omgMarkdownModel.ensureMermaid = async () => ({
    initialize() {},
    render: () => new Promise(resolve => { resolveRender = resolve; }),
  });
  window.DOMPurify = { sanitize: value => value };
  let measurements = 0;
  const view = { state: EditorState.create({ doc: source }), requestMeasure() { measurements++; } };
  const root = createBlockWidget({ from: 0, to: source.length, kind: 'code', source }).toDOM(view);
  document.body.replaceChildren(root);
  await new Promise(setImmediate);
  assert.equal(typeof resolveRender, 'function');
  return { root, view, finish: async () => {
    resolveRender({ svg: '<svg><text>diagram</text></svg>' });
    await new Promise(setImmediate);
    return measurements;
  } };
}
{
  const { root, view, finish } = await diagramFixture();
  view.state = view.state.update({ changes: { from: view.state.doc.length, insert: '\nother text' } }).state;
  assert.ok(await finish() > 0);
  assert.ok(root.querySelector('figure svg'), 'unrelated typing must not cancel a reused diagram widget');
}
{
  const { root, finish } = await diagramFixture();
  root.remove();
  await finish();
  assert.equal(root.querySelector('figure'), null, 'detached widgets must not accept old asynchronous results');
}
console.log('Markdown widgets: asynchronous Mermaid reuse and stale-result rejection passed');
