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
        token = state.push('paragraph_open', 'p', 1);
        token = state.push('inline', '', 0);
        token.content = '[!' + match[2] + ']' + (match[3] ? ' ' + match[3].replace(/^"|"$/g, '') : ''); token.children = [];
        state.push('paragraph_close', 'p', -1);
        const body = state.getLines(start + 1, next, match[1] === '!!!' ? state.sCount[start] + 4 : state.blkIndent, true);
        state.md.block.parse(body, state.md, state.env, state.tokens);
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
    // Shared sanitized rendering for preserved rich blocks in the live editor.
    window.omgMarkdownFragment = markdown => DOMPurify.sanitize(md.render(String(markdown)), sanitizeOptions);
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
    // live-editor.js sends ready after installing the editable render API.
})();
