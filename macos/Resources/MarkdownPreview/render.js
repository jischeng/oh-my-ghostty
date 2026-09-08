/* OMG Markdown preview. Third-party engine licenses are in licenses/. */
(function () {
    'use strict';
    const kinds = { note: 'Note', notes: 'Note', tip: 'Tip', tips: 'Tip', important: 'Important', warning: 'Warning', caution: 'Caution' };
    const md = window.markdownit({
        html: true, linkify: true,
        highlight(code, language) {
            if (language === 'mermaid') return '';
            if (language && hljs.getLanguage(language)) {
                try { return '<pre class="hljs"><code>' + hljs.highlight(code, {language, ignoreIllegals: true}).value + '</code></pre>'; } catch (_) {}
            }
            return '<pre class="hljs"><code>' + md.utils.escapeHtml(code) + '</code></pre>';
        }
    });
    md.use(window.markdownitTaskLists, {enabled: false});
    md.use(window.markdownItAnchor);
    md.use(window.texmath, {engine: window.katex, delimiters: ['dollars', 'brackets'], katexOptions: {throwOnError: false, trust: false, strict: 'ignore', maxExpand: 1000}});

    // MkDocs !!! note (indented body) and ::: note containers share GitHub alert rendering.
    md.block.ruler.before('fence', 'admonition', function (state, start, end, silent) {
        const line = state.src.slice(state.bMarks[start] + state.tShift[start], state.eMarks[start]);
        const match = /^(!!!|:::)\s*(note|notes|tip|tips|important|warning|caution)(?:\s+(.+))?\s*$/i.exec(line);
        if (!match || state.sCount[start] - state.blkIndent >= 4) return false;
        if (silent) return true;
        let next = start + 1;
        while (next < end) {
            const text = state.src.slice(state.bMarks[next] + state.tShift[next], state.eMarks[next]);
            if (match[1] === ':::' ? /^:::\s*$/.test(text) : text.trim() && state.sCount[next] <= state.sCount[start]) break;
            next++;
        }
        let token = state.push('blockquote_open', 'blockquote', 1);
        token.map = [start, next + (match[1] === ':::' && next < end ? 1 : 0)];
        token = state.push('paragraph_open', 'p', 1);
        token = state.push('inline', '', 0);
        token.content = '[!' + match[2] + ']' + (match[3] ? ' ' + match[3].replace(/^"|"$/g, '') : ''); token.children = [];
        state.push('paragraph_close', 'p', -1);
        const body = state.getLines(start + 1, next, match[1] === '!!!' ? state.sCount[start] + 4 : state.blkIndent, true);
        const bodyTokens = [];
        state.md.block.parse(body, state.md, state.env, bodyTokens);
        for (const child of bodyTokens) {
            if (child.map) child.map = child.map.map(line => line + start + 1);
            state.tokens.push(child);
        }
        state.push('blockquote_close', 'blockquote', -1);
        state.line = next + (match[1] === ':::' && next < end ? 1 : 0);
        return true;
    });
    md.core.ruler.after('inline', 'github_alerts', function (state) {
        const stack = [];
        for (let i = 0; i < state.tokens.length; i++) {
            const token = state.tokens[i];
            if (token.type === 'blockquote_open') {
                const inline = state.tokens[i + 2];
                const match = inline && inline.type === 'inline' && /^\[!(note|notes|tip|tips|important|warning|caution)\](?:[ \t]+([^\n]*))?(?:\n|$)/i.exec(inline.content);
                stack.push(!!match);
                if (!match) continue;
                const name = kinds[match[1].toLowerCase()];
                token.tag = 'div'; token.attrSet('class', 'markdown-alert markdown-alert-' + name.toLowerCase());
                state.tokens[i + 1].attrSet('class', 'markdown-alert-title');
                inline.content = match[2] || name;
                inline.children = [];
                state.md.inline.parse(inline.content, state.md, state.env, inline.children);
                const remaining = match.input.slice(match[0].length);
                if (remaining) {
                    const open = new state.Token('paragraph_open', 'p', 1);
                    const body = new state.Token('inline', '', 0); body.content = remaining; body.children = [];
                    state.md.inline.parse(remaining, state.md, state.env, body.children);
                    const close = new state.Token('paragraph_close', 'p', -1);
                    state.tokens.splice(i + 4, 0, open, body, close);
                }
            } else if (token.type === 'blockquote_close' && stack.pop()) token.tag = 'div';
        }
    });
    let generation = 0;
    let queue = Promise.resolve();
    const assetURL = document.baseURI;
    let mermaidPromise;
    function ensureMermaid() {
        if (window.mermaid) return Promise.resolve(window.mermaid);
        if (!mermaidPromise) {
            mermaidPromise = new Promise((resolve, reject) => {
                const script = document.createElement('script');
                script.src = new URL('mermaid.min.js', assetURL).href;
                script.onload = () => resolve(window.mermaid);
                script.onerror = () => reject(new Error('Mermaid bundle could not be loaded'));
                document.head.appendChild(script);
            });
        }
        return mermaidPromise;
    }
    const sanitizeOptions = {
        ADD_TAGS: ['semantics', 'annotation'], ADD_ATTR: ['encoding'],
        FORBID_TAGS: ['style', 'script', 'iframe', 'object', 'embed', 'form', 'base', 'link', 'meta'],
        FORBID_ATTR: ['srcset'], ALLOW_DATA_ATTR: false
    };
    function notify(message) { window.webkit?.messageHandlers?.markdownPreview?.postMessage(message); }
    let cachedText = null, cachedEnvironment = null, cachedBlocks = null;
    function lineStarts(text) {
        const offsets = [0];
        const endings = /\r\n|\r|\n/g;
        let match;
        while ((match = endings.exec(text))) offsets.push(match.index + match[0].length);
        return offsets;
    }
    // A pipe inside an escaped sequence or a matched code span belongs to the
    // cell. Backtick runs must match exactly, as with CommonMark code spans.
    function tableCells(line, offset, row) {
        const boundaries = [-1];
        for (let index = 0; index < line.length; index++) {
            if (line[index] === '\\') { index++; continue; }
            if (line[index] === '`') {
                let end = index;
                while (line[end] === '`') end++;
                const run = end - index;
                let close = end;
                while (close < line.length) {
                    if (line[close] !== '`') { close++; continue; }
                    let after = close;
                    while (line[after] === '`') after++;
                    if (after - close === run) { index = after - 1; break; }
                    close = after;
                }
                if (close < line.length) continue;
                index = end - 1;
                continue;
            }
            if (line[index] === '|') boundaries.push(index);
        }
        boundaries.push(line.length);
        const cells = [];
        for (let index = 0; index < boundaries.length - 1; index++) {
            let from = boundaries[index] + 1, to = boundaries[index + 1];
            while (from < to && /[ \t]/.test(line[from])) from++;
            while (to > from && /[ \t]/.test(line[to - 1])) to--;
            // Ignore optional outer pipes, retaining actual empty interior cells.
            if (from === to && (index === 0 || index === boundaries.length - 2)) continue;
            const source = line.slice(from, to);
            cells.push({row, column: cells.length, from: offset + from, to: offset + to, source, text: source});
        }
        return cells;
    }
    function parseBlocks(value) {
        const text = String(value);
        if (text === cachedText && cachedBlocks) return cachedBlocks;
        const env = {}, tokens = md.parse(text, env), starts = lineStarts(text), blocks = [];
        const position = line => line < starts.length ? starts[line] : text.length;
        const kindOf = (token, group) => {
            if ((token.attrGet('class') || '').includes('markdown-alert')) return 'callout';
            if (token.type.startsWith('math_block')) return 'math';
            switch (token.type) {
            case 'heading_open': return 'heading';
            case 'bullet_list_open': case 'ordered_list_open': return 'list';
            case 'blockquote_open': return 'quote';
            case 'table_open': return 'table';
            case 'fence': case 'code_block': return 'code';
            case 'html_block': return 'html';
            case 'hr': return 'hr';
            default: {
                const inline = group.find(item => item.type === 'inline');
                if (inline?.children?.length === 1 && inline.children[0].type === 'image') return 'image';
                return 'paragraph';
            }
            }
        };
        const nestedCodeBlocks = (group) => group.filter(item => item.type === 'fence' || item.type === 'code_block')
            .filter(item => item.map && item.map[1] > item.map[0])
            .map(item => {
                const from = position(item.map[0]), to = position(item.map[1]);
                return {
                    from, to, kind: 'code', source: text.slice(from, to),
                    language: item.info.trim().split(/\s+/)[0] || '', content: item.content,
                };
            });
        for (let index = 0; index < tokens.length;) {
            const token = tokens[index], start = index;
            let depth = token.nesting;
            index++;
            while (depth > 0 && index < tokens.length) depth += tokens[index++].nesting;
            if (!token.map || token.map[1] <= token.map[0]) continue;
            const from = position(token.map[0]), to = position(token.map[1]);
            const block = {from, to, kind: kindOf(token, tokens.slice(start, index)), source: text.slice(from, to)};
            if (block.kind === 'heading') block.level = Number(token.tag.slice(1));
            if (block.kind === 'code') { block.language = token.info.trim().split(/\s+/)[0] || ''; block.content = token.content; }
            if (block.kind === 'list') block.codeBlocks = nestedCodeBlocks(tokens.slice(start, index));
            if (block.kind === 'table') {
                block.rows = [];
                block.cells = [];
                for (let line = token.map[0]; line < token.map[1]; line++) {
                    const rowFrom = position(line), rowTo = position(line + 1);
                    const source = text.slice(rowFrom, rowTo).replace(/\r\n$|[\r\n]$/g, '');
                    const delimiter = line === token.map[0] + 1;
                    const row = line === token.map[0] ? 0 : line - token.map[0] - 1;
                    const cells = tableCells(source, rowFrom, delimiter ? -1 : row);
                    block.rows.push({from: rowFrom, to: rowTo, delimiter, cells});
                    if (!delimiter) block.cells.push(...cells);
                }
            }
            blocks.push(block);
        }
        // Reference definitions and other parser-elided source remain addressable
        // as source-only blocks; whitespace is never normalized or reserialized.
        const complete = [];
        let previous = 0;
        for (const block of blocks) {
            if (block.from > previous && text.slice(previous, block.from).trim()) {
                complete.push({from: previous, to: block.from, kind: 'paragraph', source: text.slice(previous, block.from), sourceOnly: true});
            }
            complete.push(block); previous = block.to;
        }
        if (previous < text.length && text.slice(previous).trim()) {
            complete.push({from: previous, to: text.length, kind: 'paragraph', source: text.slice(previous), sourceOnly: true});
        }
        cachedText = text; cachedEnvironment = env; cachedBlocks = complete;
        return complete;
    }
    function renderFragment(value, options = {}) {
        if (options.documentText !== undefined) parseBlocks(options.documentText);
        const env = options.documentText !== undefined && cachedEnvironment
            ? {references: cachedEnvironment.references} : {};
        const root = document.createElement('div');
        root.innerHTML = DOMPurify.sanitize(md.render(String(value), env), sanitizeOptions);
        root.querySelectorAll('input,button,textarea,select').forEach(input => { input.disabled = true; });
        root.querySelectorAll('img').forEach(image => {
            const source = image.getAttribute('src');
            if (!source) return;
            try {
                const url = options.imageURLs?.[source] || new URL(source, options.baseURL || assetURL).href;
                if (/^(https?:|data:image\/|blob:|omg-markdown-image:)/i.test(url)) image.src = url;
                else image.removeAttribute('src');
            } catch (_) { image.removeAttribute('src'); }
        });
        root.querySelectorAll('a[href]').forEach(link => {
            const source = link.getAttribute('href');
            if (source.startsWith('#')) return;
            try {
                const url = new URL(source, options.baseURL || assetURL);
                if (/^(https?:|mailto:|file:|omg-markdown-image:)$/i.test(url.protocol)) link.href = url.href;
                else link.removeAttribute('href');
            } catch (_) { link.removeAttribute('href'); }
            link.rel = 'noreferrer noopener';
        });
        return root.innerHTML;
    }
    window.omgMarkdownModel = {parseBlocks, renderFragment, ensureMermaid};
    // Shared sanitized rendering for preserved rich blocks in the live editor.
    window.omgMarkdownFragment = renderFragment;
    window.omgEnsureMermaid = ensureMermaid;
    async function render(markdown, options, request) {
        if (request !== generation) return;
        const content = document.getElementById('content');
        const theme = options.theme === 'dark' ? 'dark' : 'light';
        document.documentElement.dataset.theme = theme;
        document.getElementById('highlight-theme').href = new URL(theme === 'dark' ? 'github-dark.min.css' : 'github.min.css', assetURL).href;
        for (const key of ['background', 'foreground']) {
            const value = options[key];
            if (value && CSS.supports('color', value)) document.documentElement.style.setProperty('--' + key, value);
        }
        content.innerHTML = DOMPurify.sanitize(md.render(String(markdown)), sanitizeOptions);
        // Disable all user controls; task lists in the preview do not mutate the source.
        content.querySelectorAll('input').forEach(input => { input.disabled = true; });
        content.querySelectorAll('img').forEach(img => {
            const source = img.getAttribute('src');
            if (!source) return;
            try {
                const resolved = options.imageURLs?.[source] || new URL(source, options.baseURL || assetURL).href;
                if (/^(https?:|data:image\/|blob:|omg-markdown-image:)/i.test(resolved)) img.src = resolved;
                else img.removeAttribute('src');
            } catch (_) { img.removeAttribute('src'); }
            img.loading = 'lazy';
        });
        content.querySelectorAll('a[href]').forEach(link => {
            const href = link.getAttribute('href');
            if (href.startsWith('#')) return;
            try { link.href = new URL(href, options.baseURL || assetURL).href; } catch (_) { link.removeAttribute('href'); }
            link.rel = 'noreferrer noopener';
        });
        const blocks = Array.from(content.querySelectorAll('pre > code.language-mermaid'));
        if (blocks.length === 0) {
            if (request === generation) notify({type: 'rendered'});
            return;
        }
        const mermaid = await ensureMermaid();
        mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: theme === 'dark' ? 'dark' : 'default',
            suppressErrorRendering: true, maxTextSize: 50000, htmlLabels: false, flowchart: {htmlLabels: false},
            secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'suppressErrorRendering', 'htmlLabels']});
        for (let index = 0; index < blocks.length; index++) {
            if (request !== generation) return;
            const block = blocks[index];
            try {
                const result = await mermaid.render('omg-diagram-' + request + '-' + index, block.textContent);
                if (request !== generation) return;
                const figure = document.createElement('figure'); figure.className = 'mermaid';
                // Mermaid's strict mode sanitizes diagram markup; sanitize once more at the insertion boundary.
                figure.innerHTML = DOMPurify.sanitize(result.svg, {USE_PROFILES: {svg: true, svgFilters: true}, FORBID_TAGS: ['foreignObject', 'script'], FORBID_ATTR: ['onload']});
                block.parentElement.replaceWith(figure);
            } catch (error) {
                const message = document.createElement('p'); message.className = 'render-error';
                message.textContent = 'Mermaid: ' + String(error.message || error).slice(0, 300);
                block.parentElement.after(message);
            }
        }
        if (request === generation) notify({type: 'rendered'});
    }
    window.renderMarkdown = function (markdown, options = {}) {
        const request = ++generation;
        queue = queue.catch(() => {}).then(() => render(markdown, options, request));
        return queue;
    };
    window.renderMarkdownReadonly = window.renderMarkdown;
    // The live editor announces readiness after installing the editing API.
})();
