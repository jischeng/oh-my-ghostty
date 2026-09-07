import {Crepe} from '@milkdown/crepe';
import {editorViewCtx, parserCtx, serializerCtx} from '@milkdown/kit/core';
import {$node, $remark, $prose, $view} from '@milkdown/kit/utils';
import {Plugin} from '@milkdown/kit/prose/state';
import {imageSchema, linkSchema} from '@milkdown/kit/preset/commonmark';
import {languages} from '@codemirror/language-data';
import {nextTick} from 'vue';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/frame.css';
import './editor.css';

let editor, currentText = '', currentOptions = {}, queue = Promise.resolve(), renderVersion = 0;
let suppress = false, previousDoc, diagramID = 0;
let flushPreservedEdit = null;
let diagramQueue = Promise.resolve();
const pendingEchoes = new Set();
const notify = message => window.webkit?.messageHandlers?.markdownPreview?.postMessage(message);
const content = document.getElementById('content');
const imageSources = new WeakMap();
const linkSources = new WeakMap();
function resolvedLink(source) {
    if (source.startsWith('#')) return source;
    try {
        const resolved = new URL(source, currentOptions.baseURL || document.baseURI);
        return /^(https?:|mailto:|file:|omg-markdown-image:)$/i.test(resolved.protocol) ? resolved.href : '';
    } catch (_) { return ''; }
}
const sourceLinks = linkSchema.extendSchema(previous => ctx => ({
    ...previous(ctx),
    toDOM(mark) {
        const link = document.createElement('a'); link.setAttribute('href', resolvedLink(mark.attrs.href));
        if (mark.attrs.title) link.title = mark.attrs.title;
        linkSources.set(link, mark.attrs.href);
        return link;
    },
    parseDOM: [{tag: 'a[href]', getAttrs: link => ({href: linkSources.get(link) || link.getAttribute('href'), title: link.getAttribute('title')})}]
}));

// Keep unsupported HTML and alert/container syntax as lossless Markdown atoms.
// Remark/Milkdown own every other parse/serialize operation; no DOM-to-Markdown.
const preserved = inline => $node(inline ? 'omg_raw_inline' : 'omg_raw_block', () => ({
    group: inline ? 'inline' : 'block', inline, atom: true, selectable: true,
    attrs: {source: {default: ''}},
    parseDOM: [],
    toDOM: node => {
        const element = document.createElement(inline ? 'span' : 'div');
        element.className = 'omg-preserved-markdown';
        element.contentEditable = 'false';
        element.innerHTML = window.omgMarkdownFragment(node.attrs.source);
        resolveImages(element);
        return element;
    },
    parseMarkdown: {match: node => node.type === (inline ? 'omgRawInline' : 'omgRawBlock'),
        runner: (state, node, type) => state.addNode(type, {source: node.value})},
    toMarkdown: {match: node => node.type.name === (inline ? 'omg_raw_inline' : 'omg_raw_block'),
        runner: (state, node) => state.addNode('html', undefined, node.attrs.source)}
}));

const rawBlock = preserved(false), rawInline = preserved(true);
const preservedView = schema => $view(schema, () => (initialNode, view, getPos) => {
    let node = initialNode, input = null, composing = false;
    const dom = document.createElement(node.isInline ? 'span' : 'div');
    dom.className = 'omg-preserved-markdown'; dom.contentEditable = 'false';
    function draw() {
        dom.innerHTML = window.omgMarkdownFragment(node.attrs.source);
        dom.title = currentOptions.language === 'en' ? 'Double-click to edit this Markdown block' : '双击编辑此 Markdown 内容块';
        resolveImages(dom);
    }
    function finish(commit) {
        if (!input || composing) return;
        const source = input.value;
        input = null;
        flushPreservedEdit = null;
        if (commit && source !== node.attrs.source && typeof getPos() === 'number') {
            view.dispatch(view.state.tr.setNodeMarkup(getPos(), null, {source}));
        } else draw();
        view.focus();
    }
    dom.addEventListener('dblclick', event => {
        if (input || currentOptions.editable === false || event.target.closest('a')) return;
        event.preventDefault(); event.stopPropagation();
        input = document.createElement('textarea'); input.value = node.attrs.source;
        flushPreservedEdit = () => finish(true);
        input.className = 'omg-preserved-source'; input.setAttribute('aria-label', 'Markdown');
        input.rows = Math.min(24, Math.max(3, input.value.split('\n').length));
        const controls = document.createElement('span'); controls.className = 'omg-preserved-controls';
        for (const [english, chinese, commit] of [['Apply', '应用', true], ['Cancel', '取消', false]]) {
            const button = document.createElement('button'); button.type = 'button';
            button.textContent = currentOptions.language === 'en' ? english : chinese;
            button.addEventListener('click', () => finish(commit)); controls.appendChild(button);
        }
        input.addEventListener('compositionstart', () => { composing = true; });
        input.addEventListener('compositionend', () => { composing = false; });
        input.addEventListener('keydown', event => {
            if (event.isComposing || composing) return;
            if (event.key === 'Escape' || (event.key === 'Enter' && event.metaKey)) {
                event.preventDefault(); finish(event.key !== 'Escape');
            }
        });
        input.addEventListener('blur', event => {
            if (dom.contains(event.relatedTarget)) return;
            finish(true);
        });
        dom.replaceChildren(input, controls); input.focus();
    });
    draw();
    return {dom, stopEvent: () => !!input, ignoreMutation: () => true,
        update(next) { if (next.type !== node.type) return false; node = next; if (!input) draw(); return true; }};
});

const preserveSyntax = $remark('omg-preserve-syntax', () => function () {
    return (tree, file) => {
        const source = String(file.value || '');
        const visit = parent => {
            if (!parent.children) return;
            const result = [];
            for (let index = 0; index < parent.children.length; index++) {
                let node = parent.children[index];
                const raw = source.slice(node.position?.start.offset, node.position?.end.offset);
                const marker = /^(!!!|:::)\s*(?:notes?|tips?|important|warning|caution)\b/i.exec(raw);
                if (parent.type === 'root' && marker) {
                    const start = node.position.start.offset;
                    let end = node.position.end.offset;
                    if (marker[1] === ':::') {
                        const close = /^:::\s*$/m.exec(source.slice(start + raw.indexOf('\n') + 1));
                        if (close) end = start + raw.indexOf('\n') + 1 + close.index + close[0].length;
                    } else {
                        const lines = source.slice(start).split(/(?<=\n)/);
                        end = start + lines[0].length;
                        for (const line of lines.slice(1)) {
                            if (line.trim() && !/^(?: {4}|\t)/.test(line)) break;
                            end += line.length;
                        }
                    }
                    while (index + 1 < parent.children.length && parent.children[index + 1].position.start.offset < end) index++;
                    node = {type: 'omgRawBlock', value: source.slice(start, end)};
                } else if (node.type === 'html' || (node.type === 'blockquote' && /^>\s*\[!(?:notes?|tips?|important|warning|caution)\]/i.test(raw))
                    || (node.type === 'paragraph' && /\\\[|\\\(/.test(raw))) {
                    node = {type: parent.type === 'paragraph' ? 'omgRawInline' : 'omgRawBlock', value: raw || node.value};
                } else visit(node);
                result.push(node);
            }
            parent.children = result;
        };
        visit(tree);
    };
});

function resolveImages(root) {
    (root.matches?.('img') ? [root] : root.querySelectorAll('img')).forEach(image => {
        const source = imageSources.get(image) || image.getAttribute('src');
        if (!source) return;
        imageSources.set(image, source);
        try {
            const resolved = currentOptions.imageURLs?.[source] || new URL(source, currentOptions.baseURL || document.baseURI).href;
            if (/^(https?:|data:image\/|blob:|omg-markdown-image:)/i.test(resolved)) image.src = resolved;
            else image.removeAttribute('src');
        } catch (_) { image.removeAttribute('src'); }
    });
    root.querySelectorAll('a[href]').forEach(link => {
        if (linkSources.has(link)) return;
        const source = link.getAttribute('href');
        if (source.startsWith('#')) return;
        try {
            const resolved = new URL(source, currentOptions.baseURL || document.baseURI);
            if (/^(https?:|mailto:|file:|omg-markdown-image:)$/i.test(resolved.protocol)) link.href = resolved.href;
            else link.removeAttribute('href');
        } catch (_) { link.removeAttribute('href'); }
    });
}

// Resolve local/SSH URLs only in the image view, never in document attributes.
// Ignore DOM resource changes so ProseMirror cannot write the private URL back.
const imageView = $view(imageSchema, () => initialNode => {
    const dom = document.createElement('img');
    function update(node) {
        if (node.type !== initialNode.type) return false;
        dom.setAttribute('src', node.attrs.src); imageSources.set(dom, node.attrs.src);
        dom.alt = node.attrs.alt || ''; dom.title = node.attrs.title || '';
        resolveImages(dom);
        return true;
    }
    update(initialNode);
    return {dom, update, ignoreMutation: () => true};
});

function appearance(options) {
    currentOptions = options;
    document.documentElement.dataset.theme = options.theme === 'dark' ? 'dark' : 'light';
    for (const key of ['background', 'foreground']) {
        if (options[key] && CSS.supports('color', options[key])) document.documentElement.style.setProperty('--' + key, options[key]);
    }
}

function documentChanged(ctx, doc) {
    if (suppress || previousDoc?.eq(doc)) return;
    previousDoc = doc;
    const text = ctx.get(serializerCtx)(doc);
    if (text === currentText) return;
    const baseText = currentText;
    currentText = text;
    pendingEchoes.add(text);
    // Bound outstanding acknowledgement history when typing continuously.
    if (pendingEchoes.size > 100) pendingEchoes.delete(pendingEchoes.values().next().value);
    notify({type: 'edit', text, baseText});
    resolveImages(content);
}

async function create(markdown) {
    content.replaceChildren();
    editor = new Crepe({root: content, defaultValue: markdown,
        features: {[Crepe.Feature.ImageBlock]: false, [Crepe.Feature.BlockEdit]: false, [Crepe.Feature.LinkTooltip]: false},
        featureConfigs: {
            [Crepe.Feature.Placeholder]: {text: currentOptions.language === 'en' ? 'Type Markdown…' : '输入 Markdown…'},
            [Crepe.Feature.CodeMirror]: {languages, previewOnlyByDefault: true,
                renderPreview(language, value) {
                    if (language.toLowerCase() !== 'mermaid') return null;
                    const id = 'omg-live-diagram-' + (++diagramID);
                    diagramQueue = diagramQueue.catch(() => {}).then(async () => {
                        const mermaid = await window.omgEnsureMermaid();
                        mermaid.initialize({startOnLoad: false, securityLevel: 'strict',
                            theme: currentOptions.theme === 'dark' ? 'dark' : 'default',
                            suppressErrorRendering: true, maxTextSize: 50000,
                            htmlLabels: false, flowchart: {htmlLabels: false},
                            secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'suppressErrorRendering', 'htmlLabels']});
                        const result = await mermaid.render(id + '-svg', value);
                        await nextTick();
                        // Crepe sanitizes/clones HTMLElement previews. Resolve a
                        // unique placeholder after completion; stale placeholders
                        // disappear when the block is edited or replaced.
                        const preview = document.getElementById(id);
                        if (preview) preview.innerHTML = window.DOMPurify.sanitize(result.svg, {USE_PROFILES: {svg: true, svgFilters: true}, FORBID_TAGS: ['foreignObject', 'script']});
                    }).catch(error => {
                        const preview = document.getElementById(id);
                        if (preview) preview.textContent = String(error.message || error);
                    });
                    return '<div id="' + id + '" class="mermaid"></div>';
                }
            }
        }
    });
    editor.editor.use(preserveSyntax).use(rawBlock).use(rawInline).use(preservedView(rawBlock)).use(preservedView(rawInline)).use(imageView).use(sourceLinks);
    editor.editor.use($prose(ctx => new Plugin({view: () => ({update(view, previous) {
        if (!previous.doc.eq(view.state.doc)) documentChanged(ctx, view.state.doc);
    }})})));
    suppress = true;
    await editor.create();
    editor.setReadonly(currentOptions.editable === false);
    previousDoc = editor.editor.action(ctx => ctx.get(editorViewCtx).state.doc);
    suppress = false;
    resolveImages(content);
    // Make the real editor observable for native tests and focused edit commands.
    window.omgLiveEditor = editor;
    window.omgLiveEditorView = () => editor.editor.action(ctx => ctx.get(editorViewCtx));
}

content.addEventListener('focusin', () => notify({type: 'focus'}));
window.getMarkdown = () => { flushPreservedEdit?.(); return currentText; };

window.renderMarkdown = function (markdown, options = {}) {
    markdown = String(markdown);
    const version = ++renderVersion;
    queue = queue.catch(() => {}).then(async () => {
        if (version !== renderVersion) return;
        appearance(options);
        if (!editor) { currentText = markdown; await create(markdown); }
        else {
            editor.setReadonly(options.editable === false);
            if (markdown === currentText || pendingEchoes.has(markdown)) {
                // Acknowledgements are cumulative: release all older snapshots
                // rather than retaining many copies of a large document.
                if (pendingEchoes.has(markdown)) {
                    for (const pending of pendingEchoes) {
                        pendingEchoes.delete(pending);
                        if (pending === markdown) break;
                    }
                }
            } else {
                const view = editor.editor.action(ctx => ctx.get(editorViewCtx));
                if (view.composing) {
                    setTimeout(() => window.renderMarkdown(markdown, options), 50);
                    return;
                }
                suppress = true;
                editor.editor.action(ctx => {
                    const doc = ctx.get(parserCtx)(markdown);
                    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, doc.content).setMeta('addToHistory', false));
                    previousDoc = view.state.doc;
                });
                currentText = markdown; pendingEchoes.clear(); suppress = false;
            }
            resolveImages(content);
        }
        notify({type: 'rendered'});
    }).catch(async error => {
        suppress = false;
        if (editor) { await editor.destroy().catch(() => {}); editor = null; }
        await window.renderMarkdownReadonly(markdown, options);
        notify({type: 'editorError', message: String(error.message || error)});
    });
    return queue;
};
notify({type: 'ready'});
