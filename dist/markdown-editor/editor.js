import {EditorState, StateField, StateEffect, Compartment, Transaction} from '@codemirror/state';
import {EditorView, Decoration, WidgetType, ViewPlugin, keymap, drawSelection} from '@codemirror/view';
import {history, historyKeymap, defaultKeymap, indentWithTab, selectAll, undo, redo} from '@codemirror/commands';
import {markdown, markdownLanguage, markdownKeymap} from '@codemirror/lang-markdown';
import {syntaxTree, syntaxHighlighting, defaultHighlightStyle} from '@codemirror/language';
import {languages} from '@codemirror/language-data';
import {parseBlocks, renderFragment} from './model.js';
import {createBlockWidget} from './widgets.js';
import './editor.css';
import './widgets.css';

const content = document.getElementById('content');
const notify = message => window.webkit?.messageHandlers?.markdownPreview?.postMessage(message);
const activateSource = StateEffect.define();
const focusChanged = StateEffect.define();
const refreshAppearance = StateEffect.define();
const nativeUpdate = Transaction.userEvent.of('input.native');
const editable = new Compartment();
let view, options = {}, externalRevision = 0, composingUpdate;
const pendingEchoes = new Set();

function activate(editor, block) {
    if (editor.state.readOnly) return;
    const firstLine = editor.state.doc.lineAt(block.from);
    const position = block.kind === 'code' ? Math.min(firstLine.to + 1, block.to) : block.from;
    editor.dispatch({effects: activateSource.of({from: block.from, to: block.to}),
        selection: {anchor: position}, scrollIntoView: true});
    editor.focus();
}

function selected(state, from, to, focused) {
    return focused && state.selection.ranges.some(range => range.empty
        ? range.head >= from && range.head <= to : range.from < to && range.to > from);
}

function makeBlockState(state, blocks, active, focused) {
    const decorations = [], source = state.doc.toString();
    const referenceKey = blocks.filter(block => block.sourceOnly).map(block => block.source).join('\n');
    const hidden = [];
    for (const block of blocks) {
        if (block.sourceOnly) {
            if (!selected(state, block.from, block.to, focused)) {
                let end = block.to;
                while (end > block.from && /[\r\n]/.test(source[end - 1])) end--;
                if (end > block.from) {
                    decorations.push(Decoration.replace({block: true}).range(block.from, end));
                    hidden.push({from: block.from, to: end});
                }
            }
            continue;
        }
        if (block.kind === 'list') {
            for (const nested of block.codeBlocks || []) {
                const explicit = active && active.from <= nested.from && active.to >= nested.to;
                if (explicit || selected(state, nested.from, nested.to, focused)) continue;
                let end = nested.to;
                while (end > nested.from && /[\r\n]/.test(source[end - 1])) end--;
                if (end <= nested.from) continue;
                decorations.push(Decoration.replace({block: true, widget: createBlockWidget(nested,
                    {...options, referenceKey, activate})}).range(nested.from, end));
                hidden.push({from: nested.from, to: end});
            }
            continue;
        }
        if (['paragraph', 'heading'].includes(block.kind)) continue;
        const explicit = active && active.from <= block.from && active.to >= block.to;
        // A table's cell editor modifies source ranges without expanding the whole table.
        if (explicit || (block.kind !== 'table' && selected(state, block.from, block.to, focused))) continue;
        let end = block.to;
        while (end > block.from && /[\r\n]/.test(source[end - 1])) end--;
        if (end <= block.from) continue;
        decorations.push(Decoration.replace({block: true, widget: createBlockWidget(block,
            {...options, referenceKey, activate})}).range(block.from, end));
        hidden.push({from: block.from, to: end});
    }
    return {blocks, active, focused, hidden, referenceKey, decorations: Decoration.set(decorations, true)};
}

const blockState = StateField.define({
    create(state) { return makeBlockState(state, parseBlocks(state.doc.toString()), null, false); },
    update(value, transaction) {
        let active = value.active, focused = value.focused;
        if (active && transaction.docChanged) active = {
            from: transaction.changes.mapPos(active.from, -1), to: transaction.changes.mapPos(active.to, 1)
        };
        for (const effect of transaction.effects) {
            if (effect.is(activateSource)) active = effect.value;
            if (effect.is(focusChanged)) { focused = effect.value; if (!focused) active = null; }
        }
        if (active && !selected(transaction.state, active.from, active.to, true)) active = null;
        if (!transaction.docChanged && !transaction.selection && !transaction.effects.length) return value;
        const blocks = transaction.docChanged ? parseBlocks(transaction.state.doc.toString()) : value.blocks;
        return makeBlockState(transaction.state, blocks, active, focused);
    },
    provide: field => EditorView.decorations.from(field, value => value.decorations)
});

class Bullet extends WidgetType {
    constructor(value) { super(); this.value = value; }
    eq(other) { return this.value === other.value; }
    toDOM() { const span = document.createElement('span'); span.className = 'cm-md-bullet'; span.textContent = this.value; return span; }
}

class Checkbox extends WidgetType {
    constructor(position, checked) { super(); this.position = position; this.checked = checked; }
    eq(other) { return this.position === other.position && this.checked === other.checked; }
    toDOM(editor) {
        const input = document.createElement('input'); input.type = 'checkbox'; input.checked = this.checked;
        input.className = 'cm-md-checkbox'; input.disabled = editor.state.readOnly;
        input.addEventListener('mousedown', event => event.preventDefault());
        input.addEventListener('click', event => {
            event.stopPropagation();
            if (!editor.state.readOnly) editor.dispatch({changes: {from: this.position, to: this.position + 1,
                insert: this.checked ? ' ' : 'x'}, userEvent: 'input.task'});
        });
        return input;
    }
    ignoreEvent() { return true; }
}

class InlinePreview extends WidgetType {
    constructor(source, from, to, theme, referenceKey, baseURL) { super(); Object.assign(this, {source, from, to, theme, referenceKey, baseURL}); }
    eq(other) { return this.source === other.source && this.from === other.from && this.to === other.to && this.theme === other.theme && this.referenceKey === other.referenceKey && this.baseURL === other.baseURL; }
    toDOM(editor) {
        const span = document.createElement('span'), wrapper = document.createElement('div');
        span.className = 'cm-md-inline-preview';
        wrapper.innerHTML = renderFragment(this.source, {...options, documentText: editor.state.doc.toString()});
        const inner = wrapper.childElementCount === 1 && wrapper.firstElementChild.tagName === 'P' ? wrapper.firstElementChild : wrapper;
        span.append(...inner.childNodes);
        span.addEventListener('load', () => editor.requestMeasure(), true);
        span.addEventListener('click', () => {
            if (window.getSelection()?.toString()) return;
            editor.dispatch({selection: {anchor: this.from + 1}}); editor.focus();
        });
        return span;
    }
    ignoreEvent() { return true; }
}

function inlineDecorations(editor) {
    const state = editor.state, block = state.field(blockState), result = [], replaced = [];
    const documentText = state.doc.toString();
    const hidden = (from, to) => block.hidden.some(range => range.from <= from && range.to >= to);
    const addMark = (from, to, cls) => { if (from < to) result.push(Decoration.mark({class: cls}).range(from, to)); };
    const addLink = (from, to, source) => {
        const fragment = document.createElement('div');
        fragment.innerHTML = renderFragment(source, {...options, documentText});
        const href = fragment.querySelector('a[href]')?.getAttribute('href');
        if (!href) return false;
        result.push(Decoration.mark({tagName: 'a', class: 'cm-md-link', attributes: {href, 'data-md-link': 'true'}}).range(from, to));
        return true;
    };
    const hide = (from, to, widget) => {
        if (from >= to || state.sliceDoc(from, to).includes('\n') || replaced.some(range => range.from < to && range.to > from)) return;
        result.push(Decoration.replace(widget ? {widget} : {}).range(from, to)); replaced.push({from, to});
    };
    const cursorInside = (from, to) => selected(state, from, to, block.focused);
    const seen = new Set();
    for (const visible of editor.visibleRanges) {
        for (let position = state.doc.lineAt(visible.from).from; position <= visible.to;) {
            const line = state.doc.lineAt(position);
            if (!seen.has(line.number) && !hidden(line.from, line.to)) {
                seen.add(line.number);
                const fenced = block.blocks.some(b =>
                    (b.kind === 'code' || (b.codeBlocks || []).some(code => code.kind === 'code')) &&
                    (b.kind === 'code' ? b.from <= line.from && b.to > line.from
                        : b.codeBlocks.some(code => code.from <= line.from && code.to > line.from)));
                if (fenced) {
                    result.push(Decoration.line({class: 'cm-md-code-line'}).range(line.from));
                } else {
                    const heading = /^(#{1,6})[ \t]+/.exec(line.text);
                    if (heading) {
                        result.push(Decoration.line({class: `cm-md-h${heading[1].length}`}).range(line.from));
                        if (!cursorInside(line.from, line.from + heading[0].length - 1)) hide(line.from, line.from + heading[0].length);
                    }
                    if (!line.text.length) result.push(Decoration.line({class: 'cm-md-empty'}).range(line.from));
                    const task = /^(\s*)(?:[-+*]|\d+[.)])\s+\[([ xX])\]\s/.exec(line.text);
                    const bullet = /^(\s*)([-+*]|\d+[.)])\s+/.exec(line.text);
                    if (task) {
                        const from = line.from + task[1].length, to = line.from + task[0].length;
                        if (!cursorInside(from, to - 1)) hide(from, to,
                            new Checkbox(line.from + task[0].indexOf('[') + 1, task[2] !== ' '));
                    } else if (bullet) {
                        const from = line.from + bullet[1].length, to = from + bullet[2].length;
                        if (!cursorInside(from, to)) hide(from, to, new Bullet(/^\d/.test(bullet[2]) ? bullet[2] : '•'));
                    }
                    const tree = syntaxTree(state);
                    for (const match of line.text.matchAll(/(?<!\\)\$(?!\$)([^$\n]+?)\$(?!\$)/g)) {
                        const from = line.from + match.index, to = from + match[0].length;
                        let node = tree.resolveInner(from, 1), inCode = false;
                        while (node) { if (/Code/.test(node.name)) inCode = true; node = node.parent; }
                        if (!inCode && !cursorInside(from, to)) hide(from, to, new InlinePreview(match[0], from, to, options.theme, block.referenceKey, options.baseURL));
                    }
                }
            }
            if (line.to >= state.doc.length) break;
            position = line.to + 1;
        }
        syntaxTree(state).iterate({from: visible.from, to: visible.to, enter(node) {
            if (hidden(node.from, node.to) || node.name === 'FencedCode' || node.name === 'CodeBlock') return false;
            const source = state.sliceDoc(node.from, node.to);
            if (node.name === 'StrongEmphasis') addMark(node.from, node.to, 'cm-md-strong');
            if (node.name === 'Emphasis') addMark(node.from, node.to, 'cm-md-em');
            if (node.name === 'Strikethrough') addMark(node.from, node.to, 'cm-md-strike');
            if (node.name === 'InlineCode') addMark(node.from, node.to, 'cm-md-inline-code');
            if (['EmphasisMark', 'CodeMark', 'StrikethroughMark'].includes(node.name) && !cursorInside(node.from, node.to)) hide(node.from, node.to);
            if (node.name === 'URL' && node.node.parent?.name !== 'Link') addLink(node.from, node.to, source);
            if (node.name === 'Link') {
                if (!addLink(node.from, node.to, source)) return false;
                if (!cursorInside(node.from, node.to)) {
                    const delimiter = source.indexOf(']('), reference = source.indexOf('][');
                    const endLabel = delimiter >= 0 ? delimiter : reference;
                    if (endLabel >= 0) { hide(node.from, node.from + 1); hide(node.from + endLabel, node.to); }
                    else if (source.startsWith('[') && source.endsWith(']')) { hide(node.from, node.from + 1); hide(node.to - 1, node.to); }
                }
            }
            if (node.name === 'Image' && !cursorInside(node.from, node.to)) {
                hide(node.from, node.to, new InlinePreview(source, node.from, node.to, options.theme, block.referenceKey, options.baseURL));
                return false;
            }
        }});
    }
    return {decorations: Decoration.set(result, true),
        atomic: Decoration.set(result.filter(range => range.from < range.to && range.value.point), true)};
}

const inlineView = ViewPlugin.fromClass(class {
    constructor(editor) { Object.assign(this, inlineDecorations(editor)); this.tree = syntaxTree(editor.state); }
    update(update) {
        if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged ||
            update.transactions.some(tr => tr.effects.length) || syntaxTree(update.state) !== this.tree) {
            Object.assign(this, inlineDecorations(update.view)); this.tree = syntaxTree(update.state);
        }
    }
}, {decorations: plugin => plugin.decorations});

function acknowledge(text) {
    if (!pendingEchoes.has(text)) return;
    for (const echo of pendingEchoes) { pendingEchoes.delete(echo); if (echo === text) break; }
}

function applyAppearance(next) {
    options = next;
    document.documentElement.dataset.theme = next.theme === 'dark' ? 'dark' : 'light';
    for (const key of ['foreground', 'background']) if (next[key] && CSS.supports('color', next[key]))
        document.documentElement.style.setProperty('--' + key, next[key]);
    document.getElementById('highlight-theme').href = next.theme === 'dark' ? 'github-dark.min.css' : 'github.min.css';
}

function create(text) {
    content.replaceChildren();
    view = new EditorView({parent: content, doc: text, extensions: [
        markdown({base: markdownLanguage, codeLanguages: languages}), history(), drawSelection(),
        syntaxHighlighting(defaultHighlightStyle),
        keymap.of([...markdownKeymap, ...historyKeymap, ...defaultKeymap, indentWithTab]),
        editable.of([EditorState.readOnly.of(options.editable === false), EditorView.editable.of(options.editable !== false)]),
        EditorView.lineWrapping, blockState, inlineView,
        EditorView.atomicRanges.of(editor => editor.plugin(inlineView)?.atomic || Decoration.none),
        EditorView.domEventHandlers({
            click(event) {
                const anchor = event.target.closest?.('a[data-md-link]');
                if (!anchor) return false;
                event.preventDefault();
                if (event.metaKey || event.ctrlKey) {
                    const target = document.createElement('a'); target.href = anchor.href;
                    document.body.appendChild(target); target.click(); target.remove();
                }
                return true;
            },
            focus() { notify({type: 'focus'}); queueMicrotask(() => view?.dispatch({effects: focusChanged.of(true)})); },
            blur() { queueMicrotask(() => view?.dispatch({effects: focusChanged.of(false)})); },
            compositionend() { if (composingUpdate) { const next = composingUpdate; composingUpdate = null; setTimeout(() => window.renderMarkdown(next.text, next.options), 0); } }
        }),
        EditorView.updateListener.of(update => {
            if (!update.docChanged || update.transactions.every(tr => tr.isUserEvent('input.native'))) return;
            const text = update.state.doc.toString(), baseText = update.startState.doc.toString();
            pendingEchoes.add(text);
            if (pendingEchoes.size > 16) pendingEchoes.delete(pendingEchoes.values().next().value);
            notify({type: 'edit', text, baseText});
        })
    ]});
    window.omgLiveEditor = view;
    window.omgLiveEditorView = () => view;
}

window.getMarkdown = () => {
    return view?.state.doc.toString() ?? '';
};
window.getSelectedMarkdownText = () => {
    const selectedText = window.getSelection()?.toString();
    if (selectedText) return selectedText;
    return view?.state.selection.ranges.map(range => view.state.sliceDoc(range.from, range.to)).join('\n') ?? '';
};
window.selectAllMarkdown = () => { if (view) { view.focus(); selectAll(view); } };
window.undoMarkdown = () => view && undo(view);
window.redoMarkdown = () => view && redo(view);
window.destroyMarkdown = () => { const previous = view; view = null; previous?.destroy(); };
window.scrollMarkdownTo = position => {
    if (!view) return;
    position = Math.max(0, Math.min(position, view.state.doc.length));
    view.dispatch({effects: EditorView.scrollIntoView(position, {y: 'start'})});
    requestAnimationFrame(() => {
        if (!view) return;
        const node = view.domAtPos(position).node;
        (node.nodeType === 1 ? node : node.parentElement)?.scrollIntoView({block: 'start'});
    });
};
window.renderMarkdown = async (text, next = {}) => {
    text = String(text);
    const previousOptions = options;
    applyAppearance(next);
    if (!view) create(text);
    else {
        const effects = [];
        if (previousOptions.editable !== next.editable) effects.push(editable.reconfigure([
            EditorState.readOnly.of(next.editable === false), EditorView.editable.of(next.editable !== false)
        ]));
        if (JSON.stringify(previousOptions) !== JSON.stringify(next)) effects.push(refreshAppearance.of(++externalRevision));
        const current = view.state.doc.toString();
        if (text === current || pendingEchoes.has(text)) {
            acknowledge(text);
            if (effects.length) view.dispatch({effects});
        } else if (view.composing) {
            composingUpdate = {text, options: next};
        } else {
            pendingEchoes.clear();
            view.dispatch({changes: {from: 0, to: view.state.doc.length, insert: text},
                selection: {anchor: Math.min(view.state.selection.main.head, text.length)},
                effects: [...effects, activateSource.of(null)],
                annotations: [nativeUpdate, Transaction.addToHistory.of(false)]});
        }
    }
    notify({type: 'rendered'});
};
window.addEventListener('pagehide', window.destroyMarkdown);
notify({type: 'ready'});
