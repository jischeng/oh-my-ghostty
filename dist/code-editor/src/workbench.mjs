import { AskAgentController } from './ask-agent.mjs';
import {
  MAX_LINE_LENGTH,
  MAX_MODEL_LINES,
  PierreHighlightingManager,
} from './highlighting.mjs';
import { KeymapController } from './keymaps.mjs';
import { resolveMonacoLanguageId } from './languages.mjs';
import { extractNormalizedRange, LspBridgeController } from './lsp-bridge.mjs';
import { applyOmgTheme } from './theme.mjs';

function normalizeWordWrap(wordWrap, fallback = 'off') {
  if (typeof wordWrap === 'boolean') {
    return wordWrap ? 'on' : 'off';
  }
  if (
    wordWrap === 'on' ||
    wordWrap === 'off' ||
    wordWrap === 'wordWrapColumn' ||
    wordWrap === 'bounded'
  ) {
    return wordWrap;
  }
  return fallback;
}

function normalizeMarkerSeverity(monaco, severity) {
  const { MarkerSeverity } = monaco;
  if (typeof severity === 'number') {
    if (
      severity === MarkerSeverity.Error ||
      severity === MarkerSeverity.Warning ||
      severity === MarkerSeverity.Info ||
      severity === MarkerSeverity.Hint
    ) {
      return severity;
    }
    // LSP DiagnosticSeverity: 1=Error, 2=Warning, 3=Info, 4=Hint
    if (severity === 1) return MarkerSeverity.Error;
    if (severity === 2) return MarkerSeverity.Warning;
    if (severity === 3) return MarkerSeverity.Info;
    if (severity === 4) return MarkerSeverity.Hint;
  }
  if (typeof severity === 'string') {
    const s = severity.toLowerCase();
    if (s === 'warning' || s === 'warn') return MarkerSeverity.Warning;
    if (s === 'info' || s === 'information') return MarkerSeverity.Info;
    if (s === 'hint') return MarkerSeverity.Hint;
    return MarkerSeverity.Error;
  }
  return MarkerSeverity.Error;
}

function isHighSurrogate(code) {
  return code >= 0xd800 && code <= 0xdbff;
}

function isLowSurrogate(code) {
  return code >= 0xdc00 && code <= 0xdfff;
}

export function computeMinimalTextEdit(model, oldText, newText, monaco) {
  const oldLen = oldText.length;
  const newLen = newText.length;
  const minLen = Math.min(oldLen, newLen);

  let prefix = 0;
  while (prefix < minLen && oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)) {
    prefix++;
  }
  if (prefix > 0 && isHighSurrogate(oldText.charCodeAt(prefix - 1))) {
    prefix--;
  }

  let suffix = 0;
  const maxSuffix = minLen - prefix;
  while (
    suffix < maxSuffix &&
    oldText.charCodeAt(oldLen - 1 - suffix) === newText.charCodeAt(newLen - 1 - suffix)
  ) {
    suffix++;
  }
  if (suffix > 0 && isLowSurrogate(oldText.charCodeAt(oldLen - suffix))) {
    suffix--;
  }

  const startPos = model.getPositionAt(prefix);
  const endPos = model.getPositionAt(oldLen - suffix);
  return {
    range: new monaco.Range(
      startPos.lineNumber,
      startPos.column,
      endPos.lineNumber,
      endPos.column
    ),
    text: newText.slice(prefix, newLen - suffix),
  };
}

function computeFallbackDiffHunks(originalText, modifiedText) {
  const origLines = originalText.split('\n');
  const modLines = modifiedText.split('\n');
  const maxLen = Math.max(origLines.length, modLines.length);
  const hunks = [];
  let inHunk = false;
  let hunkStart = 1;

  for (let i = 0; i < maxLen; i++) {
    const different = origLines[i] !== modLines[i];
    if (different && !inHunk) {
      inHunk = true;
      hunkStart = Math.min(i + 1, Math.max(1, modLines.length));
    } else if (!different && inHunk) {
      hunks.push(hunkStart);
      inHunk = false;
    }
  }
  if (inHunk) {
    hunks.push(hunkStart);
  }
  return hunks;
}

export function createOmgEditorWorkbench({
  monaco,
  win = globalThis.window,
  doc = globalThis.document,
  postMessage: customPostMessage,
} = {}) {
  const postMessage =
    customPostMessage ??
    ((msg) => {
      try {
        win?.webkit?.messageHandlers?.codeEditor?.postMessage?.(msg);
      } catch {
        // Ignore host bridge errors when running standalone
      }
    });

  let appContainer = doc.getElementById('app');
  if (!appContainer) {
    appContainer = doc.createElement('div');
    appContainer.id = 'app';
    doc.body.appendChild(appContainer);
  }

  let editorContainer = doc.getElementById('editor-root');
  if (!editorContainer) {
    editorContainer = doc.createElement('div');
    editorContainer.id = 'editor-root';
    appContainer.appendChild(editorContainer);
  }

  let diffContainer = doc.getElementById('diff-root');
  if (!diffContainer) {
    diffContainer = doc.createElement('div');
    diffContainer.id = 'diff-root';
    diffContainer.style.display = 'none';
    appContainer.appendChild(diffContainer);
  }

  applyOmgTheme(monaco, { base: 'vs-dark' });
  const highlighting = new PierreHighlightingManager(monaco);

  const modelsByUri = new Map();
  const modelMetaByUri = new Map();
  const uriByPath = new Map();
  const viewStatesByUri = new Map();
  const gitDiffLinesByUri = new Map();

  let activeUri = null;
  let mode = 'editor'; // 'editor' | 'diff'
  let diffEditor = null;
  let diffModels = { original: null, modified: null };
  let diffFallbackHunks = [];

  let currentFont = {
    fontFamily: "ui-monospace, 'JetBrains Mono', 'SF Mono', Menlo, monospace",
    fontSize: 13,
    fontLigatures: true,
  };

  const baseEditorOptions = {
    automaticLayout: false,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    smoothScrolling: false,
    cursorBlinking: 'smooth',
    renderLineHighlight: 'all',
    multiCursorModifier: 'alt', // Cmd+Click -> Go to Definition on macOS; Option+Click -> multicursor
    stickyScroll: { enabled: true, maxLineCount: 4 },
    glyphMargin: false,
    folding: true,
    lineNumbersMinChars: 4,
    padding: { top: 8, bottom: 12 },
    unicodeHighlight: {
      ambiguousCharacters: false,
      invisibleCharacters: true,
    },
    bracketPairColorization: { enabled: true },
    guides: {
      indentation: true,
      bracketPairs: false,
    },
    scrollbar: {
      useShadows: false,
      verticalScrollbarSize: 10,
      horizontalScrollbarSize: 10,
    },
    ...currentFont,
  };

  const editor = monaco.editor.create(editorContainer, {
    ...baseEditorOptions,
    model: null,
  });

  const gitGutterDecorations = editor.createDecorationsCollection([]);
  const workbenchDisposables = [];

  function normalizeUriString(uri, path) {
    if (typeof uri === 'string' && uri.length > 0) {
      return monaco.Uri.parse(uri).toString();
    }
    if (typeof path === 'string' && path.length > 0) {
      return monaco.Uri.file(path).toString();
    }
    throw new Error('openOrUpdateModel requires uri or path');
  }

  function resolveUriForPath(targetPath, sourceUri) {
    if (uriByPath.has(targetPath)) {
      return uriByPath.get(targetPath);
    }
    if (sourceUri && sourceUri.scheme && sourceUri.scheme !== 'file') {
      return sourceUri.with({ path: targetPath }).toString();
    }
    return monaco.Uri.file(targetPath).toString();
  }

  function getActiveCodeEditor() {
    if (mode === 'diff' && diffEditor) {
      return diffEditor.getModifiedEditor();
    }
    return editor;
  }

  const askAgent = new AskAgentController({
    monaco,
    container: appContainer,
    getTargetEditor: getActiveCodeEditor,
    getModelMeta: (uri) => modelMetaByUri.get(uri) ?? null,
    postMessage,
  });
  askAgent.attachToEditor(editor);

  const keymaps = new KeymapController({
    monaco,
    postMessage,
    isAskAgentOpen: () => askAgent.isVisible(),
  });
  keymaps.attachEditor(editor);
  keymaps.installGlobalShortcuts(win);

  const lspBridge = new LspBridgeController({
    monaco,
    postMessage,
    getModelMeta: (uri) => modelMetaByUri.get(uri) ?? null,
    resolveUriForPath,
    revealRange: (spec) => revealRange(spec),
  });

  workbenchDisposables.push(
    editor.onDidFocusEditorText(() => {
      postMessage({ type: 'focus' });
    })
  );

  if (typeof ResizeObserver !== 'undefined') {
    const ro = new ResizeObserver(() => {
      if (mode === 'diff' && diffEditor) {
        diffEditor.layout();
      } else {
        editor.layout();
      }
    });
    ro.observe(appContainer);
    workbenchDisposables.push({ dispose: () => ro.disconnect() });
  } else if (win && typeof win.addEventListener === 'function') {
    const onResize = () => {
      if (mode === 'diff' && diffEditor) {
        diffEditor.layout();
      } else {
        editor.layout();
      }
    };
    win.addEventListener('resize', onResize);
    workbenchDisposables.push({ dispose: () => win.removeEventListener('resize', onResize) });
  }

  function applyGitGutterForActiveModel() {
    const currentModel = editor.getModel();
    if (!currentModel || currentModel.isDisposed()) {
      gitGutterDecorations.clear();
      return;
    }
    const uri = currentModel.uri.toString();
    const linesSpec = gitDiffLinesByUri.get(uri);
    if (!linesSpec) {
      gitGutterDecorations.clear();
      return;
    }

    const maxLine = currentModel.getLineCount();
    const decorations = [];
    const entries =
      linesSpec instanceof Map
        ? Array.from(linesSpec.entries())
        : Array.isArray(linesSpec)
          ? linesSpec.map((item) => [item.line ?? item.lineNumber, item.kind ?? item.status])
          : Object.entries(linesSpec);

    for (const [rawLine, kind] of entries) {
      const lineNum = Math.trunc(Number(rawLine));
      if (!Number.isFinite(lineNum) || lineNum < 1 || lineNum > maxLine) continue;
      let className = null;
      if (kind === 'added') className = 'omg-git-gutter-added';
      else if (kind === 'modified') className = 'omg-git-gutter-modified';
      else if (kind === 'deleted') className = 'omg-git-gutter-deleted';
      if (!className) continue;

      decorations.push({
        range: new monaco.Range(lineNum, 1, lineNum, 1),
        options: {
          isWholeLine: true,
          linesDecorationsClassName: className,
        },
      });
    }

    gitGutterDecorations.set(decorations);
  }

  function openOrUpdateModel({
    uri,
    path = '',
    text = '',
    languageHint,
    readOnly = false,
    preserveView = false,
  } = {}) {
    const uriStr = normalizeUriString(uri, path);
    const monacoUri = monaco.Uri.parse(uriStr);
    const resolvedPath = path || monacoUri.path || '';
    const languageId = resolveMonacoLanguageId({ languageHint, path: resolvedPath, uri: uriStr });
    highlighting.ensureLanguageAndProvider(languageId);

    if (resolvedPath) {
      uriByPath.set(resolvedPath, uriStr);
    }

    let model = modelsByUri.get(uriStr) ?? monaco.editor.getModel(monacoUri);
    let meta = modelMetaByUri.get(uriStr);

    if (!model || model.isDisposed()) {
      meta = {
        uri: uriStr,
        path: resolvedPath,
        readOnly: Boolean(readOnly),
        suppressDidChange: true,
        disposables: [],
      };
      modelMetaByUri.set(uriStr, meta);

      try {
        model = monaco.editor.createModel(String(text ?? ''), languageId, monacoUri);
      } finally {
        meta.suppressDidChange = false;
      }

      meta.disposables.push(
        model.onDidChangeContent(() => {
          if (meta.suppressDidChange || model.isDisposed()) return;
          postMessage({
            type: 'didChangeContent',
            uri: uriStr,
            path: meta.path,
            text: model.getValue(),
            versionId: model.getVersionId(),
          });
        })
      );

      modelsByUri.set(uriStr, model);
      return { uri: uriStr, created: true, languageId };
    }

    if (!meta) {
      meta = {
        uri: uriStr,
        path: resolvedPath,
        readOnly: Boolean(readOnly),
        suppressDidChange: false,
        disposables: [],
      };
      modelMetaByUri.set(uriStr, meta);
    } else {
      if (resolvedPath) meta.path = resolvedPath;
      if (readOnly !== undefined) meta.readOnly = Boolean(readOnly);
    }

    if (model.getLanguageId() !== languageId) {
      monaco.editor.setModelLanguage(model, languageId);
    }

    if (activeUri === uriStr && readOnly !== undefined) {
      editor.updateOptions({ readOnly: Boolean(readOnly) });
    }

    if (typeof text === 'string' && model.getValue() !== text) {
      const isActive = mode === 'editor' && editor.getModel() === model;
      const savedSelections = isActive ? editor.getSelections() : null;
      const savedScrollTop = isActive ? editor.getScrollTop() : null;
      const savedScrollLeft = isActive ? editor.getScrollLeft() : null;

      meta.suppressDidChange = true;
      try {
        if (preserveView) {
          const oldText = model.getValue();
          const minimalEdit = computeMinimalTextEdit(model, oldText, text, monaco);
          model.pushStackElement();
          model.pushEditOperations(
            savedSelections ?? [],
            [minimalEdit],
            () => savedSelections
          );
          model.pushStackElement();

          if (isActive && savedSelections && savedSelections.length > 0) {
            const clamped = savedSelections.map((sel) => model.validateRange(sel));
            editor.setSelections(
              clamped.map(
                (r) =>
                  new monaco.Selection(
                    r.startLineNumber,
                    r.startColumn,
                    r.endLineNumber,
                    r.endColumn
                  )
              )
            );
            if (savedScrollTop !== null) {
              editor.setScrollTop(savedScrollTop, monaco.editor.ScrollType.Immediate);
            }
            if (savedScrollLeft !== null) {
              editor.setScrollLeft(savedScrollLeft, monaco.editor.ScrollType.Immediate);
            }
          }
        } else {
          model.setValue(text);
        }
      } finally {
        meta.suppressDidChange = false;
      }

      if (isActive) {
        applyGitGutterForActiveModel();
      }
    }

    return { uri: uriStr, created: false, languageId };
  }

  function activateModel({
    uri,
    readOnly,
    wordWrap,
    tabSize,
    insertSpaces,
    keymapProfile,
  } = {}) {
    const uriStr = normalizeUriString(uri, '');
    const targetModel = modelsByUri.get(uriStr) ?? monaco.editor.getModel(monaco.Uri.parse(uriStr));
    if (!targetModel || targetModel.isDisposed()) {
      return false;
    }

    askAgent.hidePrompt(false);

    if (mode === 'diff') {
      diffContainer.style.display = 'none';
      editorContainer.style.display = 'block';
      mode = 'editor';
    }

    const currentModel = editor.getModel();
    if (currentModel && !currentModel.isDisposed()) {
      const currentUriStr = currentModel.uri.toString();
      if (currentUriStr !== uriStr) {
        const state = editor.saveViewState();
        if (state) {
          viewStatesByUri.set(currentUriStr, state);
        }
      }
    }

    if (keymapProfile) {
      keymaps.setProfile(keymapProfile);
    }

    const modelOpts = {};
    if (typeof tabSize === 'number' && tabSize > 0) modelOpts.tabSize = tabSize;
    if (typeof insertSpaces === 'boolean') modelOpts.insertSpaces = insertSpaces;
    if (Object.keys(modelOpts).length > 0) {
      targetModel.updateOptions(modelOpts);
    }

    const meta = modelMetaByUri.get(uriStr);
    const effectiveReadOnly =
      readOnly !== undefined ? Boolean(readOnly) : Boolean(meta?.readOnly);
    if (meta && readOnly !== undefined) {
      meta.readOnly = effectiveReadOnly;
    }

    if (editor.getModel() !== targetModel) {
      editor.setModel(targetModel);
    }
    activeUri = uriStr;

    const editorOpts = {
      readOnly: effectiveReadOnly,
    };
    if (wordWrap !== undefined) {
      editorOpts.wordWrap = normalizeWordWrap(wordWrap);
    }
    editor.updateOptions(editorOpts);

    const savedViewState = viewStatesByUri.get(uriStr);
    if (savedViewState) {
      editor.restoreViewState(savedViewState);
    }

    applyGitGutterForActiveModel();
    editor.layout();
    return true;
  }

  function closeModel({ uri } = {}) {
    if (!uri) return false;
    const uriStr = normalizeUriString(uri, '');
    const model = modelsByUri.get(uriStr) ?? monaco.editor.getModel(monaco.Uri.parse(uriStr));
    const meta = modelMetaByUri.get(uriStr);

    if (editor.getModel() === model) {
      editor.setModel(null);
      gitGutterDecorations.clear();
      activeUri = null;
    }

    viewStatesByUri.delete(uriStr);
    gitDiffLinesByUri.delete(uriStr);
    modelsByUri.delete(uriStr);
    modelMetaByUri.delete(uriStr);

    if (meta) {
      if (meta.path && uriByPath.get(meta.path) === uriStr) {
        uriByPath.delete(meta.path);
      }
      for (const d of meta.disposables) {
        d.dispose();
      }
      meta.disposables.length = 0;
    }

    if (model && !model.isDisposed()) {
      monaco.editor.setModelMarkers(model, 'omg-intelligence', []);
      model.dispose();
    }
    return true;
  }

  function revealRange({
    uri,
    startLine = 1,
    startColumn = 1,
    endLine,
    endColumn,
  } = {}) {
    if (uri) {
      const uriStr = normalizeUriString(uri, '');
      if (mode === 'diff' || editor.getModel()?.uri.toString() !== uriStr) {
        if (modelsByUri.has(uriStr)) {
          activateModel({ uri: uriStr });
        }
      }
    }

    const targetEditor = getActiveCodeEditor();
    const model = targetEditor?.getModel?.();
    if (!targetEditor || !model || model.isDisposed()) {
      return false;
    }

    const sLine = Math.max(1, Math.min(model.getLineCount(), Number(startLine) || 1));
    const sCol = Math.max(1, Math.min(model.getLineMaxColumn(sLine), Number(startColumn) || 1));
    const rawELine = endLine !== undefined ? Number(endLine) : sLine;
    const eLine = Math.max(sLine, Math.min(model.getLineCount(), rawELine || sLine));
    const rawECol = endColumn !== undefined ? Number(endColumn) : sCol;
    const eCol = Math.max(1, Math.min(model.getLineMaxColumn(eLine), rawECol || sCol));

    const range = new monaco.Range(sLine, sCol, eLine, eCol);
    targetEditor.setSelection(range);
    targetEditor.revealRangeInCenter(range, monaco.editor.ScrollType.Immediate);
    return true;
  }

  function disposeDiffModels() {
    if (diffEditor) {
      diffEditor.setModel(null);
    }
    if (diffModels.original && !diffModels.original.isDisposed()) {
      diffModels.original.dispose();
    }
    if (diffModels.modified && !diffModels.modified.isDisposed()) {
      diffModels.modified.dispose();
    }
    diffModels = { original: null, modified: null };
    diffFallbackHunks = [];
  }

  function ensureDiffEditor() {
    if (diffEditor) return diffEditor;
    diffEditor = monaco.editor.createDiffEditor(diffContainer, {
      ...baseEditorOptions,
      renderSideBySide: true,
      useInlineViewWhenSpaceIsLimited: false,
      ignoreTrimWhitespace: false,
      renderIndicators: true,
      originalEditable: false,
      readOnly: true,
      hideUnchangedRegions: {
        enabled: true,
        revealLineCount: 3,
        minimumLineCount: 3,
        contextLineCount: 3,
      },
    });
    const modEd = diffEditor.getModifiedEditor();
    const origEd = diffEditor.getOriginalEditor();
    askAgent.attachToEditor(modEd);
    keymaps.attachEditor(modEd);
    keymaps.attachEditor(origEd);
    workbenchDisposables.push(
      modEd.onDidFocusEditorText(() => postMessage({ type: 'focus' })),
      origEd.onDidFocusEditorText(() => postMessage({ type: 'focus' }))
    );
    return diffEditor;
  }

  function activateDiff({
    id = 'default',
    path = '',
    originalText = '',
    modifiedText = '',
    inline = false,
    wordWrap = false,
    readOnly = true,
    languageHint,
  } = {}) {
    askAgent.hidePrompt(false);

    if (mode === 'editor') {
      const currentModel = editor.getModel();
      if (currentModel && !currentModel.isDisposed()) {
        const state = editor.saveViewState();
        if (state) {
          viewStatesByUri.set(currentModel.uri.toString(), state);
        }
      }
      editorContainer.style.display = 'none';
      diffContainer.style.display = 'block';
      mode = 'diff';
    }

    const de = ensureDiffEditor();
    disposeDiffModels();

    const languageId = resolveMonacoLanguageId({ languageHint, path });
    highlighting.ensureLanguageAndProvider(languageId);

    const safeId = encodeURIComponent(String(id));
    const safePath = path.startsWith('/') ? path : `/${path}`;
    const origUri = monaco.Uri.parse(`omg-diff://original/${safeId}${safePath}`);
    const modUri = monaco.Uri.parse(`omg-diff://modified/${safeId}${safePath}`);

    modelMetaByUri.set(modUri.toString(), {
      uri: modUri.toString(),
      path,
      readOnly: Boolean(readOnly),
      suppressDidChange: true,
      disposables: [],
    });

    const originalModel = monaco.editor.createModel(String(originalText ?? ''), languageId, origUri);
    const modifiedModel = monaco.editor.createModel(String(modifiedText ?? ''), languageId, modUri);
    diffModels = { original: originalModel, modified: modifiedModel };
    diffFallbackHunks = computeFallbackDiffHunks(
      String(originalText ?? ''),
      String(modifiedText ?? '')
    );

    const wrapMode = normalizeWordWrap(wordWrap, 'off');
    de.updateOptions({
      renderSideBySide: !inline,
      diffWordWrap: wrapMode,
      wordWrap: wrapMode,
      readOnly: Boolean(readOnly),
      hideUnchangedRegions: {
        enabled: true,
        revealLineCount: 3,
        minimumLineCount: 3,
        contextLineCount: 3,
      },
      ...currentFont,
    });

    de.setModel({
      original: originalModel,
      modified: modifiedModel,
    });
    de.layout();
    return true;
  }

  function navigateDiff({ direction = 'next' } = {}) {
    if (mode !== 'diff' || !diffEditor) return false;
    const isPrev = direction === 'prev' || direction === 'previous';
    const modEditor = diffEditor.getModifiedEditor();
    const model = modEditor.getModel();
    if (!model || model.isDisposed()) return false;

    const lineChanges = diffEditor.getLineChanges();
    if (Array.isArray(lineChanges) && lineChanges.length > 0) {
      diffEditor.goToDiff(isPrev ? 'previous' : 'next');
      return true;
    }

    // Immediate deterministic fallback before background diff worker completes
    if (diffFallbackHunks.length === 0) return false;
    const curLine = modEditor.getPosition()?.lineNumber ?? 1;
    let targetLine;
    if (isPrev) {
      const earlier = diffFallbackHunks.filter((l) => l < curLine);
      targetLine =
        earlier.length > 0
          ? earlier[earlier.length - 1]
          : diffFallbackHunks[diffFallbackHunks.length - 1];
    } else {
      const later = diffFallbackHunks.filter((l) => l > curLine);
      targetLine = later.length > 0 ? later[0] : diffFallbackHunks[0];
    }

    const clampedLine = Math.max(1, Math.min(model.getLineCount(), targetLine));
    const range = new monaco.Range(clampedLine, 1, clampedLine, 1);
    modEditor.setSelection(range);
    modEditor.revealRangeInCenter(range, monaco.editor.ScrollType.Immediate);
    return true;
  }

  function setTheme(themeSpec = {}) {
    return applyOmgTheme(monaco, themeSpec);
  }

  function setFont({ family, size, ligatures } = {}) {
    if (typeof family === 'string' && family.trim().length > 0) {
      currentFont.fontFamily = family;
    }
    if (typeof size === 'number' && Number.isFinite(size) && size > 0) {
      currentFont.fontSize = size;
    }
    if (typeof ligatures === 'boolean') {
      currentFont.fontLigatures = ligatures;
    }
    editor.updateOptions({ ...currentFont });
    if (diffEditor) {
      diffEditor.updateOptions({ ...currentFont });
    }
    monaco.editor.remeasureFonts();
    return { ...currentFont };
  }

  function setGitDiffLines({ uri, lines = {} } = {}) {
    if (!uri) return false;
    const uriStr = normalizeUriString(uri, '');
    gitDiffLinesByUri.set(uriStr, lines ?? {});
    if (mode === 'editor' && editor.getModel()?.uri.toString() === uriStr) {
      applyGitGutterForActiveModel();
    }
    return true;
  }

  function setDiagnostics({ uri, markers = [] } = {}) {
    if (!uri) return false;
    const uriStr = normalizeUriString(uri, '');
    const model = modelsByUri.get(uriStr) ?? monaco.editor.getModel(monaco.Uri.parse(uriStr));
    if (!model || model.isDisposed()) return false;

    const normalizedMarkers = (Array.isArray(markers) ? markers : []).map((m) => {
      const range = extractNormalizedRange(monaco, m);
      return {
        startLineNumber: range.startLineNumber,
        startColumn: range.startColumn,
        endLineNumber: range.endLineNumber,
        endColumn: range.endColumn,
        message: String(m.message ?? ''),
        severity: normalizeMarkerSeverity(monaco, m.monacoSeverity ?? m.severity),
        source: m.source ? String(m.source) : undefined,
        code: m.code !== undefined ? String(m.code) : undefined,
      };
    });

    monaco.editor.setModelMarkers(model, 'omg-intelligence', normalizedMarkers);
    return normalizedMarkers.length;
  }

  const ACTION_MAP = {
    find: 'actions.find',
    replace: 'editor.action.startFindReplaceAction',
    goToLine: 'editor.action.gotoLine',
    findNext: 'editor.action.nextMatchFindAction',
    findPrev: 'editor.action.previousMatchFindAction',
    findPrevious: 'editor.action.previousMatchFindAction',
    documentSymbols: 'editor.action.quickOutline',
    foldAll: 'editor.foldAll',
    unfoldAll: 'editor.unfoldAll',
    quickCommand: 'editor.action.quickCommand',
  };

  function performAction({ action } = {}) {
    if (!action) return false;
    if (action === 'askAgent') {
      return askAgent.openPromptForEditor();
    }
    const monacoActionId = ACTION_MAP[action];
    if (!monacoActionId) return false;

    const targetEditor = getActiveCodeEditor();
    if (!targetEditor) return false;

    targetEditor.focus();
    const registeredAction = targetEditor.getAction(monacoActionId);
    if (registeredAction) {
      Promise.resolve(registeredAction.run()).catch(() => {});
      return true;
    }
    targetEditor.trigger('omg', monacoActionId, null);
    return true;
  }

  function resolveRequest(requestId, payload) {
    return lspBridge.resolveRequest(requestId, payload);
  }

  function dispose() {
    askAgent.dispose();
    keymaps.dispose();
    lspBridge.dispose();
    disposeDiffModels();
    if (diffEditor) {
      diffEditor.dispose();
      diffEditor = null;
    }
    for (const uriStr of Array.from(modelsByUri.keys())) {
      closeModel({ uri: uriStr });
    }
    highlighting.dispose();
    editor.dispose();
    for (const d of workbenchDisposables) {
      d?.dispose?.();
    }
    workbenchDisposables.length = 0;
  }

  const api = {
    openOrUpdateModel,
    activateModel,
    closeModel,
    revealRange,
    activateDiff,
    navigateDiff,
    setTheme,
    setFont,
    setGitDiffLines,
    setDiagnostics,
    performAction,
    resolveRequest,
    askAgent: (opts) => askAgent.triggerAskAgent(opts),
    dispose,
    constants: {
      MAX_LINE_LENGTH,
      MAX_MODEL_LINES,
    },
    // Introspection helpers for tests and host debugging
    getState: () => ({
      mode,
      activeUri,
      openUris: Array.from(modelsByUri.keys()),
      keymapProfile: keymaps.getProfile(),
      isAskAgentOpen: askAgent.isVisible(),
      gitGutterCount: gitGutterDecorations.length,
    }),
    _internal: {
      monaco,
      editor,
      getDiffEditor: () => diffEditor,
      highlighting,
      askAgent,
      keymaps,
      lspBridge,
    },
  };

  if (win) {
    win.omgEditor = api;
  }

  postMessage({ type: 'ready' });
  return api;
}
