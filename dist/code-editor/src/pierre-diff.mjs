import './dom-shims.mjs';
import {
  FileDiff,
  parseDiffFromFile,
  parsePatchFiles,
  preloadHighlighter,
  registerCustomTheme,
  replaceCustomExtensions,
  setLanguageOverride,
} from '@pierre/diffs';
import {
  getPierreLanguageForMonacoId,
  LANGUAGE_SPECS,
  resolveMonacoLanguageId,
} from './languages.mjs';
import { applyPierreCssVariables } from './theme.mjs';

const PIERRE_DARK_THEME = 'omg-pierre-dark';
const PIERRE_LIGHT_THEME = 'omg-pierre-light';
const COLLAPSED_CONTEXT_THRESHOLD = 3;
const EXPANSION_LINE_COUNT = 20;

const OMG_PIERRE_SYNTAX = {
  attribute: { color: 'attribute' },
  boolean: { color: 'number' },
  comment: { color: 'comment', font_style: 'italic' },
  'comment.doc': { color: 'comment', font_style: 'italic' },
  constant: { color: 'number' },
  constructor: { color: 'type' },
  embedded: { color: 'foreground' },
  emphasis: { font_style: 'italic' },
  'emphasis.strong': { font_weight: 700 },
  enum: { color: 'type' },
  function: { color: 'function' },
  'function.method': { color: 'function' },
  'function.special': { color: 'function' },
  hint: { color: 'comment' },
  keyword: { color: 'keyword' },
  label: { color: 'attribute' },
  link_text: { color: 'string' },
  link_uri: { color: 'function' },
  namespace: { color: 'type' },
  number: { color: 'number' },
  operator: { color: 'keyword' },
  predictive: { color: 'comment' },
  preproc: { color: 'keyword' },
  primary: { color: 'foreground' },
  property: { color: 'variable' },
  punctuation: { color: 'foreground' },
  'punctuation.bracket': { color: 'foreground' },
  'punctuation.delimiter': { color: 'foreground' },
  'punctuation.list_marker': { color: 'keyword' },
  'punctuation.special': { color: 'keyword' },
  selector: { color: 'keyword' },
  string: { color: 'string' },
  'string.escape': { color: 'number' },
  'string.regex': { color: 'string' },
  'string.special': { color: 'string' },
  'string.special.symbol': { color: 'number' },
  tag: { color: 'variable' },
  'text.literal': { color: 'string' },
  title: { color: 'function', font_weight: 600 },
  type: { color: 'type' },
  'type.builtin': { color: 'type' },
  'type.interface': { color: 'type' },
  variable: { color: 'variable' },
  'variable.special': { color: 'keyword' },
};

function createOmgZedTheme(appearance) {
  const isDark = appearance !== 'light';
  return {
    name: isDark ? PIERRE_DARK_THEME : PIERRE_LIGHT_THEME,
    appearance: isDark ? 'dark' : 'light',
    cssVariables: {
      prefix: '--omg-syntax-',
      defaults: {
        background: 'transparent',
        foreground: isDark ? '#abb2bf' : '#383a42',
        keyword: isDark ? '#c678dd' : '#a626a4',
        function: isDark ? '#61afef' : '#4078f2',
        type: isDark ? '#e5c07b' : '#c18401',
        string: isDark ? '#98c379' : '#50a14f',
        number: isDark ? '#d19a66' : '#986801',
        comment: isDark ? '#5c6370' : '#a0a1a7',
        variable: isDark ? '#e06c75' : '#e45649',
        attribute: isDark ? '#d19a66' : '#986801',
      },
    },
    style: {
      background: 'background',
      foreground: 'foreground',
      text: 'foreground',
      syntax: OMG_PIERRE_SYNTAX,
    },
  };
}

// ThinkRail-inspired Shadow DOM styling over OMG's transparent glass vibrancy backdrop
const OMG_PIERRE_UNSAFE_CSS = `
:host,
[data-diffs],
[data-diff],
pre,
code,
[data-gutter],
[data-content] {
  background-color: transparent !important;
}

pre[data-diff] {
  margin: 0;
  padding: 6px 0 20px 0;
}

[data-separator='line-info'] {
  height: 28px;
  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
  font-size: 11.5px;
  border-top: 1px solid color-mix(in srgb, var(--diffs-fg) 8%, transparent);
  border-bottom: 1px solid color-mix(in srgb, var(--diffs-fg) 8%, transparent);
  backdrop-filter: blur(8px);
  -webkit-backdrop-filter: blur(8px);
}

[data-expand-button] {
  cursor: pointer;
  border-radius: 4px;
  transition: background-color 120ms ease, color 120ms ease;
}

[data-expand-button]:hover {
  background-color: color-mix(in srgb, var(--diffs-fg) 12%, transparent);
}

[data-gutter-utility-slot] button {
  cursor: pointer;
  border-radius: 5px;
  transition: transform 100ms ease, background-color 120ms ease;
}

[data-gutter-utility-slot] button:hover {
  transform: scale(1.06);
}

[data-line][data-editor-active-line] {
  box-shadow: inset 2px 0 0 0 var(--diffs-modified-color-override, #58a6ff);
  background-color: color-mix(in srgb, var(--diffs-modified-color-override, #58a6ff) 12%, transparent);
}

code::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}

code::-webkit-scrollbar-track {
  background: transparent;
}

code::-webkit-scrollbar-thumb {
  background: color-mix(in srgb, var(--diffs-fg) 22%, transparent);
  border-radius: 4px;
}

code::-webkit-scrollbar-thumb:hover {
  background: color-mix(in srgb, var(--diffs-fg) 36%, transparent);
}
`;

let runtimeInitialized = false;
let highlighterReadyPromise = null;

export function ensurePierreDiffRuntime() {
  if (!runtimeInitialized) {
    runtimeInitialized = true;
    registerCustomTheme(
      PIERRE_DARK_THEME,
      () => Promise.resolve(createOmgZedTheme('dark')),
      'zed'
    );
    registerCustomTheme(
      PIERRE_LIGHT_THEME,
      () => Promise.resolve(createOmgZedTheme('light')),
      'zed'
    );

    const extMap = {};
    for (const spec of LANGUAGE_SPECS) {
      if (!spec.pierre) continue;
      for (const ext of spec.extensions ?? []) {
        const cleanExt = ext.startsWith('.') ? ext.slice(1) : ext;
        if (cleanExt) extMap[cleanExt] = spec.pierre;
      }
      for (const fname of spec.filenames ?? []) {
        if (fname) extMap[fname] = spec.pierre;
      }
    }
    replaceCustomExtensions(extMap);

    highlighterReadyPromise = preloadHighlighter({
      themes: [PIERRE_DARK_THEME, PIERRE_LIGHT_THEME],
      langs: ['text'],
      preferredHighlighter: 'highlights',
    }).catch(() => {});
  }
  return highlighterReadyPromise;
}

// Kick off offline @pierre/highlights WASM + Zed theme resolution immediately on bundle load
ensurePierreDiffRuntime();

function splitLinesPreservingNewlines(text) {
  if (!text) return [];
  const parts = text.match(/[^\n]*\n|[^\n]+/g);
  return parts ?? [];
}

function stripTrailingLineBreak(line) {
  if (typeof line !== 'string') return '';
  return line.replace(/\r?\n$/, '');
}

function createSyntheticFullSourceDiff(filePath, contents, pierreLang) {
  const lines = splitLinesPreservingNewlines(contents);
  const count = lines.length;
  const noEOFCR = contents.length > 0 && !contents.endsWith('\n');
  const hunks =
    count > 0
      ? [
          {
            collapsedBefore: 0,
            additionStart: 1,
            additionCount: count,
            additionLines: count,
            additionLineIndex: 0,
            deletionStart: 1,
            deletionCount: count,
            deletionLines: count,
            deletionLineIndex: 0,
            hunkContent: [
              {
                type: 'context',
                lines: count,
                additionLineIndex: 0,
                deletionLineIndex: 0,
              },
            ],
            hunkContext: undefined,
            hunkSpecs: `@@ -1,${count} +1,${count} @@`,
            splitLineStart: 0,
            splitLineCount: count,
            unifiedLineStart: 0,
            unifiedLineCount: count,
            noEOFCRAdditions: noEOFCR,
            noEOFCRDeletions: noEOFCR,
          },
        ]
      : [];

  return {
    name: filePath || 'untitled',
    prevName: undefined,
    type: 'change',
    hunks,
    splitLineCount: count,
    unifiedLineCount: count,
    isPartial: false,
    deletionLines: lines,
    additionLines: [...lines],
    deletionCharacterCount: contents.length,
    additionCharacterCount: contents.length,
    ...(pierreLang ? { lang: pierreLang } : {}),
  };
}

function normalizePatchInput(rawPatch, filePath) {
  const trimmed = String(rawPatch ?? '');
  if (!trimmed.trim()) return '';
  const hasGitHeader = /^diff --git /m.test(trimmed);
  const hasUnifiedHeader = /^---\s+\S+/m.test(trimmed) && /^\+\+\+\s+\S+/m.test(trimmed);
  if (hasGitHeader || hasUnifiedHeader) {
    return trimmed;
  }
  if (/^@@\s+-\d+/m.test(trimmed)) {
    const cleanName = (filePath || 'file').replace(/^\/+/, '');
    return `--- a/${cleanName}\n+++ b/${cleanName}\n${trimmed}`;
  }
  return trimmed;
}

export function extractChangeBlocks(fileDiff) {
  if (!fileDiff || !Array.isArray(fileDiff.hunks)) return [];
  const blocks = [];
  for (let hunkIndex = 0; hunkIndex < fileDiff.hunks.length; hunkIndex++) {
    const hunk = fileDiff.hunks[hunkIndex];
    let addLine = Math.max(1, hunk.additionStart || 1);
    let delLine = Math.max(1, hunk.deletionStart || 1);
    for (const content of hunk.hunkContent ?? []) {
      if (content.type === 'context') {
        addLine += content.lines;
        delLine += content.lines;
      } else if (content.type === 'change') {
        const hasAdditions = content.additions > 0;
        const side = hasAdditions ? 'additions' : 'deletions';
        const lineNumber = hasAdditions ? addLine : delLine;
        const modifiedLineNumber = hasAdditions ? addLine : Math.max(1, addLine);
        blocks.push({
          index: blocks.length,
          hunkIndex,
          side,
          lineNumber,
          modifiedLineNumber,
          originalLineNumber: delLine,
          additionStart: addLine,
          deletionStart: delLine,
          additions: content.additions,
          deletions: content.deletions,
        });
        addLine += content.additions;
        delLine += content.deletions;
      }
    }
  }
  return blocks;
}

function buildPartialLineLookup(fileDiff) {
  const additions = new Map();
  const deletions = new Map();
  if (!fileDiff) return { additions, deletions };

  if (!fileDiff.isPartial) {
    for (let i = 0; i < (fileDiff.additionLines?.length ?? 0); i++) {
      additions.set(i + 1, stripTrailingLineBreak(fileDiff.additionLines[i]));
    }
    for (let i = 0; i < (fileDiff.deletionLines?.length ?? 0); i++) {
      deletions.set(i + 1, stripTrailingLineBreak(fileDiff.deletionLines[i]));
    }
    return { additions, deletions };
  }

  for (const hunk of fileDiff.hunks ?? []) {
    let addLine = Math.max(1, hunk.additionStart || 1);
    let delLine = Math.max(1, hunk.deletionStart || 1);
    for (const content of hunk.hunkContent ?? []) {
      if (content.type === 'context') {
        for (let i = 0; i < content.lines; i++) {
          const addRaw = fileDiff.additionLines?.[content.additionLineIndex + i];
          const delRaw = fileDiff.deletionLines?.[content.deletionLineIndex + i];
          if (addRaw !== undefined) additions.set(addLine + i, stripTrailingLineBreak(addRaw));
          if (delRaw !== undefined) deletions.set(delLine + i, stripTrailingLineBreak(delRaw));
        }
        addLine += content.lines;
        delLine += content.lines;
      } else if (content.type === 'change') {
        for (let i = 0; i < content.additions; i++) {
          const addRaw = fileDiff.additionLines?.[content.additionLineIndex + i];
          if (addRaw !== undefined) additions.set(addLine + i, stripTrailingLineBreak(addRaw));
        }
        for (let i = 0; i < content.deletions; i++) {
          const delRaw = fileDiff.deletionLines?.[content.deletionLineIndex + i];
          if (delRaw !== undefined) deletions.set(delLine + i, stripTrailingLineBreak(delRaw));
        }
        addLine += content.additions;
        delLine += content.deletions;
      }
    }
  }
  return { additions, deletions };
}

export class PierreDiffController {
  constructor({
    container,
    win = globalThis.window,
    doc = globalThis.document,
    askAgent,
    postMessage,
    initialThemeData,
    initialFont,
  }) {
    this.container = container;
    this.win = win;
    this.doc = doc;
    this.askAgent = askAgent;
    this.postMessage = postMessage;
    this.themeType = initialThemeData?.isDark === false ? 'light' : 'dark';
    this.pierrePalette = initialThemeData?.pierre ?? null;
    this.font = {
      fontFamily:
        initialFont?.fontFamily ??
        "ui-monospace, 'JetBrains Mono', 'SF Mono', Menlo, monospace",
      fontSize: initialFont?.fontSize ?? 13,
      fontLigatures: initialFont?.fontLigatures ?? true,
    };

    this.scrollerEl = doc.createElement('div');
    this.scrollerEl.className = 'omg-pierre-diff-scroller';
    this.scrollerEl.tabIndex = 0;

    this.emptyStateEl = doc.createElement('div');
    this.emptyStateEl.className = 'omg-pierre-diff-empty';
    this.emptyStateEl.hidden = true;

    this.scrollerEl.appendChild(this.emptyStateEl);
    this.container.appendChild(this.scrollerEl);

    this.fileContainer = null;
    this.fileDiffInstance = null;

    this.activeState = {
      id: 'default',
      path: '',
      patchOnly: false,
      review: true,
      inline: false,
      wordWrap: false,
      readOnly: true,
      languageId: 'plaintext',
      pierreLang: null,
    };

    this.cachedParseKey = null;
    this.cachedBaseDiff = null;
    this.cachedFullSourceDiff = null;
    this.effectiveDiff = null;
    this.lineLookup = { additions: new Map(), deletions: new Map() };
    this.changeBlocks = [];
    this.currentChangeIndex = -1;
    this.currentLineNumber = 1;
    this.currentSide = 'additions';
    this.lastSelectedRange = null;

    this.onFocusIn = () => {
      this.postMessage?.({ type: 'focus' });
    };
    this.onPointerDown = () => {
      this.postMessage?.({ type: 'focus' });
    };
    this.scrollerEl.addEventListener('focusin', this.onFocusIn);
    this.scrollerEl.addEventListener('pointerdown', this.onPointerDown);

    this.applyFontCssVariables();
    if (this.pierrePalette) {
      applyPierreCssVariables(this.container, this.pierrePalette);
    }
  }

  applyFontCssVariables() {
    const targets = [this.doc?.documentElement, this.container].filter(Boolean);
    const size = Math.max(8, Number(this.font.fontSize) || 13);
    const lineHeight = Math.max(18, Math.round(size * 1.54));
    const features = this.font.fontLigatures ? '"calt" 1, "liga" 1' : '"calt" 0, "liga" 0';
    for (const el of targets) {
      el.style?.setProperty('--diffs-font-family', this.font.fontFamily);
      el.style?.setProperty(
        '--diffs-header-font-family',
        "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
      );
      el.style?.setProperty('--diffs-font-size', `${size}px`);
      el.style?.setProperty('--diffs-line-height', `${lineHeight}px`);
      el.style?.setProperty('--diffs-font-features', features);
    }
  }

  buildOptions({ review, inline, wordWrap, isPartial }) {
    return {
      theme: {
        dark: PIERRE_DARK_THEME,
        light: PIERRE_LIGHT_THEME,
      },
      themeType: this.themeType,
      preferredHighlighter: 'highlights',
      diffStyle: inline ? 'unified' : 'split',
      overflow: wordWrap ? 'wrap' : 'scroll',
      diffIndicators: 'bars',
      hunkSeparators: 'line-info',
      expandUnchanged: !review && !isPartial,
      collapsedContextThreshold: COLLAPSED_CONTEXT_THRESHOLD,
      expansionLineCount: EXPANSION_LINE_COUNT,
      disableFileHeader: true,
      disableBackground: false,
      lineHoverHighlight: 'both',
      enableLineSelection: true,
      enableGutterUtility: true,
      unsafeCSS: OMG_PIERRE_UNSAFE_CSS,
      onGutterUtilityClick: (range) => {
        if (range) {
          this.handleSelectedRange(range, true);
        }
      },
      onLineSelectionEnd: (range) => {
        if (range) {
          this.handleSelectedRange(range, true);
        } else {
          this.lastSelectedRange = null;
          this.askAgent?.hidePrompt?.(false);
        }
      },
    };
  }

  ensureInstance(options) {
    if (!this.fileContainer) {
      this.fileContainer = this.doc.createElement('diffs-container');
      this.fileContainer.className = 'omg-pierre-diffs-element';
      this.scrollerEl.appendChild(this.fileContainer);
    }
    this.fileContainer.setAttribute('data-theme-type', this.themeType);
    if (!this.fileDiffInstance) {
      this.fileDiffInstance = new FileDiff(options);
    } else {
      this.fileDiffInstance.setOptions(options);
    }
    return this.fileDiffInstance;
  }

  parseOrGetCachedDiff({
    id,
    path,
    originalText,
    modifiedText,
    patch,
    patchOnly,
    pierreLang,
  }) {
    const normOrig = String(originalText ?? '');
    const normMod = String(modifiedText ?? '');
    const normPatch = String(patch ?? '');
    const effectivePatchOnly =
      Boolean(patchOnly) ||
      (originalText === undefined && modifiedText === undefined && normPatch.length > 0);

    const parseKey = JSON.stringify([
      String(id ?? 'default'),
      String(path ?? ''),
      effectivePatchOnly,
      effectivePatchOnly ? normPatch : normOrig,
      effectivePatchOnly ? '' : normMod,
      pierreLang ?? '',
    ]);

    if (parseKey === this.cachedParseKey && this.cachedBaseDiff) {
      return {
        isSameDiffTarget: true,
        effectivePatchOnly,
        baseDiff: this.cachedBaseDiff,
        fullSourceFallbackDiff: this.cachedFullSourceDiff,
      };
    }

    let baseDiff = null;
    let fullSourceFallbackDiff = null;

    if (effectivePatchOnly) {
      const normalizedPatch = normalizePatchInput(normPatch, path);
      const parsedPatches = normalizedPatch ? parsePatchFiles(normalizedPatch) : [];
      const firstFile = parsedPatches[0]?.files?.[0] ?? null;
      if (firstFile) {
        baseDiff = pierreLang ? setLanguageOverride(firstFile, pierreLang) : firstFile;
        if (!baseDiff.name && path) {
          baseDiff.name = path;
        }
      } else {
        baseDiff = {
          name: path || 'untitled',
          type: 'change',
          hunks: [],
          splitLineCount: 0,
          unifiedLineCount: 0,
          isPartial: true,
          deletionLines: [],
          additionLines: [],
          deletionCharacterCount: 0,
          additionCharacterCount: 0,
          ...(pierreLang ? { lang: pierreLang } : {}),
        };
      }
    } else {
      const fileName = path || 'untitled';
      const oldFile = {
        name: fileName,
        contents: normOrig,
        ...(pierreLang ? { lang: pierreLang } : {}),
      };
      const newFile = {
        name: fileName,
        contents: normMod,
        ...(pierreLang ? { lang: pierreLang } : {}),
      };
      baseDiff = parseDiffFromFile(oldFile, newFile);
      if (baseDiff.hunks.length === 0 && (normMod.length > 0 || normOrig.length > 0)) {
        fullSourceFallbackDiff = createSyntheticFullSourceDiff(
          fileName,
          normMod.length > 0 ? normMod : normOrig,
          pierreLang
        );
      }
    }

    this.cachedParseKey = parseKey;
    this.cachedBaseDiff = baseDiff;
    this.cachedFullSourceDiff = fullSourceFallbackDiff;

    return {
      isSameDiffTarget: false,
      effectivePatchOnly,
      baseDiff,
      fullSourceFallbackDiff,
    };
  }

  activateDiff({
    id = 'default',
    path = '',
    originalText,
    modifiedText,
    patch = '',
    patchOnly = false,
    review = true,
    inline = false,
    wordWrap = false,
    readOnly = true,
    languageHint,
  } = {}) {
    const resolvedReview = review !== undefined ? Boolean(review) : true;
    const resolvedInline = Boolean(inline);
    const resolvedWordWrap = Boolean(wordWrap);
    const resolvedReadOnly = readOnly !== undefined ? Boolean(readOnly) : true;

    const languageId = resolveMonacoLanguageId({ languageHint, path });
    const pierreLang = getPierreLanguageForMonacoId(languageId);

    const prevReview = this.activeState.review;
    const {
      isSameDiffTarget,
      effectivePatchOnly,
      baseDiff,
      fullSourceFallbackDiff,
    } = this.parseOrGetCachedDiff({
      id,
      path,
      originalText,
      modifiedText,
      patch,
      patchOnly,
      pierreLang,
    });

    const targetDiff =
      !resolvedReview && baseDiff.hunks.length === 0 && fullSourceFallbackDiff
        ? fullSourceFallbackDiff
        : baseDiff;

    this.activeState = {
      id: String(id ?? 'default'),
      path: String(path ?? ''),
      patchOnly: effectivePatchOnly,
      review: resolvedReview,
      inline: resolvedInline,
      wordWrap: resolvedWordWrap,
      readOnly: resolvedReadOnly,
      languageId,
      pierreLang,
    };

    this.effectiveDiff = targetDiff;
    this.lineLookup = buildPartialLineLookup(targetDiff);
    this.changeBlocks = extractChangeBlocks(baseDiff);

    if (!isSameDiffTarget) {
      this.currentChangeIndex = -1;
      this.currentLineNumber = 1;
      this.currentSide = 'additions';
      this.lastSelectedRange = null;
      this.scrollerEl.scrollTop = 0;
    }

    const options = this.buildOptions({
      review: resolvedReview,
      inline: resolvedInline,
      wordWrap: resolvedWordWrap,
      isPartial: Boolean(targetDiff.isPartial),
    });

    const instance = this.ensureInstance(options);

    // When switching a new file or collapsing Full Source -> Review mode, reset manual hunk expansions
    if (!isSameDiffTarget || (!prevReview && resolvedReview)) {
      instance.hunksRenderer.setExpandedHunksMap(new Map());
    }
    if (!isSameDiffTarget) {
      instance.setSelectedLines(null, { notify: false });
      instance.setEditorActiveLine(null);
    }

    const hasRenderableRows = targetDiff.hunks.length > 0;
    if (!hasRenderableRows) {
      this.emptyStateEl.textContent = effectivePatchOnly
        ? 'No textual hunks in patch'
        : 'No textual changes';
      this.emptyStateEl.hidden = false;
      if (this.fileContainer) {
        this.fileContainer.style.display = 'none';
      }
      return true;
    }

    this.emptyStateEl.hidden = true;
    this.fileContainer.style.display = 'block';

    instance.render({
      fileDiff: targetDiff,
      fileContainer: this.fileContainer,
      containerWrapper: this.scrollerEl,
      forceRender: true,
    });

    return true;
  }

  findRenderedLineElement(lineNumber, side = 'additions') {
    const shadowRoot = this.fileContainer?.shadowRoot;
    if (!shadowRoot) return null;

    if (!this.activeState.inline) {
      const colAttr = side === 'deletions' ? 'data-deletions' : 'data-additions';
      const lineEl = shadowRoot.querySelector(`code[${colAttr}] [data-line="${lineNumber}"]`);
      if (lineEl) return lineEl;
      const numEl = shadowRoot.querySelector(
        `code[${colAttr}] [data-column-number="${lineNumber}"]`
      );
      if (numEl) return numEl;
    } else {
      const expectedType =
        side === 'deletions' ? 'change-deletion' : 'change-addition';
      const typedEl = shadowRoot.querySelector(
        `code[data-unified] [data-line="${lineNumber}"][data-line-type="${expectedType}"]`
      );
      if (typedEl) return typedEl;
      const anyLineEl = shadowRoot.querySelector(
        `code[data-unified] [data-line="${lineNumber}"]`
      );
      if (anyLineEl) return anyLineEl;
    }

    return (
      shadowRoot.querySelector(`[data-line="${lineNumber}"]`) ??
      shadowRoot.querySelector(`[data-column-number="${lineNumber}"]`)
    );
  }

  scrollToLineElement(targetEl) {
    if (!targetEl) return;
    try {
      targetEl.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
    } catch {
      targetEl.scrollIntoView?.();
    }
    if (
      typeof targetEl.offsetTop === 'number' &&
      targetEl.offsetTop > 0 &&
      this.scrollerEl.clientHeight > 0
    ) {
      const centeredTop = Math.max(
        0,
        targetEl.offsetTop - Math.round(this.scrollerEl.clientHeight * 0.35)
      );
      this.scrollerEl.scrollTop = centeredTop;
    }
  }

  navigateDiff({ direction = 'next', index } = {}) {
    if (!this.fileDiffInstance || this.changeBlocks.length === 0) {
      return false;
    }

    let targetIndex;
    if (typeof index === 'number' && Number.isFinite(index)) {
      targetIndex = Math.max(0, Math.min(this.changeBlocks.length - 1, Math.trunc(index)));
    } else {
      const isPrev = direction === 'prev' || direction === 'previous';
      if (isPrev) {
        targetIndex =
          this.currentChangeIndex <= 0
            ? this.changeBlocks.length - 1
            : this.currentChangeIndex - 1;
      } else {
        targetIndex =
          this.currentChangeIndex < 0 ||
          this.currentChangeIndex >= this.changeBlocks.length - 1
            ? 0
            : this.currentChangeIndex + 1;
      }
    }

    const block = this.changeBlocks[targetIndex];
    if (!block) return false;

    this.currentChangeIndex = targetIndex;
    this.currentLineNumber = block.modifiedLineNumber;
    this.currentSide = block.side;

    this.fileDiffInstance.setEditorActiveLine(block.lineNumber, {
      side: block.side,
    });

    const lineEl = this.findRenderedLineElement(block.lineNumber, block.side);
    this.scrollToLineElement(lineEl);
    return true;
  }

  extractLinesText(side, startLine, endLine) {
    const lo = Math.min(startLine, endLine);
    const hi = Math.max(startLine, endLine);
    const map = side === 'deletions' ? this.lineLookup.deletions : this.lineLookup.additions;
    const collected = [];
    for (let ln = lo; ln <= hi; ln++) {
      if (map.has(ln)) {
        collected.push(map.get(ln));
      } else {
        const domEl = this.findRenderedLineElement(ln, side);
        if (domEl) {
          collected.push(stripTrailingLineBreak(domEl.textContent ?? ''));
        }
      }
    }
    return collected.join('\n');
  }

  computeAnchorRectForLine(lineNumber, side) {
    const lineEl = this.findRenderedLineElement(lineNumber, side);
    if (!lineEl || typeof lineEl.getBoundingClientRect !== 'function') {
      return null;
    }
    const rect = lineEl.getBoundingClientRect();
    const appRect = this.container.parentElement?.getBoundingClientRect?.() ?? {
      top: 0,
      left: 0,
    };
    if (!rect || (rect.top === 0 && rect.bottom === 0 && rect.height === 0)) {
      return null;
    }
    return {
      top: rect.top - appRect.top,
      left: rect.left - appRect.left,
      height: rect.height || 20,
    };
  }

  handleSelectedRange(range, openPrompt = true) {
    if (!range) return false;
    const side = range.endSide ?? range.side ?? 'additions';
    const startLine = Math.max(1, Math.min(range.start, range.end));
    const endLine = Math.max(startLine, Math.max(range.start, range.end));

    this.lastSelectedRange = { side, startLine, endLine };
    this.currentLineNumber = startLine;
    this.currentSide = side;

    if (!openPrompt || !this.askAgent) {
      return true;
    }

    const selectedText = this.extractLinesText(side, startLine, endLine);
    const anchorCoords = this.computeAnchorRectForLine(startLine, side);

    return this.askAgent.openPromptForDiffContext({
      path: this.activeState.path,
      side,
      startLine,
      endLine,
      selectedText,
      anchorCoords,
      restoreFocusTarget: this.scrollerEl,
    });
  }

  selectLines({ startLine = 1, endLine = startLine, side = 'additions', openAskAgent = true } = {}) {
    if (!this.fileDiffInstance) return false;
    const s = Math.max(1, Math.trunc(Number(startLine) || 1));
    const e = Math.max(s, Math.trunc(Number(endLine) || s));
    const normalizedSide = side === 'deletions' ? 'deletions' : 'additions';
    this.fileDiffInstance.setSelectedLines(
      { start: s, end: e, side: normalizedSide },
      { notify: false }
    );
    return this.handleSelectedRange({ start: s, end: e, side: normalizedSide }, openAskAgent);
  }

  captureNativeDomSelection() {
    const shadowRoot = this.fileContainer?.shadowRoot;
    const sel =
      (typeof shadowRoot?.getSelection === 'function' ? shadowRoot.getSelection() : null) ??
      this.win?.getSelection?.();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
      return null;
    }
    const rawText = sel.toString();
    if (!rawText || !rawText.trim()) {
      return null;
    }

    const findLineInfo = (node) => {
      let cur = node?.nodeType === 1 ? node : node?.parentElement;
      while (cur) {
        if (cur.dataset?.line) {
          const ln = Number.parseInt(cur.dataset.line, 10);
          const codeParent = cur.closest?.('code');
          const side =
            codeParent?.hasAttribute('data-deletions') ||
            cur.dataset.lineType === 'change-deletion'
              ? 'deletions'
              : 'additions';
          if (Number.isFinite(ln)) return { lineNumber: ln, side };
        }
        cur = cur.parentElement;
      }
      return null;
    };

    const anchorInfo = findLineInfo(sel.anchorNode);
    const focusInfo = findLineInfo(sel.focusNode);
    if (!anchorInfo && !focusInfo) {
      return null;
    }

    const a = anchorInfo ?? focusInfo;
    const b = focusInfo ?? anchorInfo;
    const startLine = Math.min(a.lineNumber, b.lineNumber);
    const endLine = Math.max(a.lineNumber, b.lineNumber);
    const side = b.side ?? a.side ?? 'additions';

    return {
      path: this.activeState.path,
      side,
      startLine,
      endLine,
      selectedText: stripTrailingLineBreak(rawText),
      anchorCoords: this.computeAnchorRectForLine(startLine, side),
      restoreFocusTarget: this.scrollerEl,
    };
  }

  captureAskAgentContext() {
    const nativeSel = this.captureNativeDomSelection();
    if (nativeSel) return nativeSel;

    const range =
      this.fileDiffInstance?.interactionManager?.getSelection?.() ??
      (this.lastSelectedRange
        ? {
            start: this.lastSelectedRange.startLine,
            end: this.lastSelectedRange.endLine,
            side: this.lastSelectedRange.side,
          }
        : null);

    if (range) {
      const side = range.endSide ?? range.side ?? 'additions';
      const startLine = Math.max(1, Math.min(range.start, range.end));
      const endLine = Math.max(startLine, Math.max(range.start, range.end));
      return {
        path: this.activeState.path,
        side,
        startLine,
        endLine,
        selectedText: this.extractLinesText(side, startLine, endLine),
        anchorCoords: this.computeAnchorRectForLine(startLine, side),
        restoreFocusTarget: this.scrollerEl,
      };
    }

    const hovered = this.fileDiffInstance?.getHoveredLine?.();
    if (hovered && Number.isFinite(hovered.lineNumber)) {
      const side = hovered.side ?? 'additions';
      const ln = hovered.lineNumber;
      return {
        path: this.activeState.path,
        side,
        startLine: ln,
        endLine: ln,
        selectedText: this.extractLinesText(side, ln, ln),
        anchorCoords: this.computeAnchorRectForLine(ln, side),
        restoreFocusTarget: this.scrollerEl,
      };
    }

    const fallbackBlock =
      this.changeBlocks[Math.max(0, this.currentChangeIndex)] ?? this.changeBlocks[0];
    const fallbackLine = fallbackBlock?.lineNumber ?? this.currentLineNumber ?? 1;
    const fallbackSide = fallbackBlock?.side ?? this.currentSide ?? 'additions';
    return {
      path: this.activeState.path,
      side: fallbackSide,
      startLine: fallbackLine,
      endLine: fallbackLine,
      selectedText: this.extractLinesText(fallbackSide, fallbackLine, fallbackLine),
      anchorCoords: this.computeAnchorRectForLine(fallbackLine, fallbackSide),
      restoreFocusTarget: this.scrollerEl,
    };
  }

  openAskAgentPrompt(initialComment = '') {
    if (!this.askAgent) return false;
    const ctx = this.captureAskAgentContext();
    if (!ctx) return false;
    return this.askAgent.openPromptForDiffContext(ctx, initialComment);
  }

  setTheme(themeData) {
    if (!themeData) return;
    this.themeType = themeData.isDark === false ? 'light' : 'dark';
    this.pierrePalette = themeData.pierre ?? null;
    if (this.pierrePalette) {
      applyPierreCssVariables(this.container, this.pierrePalette);
    }
    if (this.fileContainer) {
      this.fileContainer.setAttribute('data-theme-type', this.themeType);
    }
    if (this.fileDiffInstance) {
      this.fileDiffInstance.setThemeType(this.themeType);
    }
  }

  setFont(nextFont) {
    if (!nextFont) return;
    if (typeof nextFont.fontFamily === 'string' && nextFont.fontFamily.length > 0) {
      this.font.fontFamily = nextFont.fontFamily;
    }
    if (typeof nextFont.fontSize === 'number' && nextFont.fontSize > 0) {
      this.font.fontSize = nextFont.fontSize;
    }
    if (typeof nextFont.fontLigatures === 'boolean') {
      this.font.fontLigatures = nextFont.fontLigatures;
    }
    this.applyFontCssVariables();
  }

  hide() {
    this.lastSelectedRange = null;
    if (this.fileDiffInstance) {
      this.fileDiffInstance.setSelectedLines(null, { notify: false });
    }
    this.container.style.display = 'none';
  }

  show() {
    this.container.style.display = 'block';
  }

  getState() {
    return {
      ...this.activeState,
      changeCount: this.changeBlocks.length,
      currentChangeIndex: this.currentChangeIndex,
      currentLineNumber: this.currentLineNumber,
      currentSide: this.currentSide,
      hunkCount: this.effectiveDiff?.hunks?.length ?? 0,
      isPartial: Boolean(this.effectiveDiff?.isPartial),
    };
  }

  // Backward-compatible position shim for tests/consumers inspecting modified line cursor
  getLegacyDiffEditorShim() {
    return {
      getModifiedEditor: () => ({
        getPosition: () => ({
          lineNumber: this.currentLineNumber,
          column: 1,
        }),
      }),
    };
  }

  dispose() {
    this.scrollerEl.removeEventListener('focusin', this.onFocusIn);
    this.scrollerEl.removeEventListener('pointerdown', this.onPointerDown);
    if (this.fileDiffInstance) {
      this.fileDiffInstance.cleanUp();
      this.fileDiffInstance = null;
    }
    this.fileContainer?.remove();
    this.fileContainer = null;
    this.scrollerEl.remove();
  }
}
