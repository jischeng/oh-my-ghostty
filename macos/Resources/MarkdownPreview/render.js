/* OMG Markdown preview. Third-party engine licenses are in licenses/. */
(function () {
    'use strict';
    const kinds = { note: 'Note', notes: 'Note', tip: 'Tip', tips: 'Tip', important: 'Important', warning: 'Warning', caution: 'Caution' };
    const md = window.markdownit({
        html: true,
        linkify: true,
        highlight(code, language) {
            const lang = (language || '').trim().split(/\s+/)[0].toLowerCase();
            if (lang === 'mermaid' || lang === 'carousel') return '';
            if (lang && hljs.getLanguage(lang)) {
                try {
                    return '<pre class="hljs"><code>' + hljs.highlight(code, { language: lang, ignoreIllegals: true }).value + '</code></pre>';
                } catch (_) {}
            }
            return '<pre class="hljs"><code>' + md.utils.escapeHtml(code) + '</code></pre>';
        }
    });
    const defaultValidateLink = md.validateLink.bind(md);
    md.validateLink = function (url) {
        return /^file:\/\//i.test(String(url || '').trim()) || defaultValidateLink(url);
    };
    md.use(window.markdownitTaskLists, { enabled: false });
    md.use(window.markdownItAnchor);
    md.use(window.texmath, {
        engine: window.katex,
        delimiters: ['dollars', 'brackets', 'beg_end'],
        katexOptions: { throwOnError: false, trust: false, strict: 'ignore', maxExpand: 1000 }
    });

    // Unwrap standalone Codex <proposed_plan> wrapper lines without shifting source offsets.
    md.block.ruler.before('html_block', 'agent_plan_wrapper', function (state, start, _end, silent) {
        if (state.sCount[start] - state.blkIndent >= 4) return false;
        const line = state.src.slice(state.bMarks[start] + state.tShift[start], state.eMarks[start]);
        if (!/^<\/?proposed_plan>\s*$/i.test(line)) return false;
        if (silent) return true;
        state.line = start + 1;
        return true;
    });

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
        token.content = '[!' + match[2] + ']' + (match[3] ? ' ' + match[3].replace(/^"|"$/g, '') : '');
        token.children = [];
        state.push('paragraph_close', 'p', -1);
        const body = state.getLines(start + 1, next, match[1] === '!!!' ? state.sCount[start] + 4 : state.blkIndent, true);
        const bodyTokens = [];
        state.md.block.parse(body, state.md, state.env, bodyTokens);
        for (const child of bodyTokens) {
            if (child.map) child.map = child.map.map(lineNo => lineNo + start + 1);
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
                token.tag = 'div';
                token.attrSet('class', 'markdown-alert markdown-alert-' + name.toLowerCase());
                state.tokens[i + 1].attrSet('class', 'markdown-alert-title');
                inline.content = match[2] || name;
                inline.children = [];
                state.md.inline.parse(inline.content, state.md, state.env, inline.children);
                const remaining = match.input.slice(match[0].length);
                if (remaining) {
                    const open = new state.Token('paragraph_open', 'p', 1);
                    const body = new state.Token('inline', '', 0);
                    body.content = remaining;
                    body.children = [];
                    state.md.inline.parse(remaining, state.md, state.env, body.children);
                    const close = new state.Token('paragraph_close', 'p', -1);
                    state.tokens.splice(i + 4, 0, open, body, close);
                }
            } else if (token.type === 'blockquote_close' && stack.pop()) {
                token.tag = 'div';
            }
        }
    });

    let generation = 0;
    let queue = Promise.resolve();
    let currentMarkdown = '';
    let lastBaseURL = '';
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
        ADD_TAGS: ['semantics', 'annotation'],
        ADD_ATTR: ['encoding'],
        FORBID_TAGS: ['style', 'script', 'iframe', 'object', 'embed', 'form', 'base', 'link', 'meta'],
        FORBID_ATTR: ['srcset'],
        ALLOW_DATA_ATTR: false,
        ALLOWED_URI_REGEXP: /^(?:(?:(?:f|ht)tps?|mailto|tel|file|omg-markdown-image):|data:image\/(?:png|gif|jpeg|jpg|webp|bmp);|[a-z0-9_.\-]+\.[a-z0-9_]+:\d|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i
    };

    function notify(message) {
        window.webkit?.messageHandlers?.markdownPreview?.postMessage(message);
    }

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
            if (from === to && (index === 0 || index === boundaries.length - 2)) continue;
            const source = line.slice(from, to);
            cells.push({ row, column: cells.length, from: offset + from, to: offset + to, source, text: source });
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
        const nestedCodeBlocks = group => group.filter(item => item.type === 'fence' || item.type === 'code_block')
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
            const block = { from, to, kind: kindOf(token, tokens.slice(start, index)), source: text.slice(from, to) };
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
                    block.rows.push({ from: rowFrom, to: rowTo, delimiter, cells });
                    if (!delimiter) block.cells.push(...cells);
                }
            }
            blocks.push(block);
        }
        const complete = [];
        let previous = 0;
        for (const block of blocks) {
            if (block.from > previous && text.slice(previous, block.from).trim()) {
                complete.push({ from: previous, to: block.from, kind: 'paragraph', source: text.slice(previous, block.from), sourceOnly: true });
            }
            complete.push(block);
            previous = block.to;
        }
        if (previous < text.length && text.slice(previous).trim()) {
            complete.push({ from: previous, to: text.length, kind: 'paragraph', source: text.slice(previous), sourceOnly: true });
        }
        cachedText = text;
        cachedEnvironment = env;
        cachedBlocks = complete;
        return complete;
    }

    function resolveImageURL(source, options) {
        if (!source) return null;
        try {
            if (/^file:\/\//i.test(source)) {
                const fileURL = new URL(source);
                return new URL('omg-markdown-image://document' + fileURL.pathname).href;
            }
            const resolved = options.imageURLs?.[source] || new URL(source, options.baseURL || assetURL).href;
            return /^(https?:|data:image\/|blob:|omg-markdown-image:)/i.test(resolved) ? resolved : null;
        } catch (_) {
            return null;
        }
    }

    function renderFragment(value, options = {}) {
        if (options.documentText !== undefined) parseBlocks(options.documentText);
        const env = options.documentText !== undefined && cachedEnvironment
            ? { references: cachedEnvironment.references } : {};
        const root = document.createElement('div');
        root.innerHTML = DOMPurify.sanitize(md.render(String(value), env), sanitizeOptions);
        root.querySelectorAll('input,button,textarea,select').forEach(input => { input.disabled = true; });
        root.querySelectorAll('img').forEach(image => {
            const resolved = resolveImageURL(image.getAttribute('src'), options);
            if (resolved) image.src = resolved;
            else image.removeAttribute('src');
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

    window.omgMarkdownModel = { parseBlocks, renderFragment, ensureMermaid };
    window.omgMarkdownFragment = renderFragment;
    window.omgEnsureMermaid = ensureMermaid;

    function extractTokenMetadata(sourceText, tokens) {
        const starts = lineStarts(sourceText);
        const codeBlocks = [];
        const taskOffsets = [];
        for (let i = 0; i < tokens.length; i++) {
            const token = tokens[i];
            if (token.type === 'fence' || token.type === 'code_block') {
                const lang = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
                if (token.type === 'fence' && (lang === 'mermaid' || lang === 'carousel')) continue;
                codeBlocks.push({ lang: lang || 'text', content: token.content });
            } else if (token.type === 'inline' && token.children?.some(ch => ch.type === 'html_inline' && ch.content.includes('task-list-item-checkbox'))) {
                let startLine = token.map ? token.map[0] : null;
                if (startLine === null) {
                    for (let j = i - 1; j >= 0; j--) {
                        if (tokens[j].map) { startLine = tokens[j].map[0]; break; }
                    }
                }
                let offset = -1;
                if (startLine !== null && startLine < starts.length) {
                    const lineStart = starts[startLine];
                    const lineEnd = startLine + 1 < starts.length ? starts[startLine + 1] : sourceText.length;
                    const lineText = sourceText.slice(lineStart, lineEnd);
                    const m = /^(\s*(?:>\s*)*(?:[-+*]|\d+[.)])\s+\[)([ xX])(\])/.exec(lineText);
                    if (m) offset = lineStart + m[1].length;
                }
                taskOffsets.push(offset);
            }
        }
        return { codeBlocks, taskOffsets };
    }

    function parseFileLineBadge(rawHref) {
        const hashMatch = rawHref.match(/#(L?\d+(?:C\d+)?(?:-L?\d+(?:C\d+)?)?)$/i);
        if (hashMatch) {
            const raw = hashMatch[1];
            return { raw, badge: ':' + (/^l/i.test(raw) ? raw.toUpperCase() : 'L' + raw) };
        }
        const withoutScheme = rawHref.replace(/^file:\/\//i, '');
        const colonMatch = withoutScheme.match(/:(\d+)(?::\d+)?(?:-L?(\d+)(?::\d+)?)?$/);
        if (colonMatch) {
            const raw = colonMatch[2] ? colonMatch[1] + '-' + colonMatch[2] : colonMatch[1];
            const badge = colonMatch[2] ? ':L' + colonMatch[1] + '-L' + colonMatch[2] : ':L' + colonMatch[1];
            return { raw, badge };
        }
        return null;
    }

    function isLocalCodeReference(rawHref) {
        if (/^file:\/\//i.test(rawHref)) return true;
        if (/^(?:[a-z][a-z0-9+.-]*:(?!\d)|(?:javascript|vbscript|data|blob|about):)/i.test(rawHref)) return false;
        if (/^(?:\/(?!\/)|~\/)/.test(rawHref)) return true;
        return /(?:[./\\]).*(?:#L?\d+|:\d+(?::\d+)?(?:-L?\d+(?::\d+)?)?)$/i.test(rawHref);
    }

    function formatFileCapsule(link, rawHref) {
        link.classList.add('omg-file-link');
        let decodedHref = rawHref;
        try { decodedHref = decodeURIComponent(rawHref); } catch (_) {}
        link.title = decodedHref;
        const lineInfo = parseFileLineBadge(decodedHref);
        let labelText = link.textContent.trim();
        if (labelText === rawHref || labelText === decodedHref) {
            const stripped = decodedHref
                .replace(/^file:\/\//i, '')
                .replace(/#L?\d+(?:C\d+)?(?:-L?\d+(?:C\d+)?)?$/i, '')
                .replace(/:\d+(?::\d+)?(?:-L?\d+(?::\d+)?)?$/, '');
            const segments = stripped.split('/').filter(Boolean);
            if (segments.length > 0) labelText = segments[segments.length - 1];
        }
        const showBadge = lineInfo && !labelText.includes(lineInfo.raw);
        link.textContent = '';
        const labelSpan = document.createElement('span');
        labelSpan.className = 'omg-file-label';
        labelSpan.textContent = labelText;
        link.appendChild(labelSpan);
        if (showBadge) {
            const lineSpan = document.createElement('span');
            lineSpan.className = 'omg-file-line';
            lineSpan.textContent = lineInfo.badge;
            link.appendChild(lineSpan);
        }
    }

    function enhanceBlockDOM(container, sourceText, options, allowTaskToggle) {
        const env = options.sharedEnv ? { references: options.sharedEnv.references } : {};
        const tokens = md.parse(sourceText, env);
        if (!options.sharedEnv) options.sharedEnv = env;
        const meta = extractTokenMetadata(sourceText, tokens);
        container.innerHTML = DOMPurify.sanitize(md.renderer.render(tokens, md.options, env), sanitizeOptions);

        // 1. Checkboxes & form controls
        const checkboxes = Array.from(container.querySelectorAll('input.task-list-item-checkbox'));
        container.querySelectorAll('input,button,textarea,select').forEach(el => { el.disabled = true; });
        if (allowTaskToggle) {
            checkboxes.forEach((checkbox, index) => {
                const offset = meta.taskOffsets[index];
                if (typeof offset !== 'number' || offset < 0) return;
                checkbox.disabled = false;
                checkbox.addEventListener('change', () => {
                    const baseText = currentMarkdown;
                    const ch = baseText[offset];
                    if (ch !== ' ' && ch !== 'x' && ch !== 'X') return;
                    const replacement = checkbox.checked ? 'x' : ' ';
                    if (ch === replacement || (ch === 'X' && checkbox.checked)) return;
                    currentMarkdown = baseText.slice(0, offset) + replacement + baseText.slice(offset + 1);
                    notify({ type: 'edit', baseText, text: currentMarkdown });
                });
            });
        }

        // 2. Images (including file:// local/SSH images)
        container.querySelectorAll('img').forEach(img => {
            const resolved = resolveImageURL(img.getAttribute('src'), options);
            if (resolved) img.src = resolved;
            else img.removeAttribute('src');
            img.loading = 'lazy';
        });

        // 3. Links (anchor scroll, file:// code capsules, workspace relative paths, external links)
        container.querySelectorAll('a[href]').forEach(link => {
            const rawHref = link.getAttribute('href') || '';
            if (rawHref.startsWith('#')) {
                link.addEventListener('click', event => {
                    event.preventDefault();
                    const id = decodeURIComponent(rawHref.slice(1));
                    const target = id ? document.getElementById(id) : null;
                    target?.scrollIntoView({ behavior: 'smooth', block: 'start' });
                });
                return;
            }
            if (isLocalCodeReference(rawHref)) {
                link.href = /^file:\/\//i.test(rawHref) ? rawHref : '#';
                link.rel = 'noreferrer noopener';
                formatFileCapsule(link, rawHref);
                link.addEventListener('click', event => {
                    event.preventDefault();
                    notify({ type: 'openLink', href: rawHref });
                });
                return;
            }
            const hasScheme = /^(?:[a-z][a-z0-9+.-]*:(?!\d)|(?:javascript|vbscript|data|blob|about):)/i.test(rawHref);
            try {
                const resolved = new URL(rawHref, options.baseURL || assetURL);
                if (/^(https?:|mailto:)$/i.test(resolved.protocol)) {
                    link.href = resolved.href;
                    link.rel = 'noreferrer noopener';
                } else if (!hasScheme && resolved.protocol === 'omg-markdown-image:') {
                    link.href = resolved.href;
                    link.rel = 'noreferrer noopener';
                    link.addEventListener('click', event => {
                        event.preventDefault();
                        notify({ type: 'openLink', href: rawHref });
                    });
                } else {
                    link.removeAttribute('href');
                }
            } catch (_) {
                link.removeAttribute('href');
            }
        });

        // 4. Fenced code block cards with Copy button (before expanding nested carousels)
        const copyLabel = options.language === 'zh' ? '复制' : 'Copy';
        const copiedLabel = options.language === 'zh' ? '已复制 ✓' : 'Copied ✓';
        const preBlocks = Array.from(container.querySelectorAll('pre.hljs'));
        preBlocks.forEach((pre, index) => {
            const info = meta.codeBlocks[index] || { lang: 'text', content: pre.textContent || '' };
            const card = document.createElement('div');
            card.className = 'omg-code-card';
            const header = document.createElement('div');
            header.className = 'omg-code-header';
            const langSpan = document.createElement('span');
            langSpan.className = 'omg-code-lang';
            langSpan.textContent = info.lang;
            const copyBtn = document.createElement('button');
            copyBtn.type = 'button';
            copyBtn.className = 'omg-code-copy';
            copyBtn.textContent = copyLabel;
            copyBtn.addEventListener('click', () => {
                notify({ type: 'copy', text: info.content });
                try { navigator.clipboard?.writeText?.(info.content); } catch (_) {}
                copyBtn.textContent = copiedLabel;
                setTimeout(() => { copyBtn.textContent = copyLabel; }, 1200);
            });
            header.append(langSpan, copyBtn);
            pre.replaceWith(card);
            card.append(header, pre);
        });

        // 5. Antigravity ````carousel ... <!-- slide --> ... ```` blocks
        const carousels = Array.from(container.querySelectorAll('pre > code.language-carousel'));
        carousels.forEach(codeEl => {
            const slidesSource = (codeEl.textContent || '')
                .split(/^\s*<!--\s*slide\s*-->\s*$/m)
                .map(part => part.trim())
                .filter(Boolean);
            const pre = codeEl.parentElement;
            if (!pre || slidesSource.length === 0) return;

            const card = document.createElement('div');
            card.className = 'omg-carousel';
            const bar = document.createElement('div');
            bar.className = 'omg-carousel-bar';
            const status = document.createElement('span');
            status.className = 'omg-carousel-status';
            const dots = document.createElement('div');
            dots.className = 'omg-carousel-dots';
            const nav = document.createElement('div');
            nav.className = 'omg-carousel-nav';
            const prevBtn = document.createElement('button');
            prevBtn.type = 'button';
            prevBtn.className = 'omg-carousel-btn';
            prevBtn.dataset.dir = '-1';
            prevBtn.textContent = options.language === 'zh' ? '◀ 上一页' : '◀ Prev';
            const nextBtn = document.createElement('button');
            nextBtn.type = 'button';
            nextBtn.className = 'omg-carousel-btn';
            nextBtn.dataset.dir = '1';
            nextBtn.textContent = options.language === 'zh' ? '下一页 ▶' : 'Next ▶';
            nav.append(prevBtn, nextBtn);
            bar.append(status, dots, nav);
            card.appendChild(bar);

            const slideNodes = [];
            const dotNodes = [];
            let activeIndex = 0;

            slidesSource.forEach((slideMarkdown, idx) => {
                const slide = document.createElement('div');
                slide.className = 'omg-carousel-slide';
                enhanceBlockDOM(slide, slideMarkdown, options, false);
                card.appendChild(slide);
                slideNodes.push(slide);

                const dot = document.createElement('button');
                dot.type = 'button';
                dot.className = 'omg-carousel-dot';
                dot.addEventListener('click', () => selectSlide(idx));
                dots.appendChild(dot);
                dotNodes.push(dot);
            });

            function selectSlide(nextIndex) {
                activeIndex = Math.max(0, Math.min(slideNodes.length - 1, nextIndex));
                status.textContent = (activeIndex + 1) + ' / ' + slideNodes.length;
                slideNodes.forEach((node, idx) => node.classList.toggle('active', idx === activeIndex));
                dotNodes.forEach((node, idx) => node.classList.toggle('active', idx === activeIndex));
                prevBtn.disabled = activeIndex === 0;
                nextBtn.disabled = activeIndex === slideNodes.length - 1;
            }

            prevBtn.addEventListener('click', () => selectSlide(activeIndex - 1));
            nextBtn.addEventListener('click', () => selectSlide(activeIndex + 1));
            selectSlide(0);
            pre.replaceWith(card);
        });

        // 6. Smart responsive tables (prevent CJK column crushing while allowing smooth horizontal scroll)
        Array.from(container.querySelectorAll('table')).forEach(table => {
            if (table.parentElement?.classList.contains('omg-table-wrap')) return;
            table.querySelectorAll('td code').forEach(code => {
                if ((code.textContent || '').length <= 28) code.classList.add('omg-short-code');
            });
            const wrap = document.createElement('div');
            wrap.className = 'omg-table-wrap';
            table.replaceWith(wrap);
            wrap.appendChild(table);

            const rows = Array.from(table.querySelectorAll('tbody tr'));
            const colCount = Math.max(
                table.querySelectorAll('thead th').length,
                ...rows.map(row => row.children.length)
            );
            for (let col = 0; col < colCount; col++) {
                const cells = rows.map(row => row.children[col]).filter(Boolean);
                const maxLen = Math.max(0, ...cells.map(td => (td.textContent || '').trim().length));
                const cls = maxLen <= 12 ? 'omg-col-compact' : (maxLen <= 28 ? 'omg-col-medium' : 'omg-col-wide');
                cells.forEach(td => td.classList.add(cls));
            }
        });
    }

    async function render(markdown, options, request) {
        if (request !== generation) return;
        const content = document.getElementById('content');
        if (!content) return;
        const sourceText = String(markdown ?? '');
        currentMarkdown = sourceText;
        const sameDoc = Boolean(options.baseURL && options.baseURL === lastBaseURL);
        const prevScrollY = sameDoc ? (window.scrollY || 0) : 0;
        lastBaseURL = options.baseURL || '';

        const theme = options.theme === 'dark' ? 'dark' : 'light';
        document.documentElement.dataset.theme = theme;
        const hlTheme = document.getElementById('highlight-theme');
        if (hlTheme) {
            const targetHref = new URL(theme === 'dark' ? 'github-dark.min.css' : 'github.min.css', assetURL).href;
            if (hlTheme.href !== targetHref) hlTheme.href = targetHref;
        }
        for (const key of ['background', 'foreground']) {
            const value = options[key];
            if (value && window.CSS?.supports?.('color', value)) {
                document.documentElement.style.setProperty('--' + key, value);
            }
        }

        const renderOpts = Object.assign({}, options, { sharedEnv: null });
        enhanceBlockDOM(content, sourceText, renderOpts, Boolean(options.editable));
        if (sameDoc && prevScrollY > 0) {
            window.scrollTo?.(0, prevScrollY);
        }

        const blocks = Array.from(content.querySelectorAll('pre > code.language-mermaid'));
        if (blocks.length === 0) {
            if (request === generation) notify({ type: 'rendered' });
            return;
        }
        try {
            const mermaid = await ensureMermaid();
            mermaid.initialize({
                startOnLoad: false,
                securityLevel: 'strict',
                theme: theme === 'dark' ? 'dark' : 'default',
                suppressErrorRendering: true,
                maxTextSize: 50000,
                htmlLabels: false,
                flowchart: { htmlLabels: false },
                secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'suppressErrorRendering', 'htmlLabels']
            });
            for (let index = 0; index < blocks.length; index++) {
                if (request !== generation) return;
                const block = blocks[index];
                if (!block.parentElement) continue;
                try {
                    const result = await mermaid.render('omg-diagram-' + request + '-' + index, block.textContent);
                    if (request !== generation || !block.parentElement) return;
                    const figure = document.createElement('figure');
                    figure.className = 'mermaid';
                    figure.innerHTML = DOMPurify.sanitize(result.svg, {
                        USE_PROFILES: { svg: true, svgFilters: true },
                        FORBID_TAGS: ['foreignObject', 'script'],
                        FORBID_ATTR: ['onload']
                    });
                    block.parentElement.replaceWith(figure);
                } catch (error) {
                    const message = document.createElement('p');
                    message.className = 'render-error';
                    message.textContent = 'Mermaid: ' + String(error.message || error).slice(0, 300);
                    block.parentElement.after(message);
                }
            }
        } catch (error) {
            if (request === generation) {
                blocks.forEach(block => {
                    if (!block.parentElement) return;
                    const message = document.createElement('p');
                    message.className = 'render-error';
                    message.textContent = 'Mermaid: ' + String(error.message || error).slice(0, 300);
                    block.parentElement.after(message);
                });
            }
        }
        if (sameDoc && prevScrollY > 0) {
            window.scrollTo?.(0, prevScrollY);
        }
        if (request === generation) notify({ type: 'rendered' });
    }

    window.renderMarkdown = function (markdown, options = {}) {
        const request = ++generation;
        queue = queue.catch(() => {}).then(() => render(markdown, options, request));
        return queue;
    };
    window.renderMarkdownReadonly = function (markdown, options = {}) {
        return window.renderMarkdown(markdown, Object.assign({}, options, { editable: false }));
    };
    window.getMarkdown = function () {
        return currentMarkdown;
    };
    window.getSelectedMarkdownText = function () {
        return String(window.getSelection?.() || '');
    };
    window.selectAllMarkdown = function () {
        const content = document.getElementById('content');
        if (!content || !window.getSelection) return;
        const range = document.createRange();
        range.selectNodeContents(content);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
    };

    document.addEventListener('mousedown', () => notify({ type: 'focus' }));
    notify({ type: 'ready' });
})();
