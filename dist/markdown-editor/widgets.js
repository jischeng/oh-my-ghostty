import { WidgetType } from '@codemirror/view';
import { isolateHistory, undo, redo } from '@codemirror/commands';
import { renderFragment } from './model.js';

let diagramID = 0;
let diagramQueue = Promise.resolve();

// Keep existing escaped pipes intact, and never introduce a new table row.
export function serializeTableCell(value) {
  return String(value).replace(/\r\n?/g, '\n').replace(/\n/g, '<br>').replace(/(\\*)\|/g,
    (match, slashes) => slashes.length % 2 ? match : `${slashes}\\|`);
}

function insertPlainText(text) {
  const selection = window.getSelection();
  if (!selection?.rangeCount) return;
  const range = selection.getRangeAt(0);
  range.deleteContents();
  const node = document.createTextNode(text);
  range.insertNode(node);
  range.setStartAfter(node);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
}

class BlockWidget extends WidgetType {
  constructor(block, options) {
    super();
    this.block = block;
    this.options = { ...options };
    // A reused widget must not retain a full document snapshot from its birth.
    delete this.options.documentText;
  }

  eq(other) {
    return this.block.from === other.block.from && this.block.to === other.block.to &&
      this.block.source === other.block.source && this.block.kind === other.block.kind &&
      this.options.theme === other.options.theme &&
      this.options.referenceKey === other.options.referenceKey &&
      this.options.baseURL === other.options.baseURL &&
      this.options.editable === other.options.editable &&
      this.options.language === other.options.language && this.options.lang === other.options.lang &&
      this.options.imageURLs === other.options.imageURLs;
  }

  toDOM(view) {
    const root = document.createElement('div');
    root.omgWidget = this;
    root.className = `omg-block-widget omg-block-${this.block.kind}`;
    root.dataset.sourceFrom = String(this.block.from);
    root.innerHTML = renderFragment(this.block.source, { ...this.options, documentText: view.state.doc.toString() });
    root.addEventListener('load', () => view.requestMeasure(), true);
    root.addEventListener('error', () => view.requestMeasure(), true);
    const activate = () => root.omgWidget.options.activate?.(view, root.omgWidget.block);
    root.addEventListener('click', event => {
      if (event.target.closest('a,button,input,summary,[contenteditable="true"]')) return;
      if (window.getSelection()?.toString()) return;
      activate();
    });
    if (this.block.kind === 'table') this.installTableEditing(root, view);
    const sourceButton = document.createElement('button');
    sourceButton.className = 'omg-block-source-button';
    sourceButton.type = 'button';
    sourceButton.textContent = this.options.language === 'en' ? 'Edit source' : '编辑源码';
    sourceButton.addEventListener('click', activate);
    root.appendChild(sourceButton);
    this.renderDiagrams(root, view);
    return root;
  }

  updateDOM(root, view) {
    const edit = root.omgCellEdit;
    if (!edit || this.block.kind !== 'table') return false;
    if (edit.expectedDoc !== view.state.doc) {
      edit.stop();
      return false;
    }
    root.omgWidget = this;
    root.dataset.sourceFrom = String(this.block.from);
    return true;
  }

  destroy(root) { root.omgCellEdit?.stop(); }

  installTableEditing(root, view) {
    const sourceRows = this.block.rows?.filter(row => !row.delimiter) || [];
    root.querySelectorAll('table tr').forEach((row, rowIndex) => {
      const renderedCells = row.querySelectorAll('th,td');
      // Malformed tables may render a different column count. Offer source
      // editing instead of writing a displayed cell into the wrong source range.
      if (renderedCells.length !== sourceRows[rowIndex]?.cells.length) return;
      renderedCells.forEach((cell, column) => {
        if (!sourceRows[rowIndex]?.cells[column]) return;
        cell.tabIndex = 0;
        cell.classList.add('omg-editable-cell');
        const begin = () => {
          if (cell.isContentEditable || view.state.readOnly) return;
          const widget = root.omgWidget;
          const source = widget.block.rows.filter(row => !row.delimiter)[rowIndex]?.cells[column];
          if (!source || view.state.doc.sliceString(widget.block.from, widget.block.to) !== widget.block.source) return;
          cell.textContent = source.source;
          cell.contentEditable = 'true';
          cell.spellcheck = false;
          cell.setAttribute('aria-label', this.options.language === 'en' ? 'Table cell Markdown' : '表格单元格 Markdown');
          const edit = { expectedDoc: view.state.doc, from: source.from, to: source.to, changed: false, stopped: false };
          root.omgCellEdit = edit;
          const stop = edit.stop = () => {
            edit.stopped = true;
            root.omgCellEdit = null;
            cell.contentEditable = 'false';
            cell.removeEventListener('blur', blur);
            cell.removeEventListener('keydown', keydown);
            cell.removeEventListener('paste', paste);
            cell.removeEventListener('beforeinput', beforeinput);
            cell.removeEventListener('input', input);
          };
          const publish = (replacement, cancel = false) => {
            if (edit.stopped) return;
            if (edit.expectedDoc !== view.state.doc || view.state.readOnly) { stop(); return; }
            if (view.state.doc.sliceString(edit.from, edit.to) === replacement) return;
            const transaction = view.state.update({
              changes: { from: edit.from, to: edit.to, insert: replacement },
              annotations: cancel ? isolateHistory.of('full') : !edit.changed ? isolateHistory.of('before') : [],
              userEvent: 'input.type',
            });
            // Install the expected version before dispatch: updateDOM runs
            // synchronously and retains this exact cell, selection and IME DOM.
            edit.expectedDoc = transaction.newDoc;
            edit.to = edit.from + replacement.length;
            edit.changed = true;
            view.dispatch(transaction);
            view.requestMeasure();
          };
          const input = () => publish(serializeTableCell(cell.innerText));
          const finish = (cancel = false) => {
            if (edit.stopped) return;
            if (cancel) publish(source.source, true);
            else input();
            if (edit.stopped) return;
            stop();
            const current = root.omgWidget;
            const rendered = document.createElement('div');
            rendered.innerHTML = renderFragment(current.block.source, { ...current.options, documentText: view.state.doc.toString() });
            const restored = rendered.querySelectorAll('table tr')[rowIndex]?.querySelectorAll('th,td')[column];
            if (restored) cell.innerHTML = restored.innerHTML;
            if (edit.changed) view.dispatch({ annotations: isolateHistory.of('after') });
            view.requestMeasure();
          };
          const blur = () => finish();
          const keydown = event => {
            if (event.isComposing) return;
            if (event.key === 'Escape') {
              event.preventDefault(); finish(true); view.focus();
            } else if (event.key === 'Enter' && !event.shiftKey) {
              event.preventDefault(); finish(); view.focus();
            } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
              event.preventDefault(); finish(); view.focus();
              (event.shiftKey ? redo : undo)(view);
            }
          };
          const paste = event => {
            event.preventDefault();
            insertPlainText(event.clipboardData?.getData('text/plain') || '');
            input();
          };
          const beforeinput = event => {
            if (event.inputType === 'insertParagraph' || event.inputType === 'insertLineBreak') {
              event.preventDefault(); insertPlainText('\n'); input();
            }
          };
          cell.addEventListener('blur', blur);
          cell.addEventListener('keydown', keydown);
          cell.addEventListener('paste', paste);
          cell.addEventListener('beforeinput', beforeinput);
          cell.addEventListener('input', input);
          cell.focus();
          const selection = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(cell);
          selection.removeAllRanges();
          selection.addRange(range);
        };
        cell.addEventListener('click', event => {
          event.stopPropagation();
          if (!window.getSelection()?.toString()) begin();
        });
        cell.addEventListener('keydown', event => {
          if (!cell.isContentEditable && event.key === 'Enter') { event.preventDefault(); begin(); }
        });
      });
    });
  }

  renderDiagrams(root, view) {
    const codes = [...root.querySelectorAll('pre > code.language-mermaid')];
    if (!codes.length) return;
    const current = () => root.isConnected &&
      view.state.doc.sliceString(this.block.from, this.block.to) === this.block.source;
    // Mermaid has global theme/config state, so serialize just its renderer.
    diagramQueue = diagramQueue.catch(() => {}).then(async () => {
      if (!current()) return;
      const mermaid = await (window.omgMarkdownModel?.ensureMermaid || window.omgEnsureMermaid)();
      if (!current()) return;
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict',
        theme: this.options.theme === 'dark' ? 'dark' : 'default', suppressErrorRendering: true,
        maxTextSize: 50000, htmlLabels: false, flowchart: { htmlLabels: false } });
      for (const code of codes) {
        if (!current()) return;
        try {
          const result = await mermaid.render(`omg-live-diagram-${++diagramID}`, code.textContent);
          if (!current()) return;
          const figure = document.createElement('figure');
          figure.className = 'mermaid';
          figure.innerHTML = window.DOMPurify.sanitize(result.svg, {
            USE_PROFILES: { svg: true, svgFilters: true },
            FORBID_TAGS: ['foreignObject', 'script'], FORBID_ATTR: ['onload'],
          });
          code.parentElement.replaceWith(figure);
          view.requestMeasure();
        } catch (error) {
          if (!current()) return;
          const message = document.createElement('p');
          message.className = 'render-error';
          message.textContent = `Mermaid: ${String(error.message || error).slice(0, 300)}`;
          code.parentElement.after(message);
          view.requestMeasure();
        }
      }
    }).catch(() => { if (current()) view.requestMeasure(); });
  }

  // Keep native selection, copying, links and temporary cell editing in the DOM.
  ignoreEvent() { return true; }
}

export function createBlockWidget(block, options = {}) {
  return new BlockWidget(block, options);
}
