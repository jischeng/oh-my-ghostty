const REQUEST_TIMEOUT_MS = 15_000;

const STRING_TO_MONACO_SYMBOL_KIND = {
  file: 0,
  module: 1,
  namespace: 2,
  package: 3,
  class: 4,
  method: 5,
  property: 6,
  field: 7,
  constructor: 8,
  enum: 9,
  interface: 10,
  protocol: 10,
  trait: 10,
  function: 11,
  func: 11,
  fn: 11,
  def: 11,
  variable: 12,
  var: 12,
  let: 12,
  constant: 13,
  const: 13,
  string: 14,
  heading: 14,
  number: 15,
  boolean: 16,
  array: 17,
  object: 18,
  key: 19,
  null: 20,
  enummember: 21,
  case: 21,
  struct: 22,
  impl: 22,
  event: 23,
  operator: 24,
  typeparameter: 25,
  type: 25,
};

const STRING_TO_COMPLETION_KIND = {
  method: 0,
  function: 1,
  constructor: 2,
  field: 3,
  variable: 4,
  class: 5,
  struct: 6,
  interface: 7,
  module: 8,
  property: 9,
  event: 10,
  operator: 11,
  unit: 12,
  value: 13,
  constant: 14,
  enum: 15,
  enummember: 16,
  keyword: 17,
  text: 18,
  color: 19,
  file: 20,
  reference: 21,
  customcolor: 22,
  folder: 23,
  typeparameter: 24,
  user: 25,
  issue: 26,
  snippet: 27,
};

function normalizeSymbolKind(kind) {
  if (typeof kind === 'string') {
    const mapped = STRING_TO_MONACO_SYMBOL_KIND[kind.toLowerCase()];
    return mapped ?? 11;
  }
  if (typeof kind === 'number' && Number.isFinite(kind)) {
    // LSP SymbolKind is 1..26; Monaco SymbolKind is 0..25.
    if (kind >= 1 && kind <= 26) return kind - 1;
    if (kind >= 0 && kind <= 25) return kind;
  }
  return 11;
}

function normalizeCompletionKind(kind) {
  if (typeof kind === 'string') {
    return STRING_TO_COMPLETION_KIND[kind.toLowerCase()] ?? 18;
  }
  if (typeof kind === 'number' && Number.isFinite(kind)) {
    // LSP CompletionItemKind is 1..25; Monaco is 0-based (though order differs slightly, clamp safely).
    if (kind >= 0 && kind <= 27) return kind;
  }
  return 18;
}

export function extractNormalizedRange(monaco, item, fallbackPos = { lineNumber: 1, column: 1 }) {
  if (!item || typeof item !== 'object') {
    return new monaco.Range(
      fallbackPos.lineNumber,
      fallbackPos.column,
      fallbackPos.lineNumber,
      fallbackPos.column
    );
  }
  if (item.range && typeof item.range === 'object') {
    const r = item.range;
    if (r.start && r.end) {
      const sl = Math.max(1, Number(r.start.line ?? r.start.lineNumber ?? fallbackPos.lineNumber));
      const sc = Math.max(1, Number(r.start.column ?? r.start.character ?? fallbackPos.column));
      const el = Math.max(sl, Number(r.end.line ?? r.end.lineNumber ?? sl));
      const ec = Math.max(1, Number(r.end.column ?? r.end.character ?? sc));
      return new monaco.Range(sl, sc, el, ec);
    }
    if (r.startLineNumber !== undefined || r.startLine !== undefined) {
      const sl = Math.max(1, Number(r.startLineNumber ?? r.startLine ?? fallbackPos.lineNumber));
      const sc = Math.max(1, Number(r.startColumn ?? fallbackPos.column));
      const el = Math.max(sl, Number(r.endLineNumber ?? r.endLine ?? sl));
      const ec = Math.max(1, Number(r.endColumn ?? sc));
      return new monaco.Range(sl, sc, el, ec);
    }
  }
  const sl = Math.max(1, Number(item.startLine ?? item.startLineNumber ?? item.line ?? fallbackPos.lineNumber));
  const sc = Math.max(1, Number(item.startColumn ?? item.column ?? fallbackPos.column));
  const el = Math.max(sl, Number(item.endLine ?? item.endLineNumber ?? sl));
  const ec = Math.max(1, Number(item.endColumn ?? sc));
  return new monaco.Range(sl, sc, el, ec);
}

export class LspBridgeController {
  constructor({ monaco, postMessage, getModelMeta, resolveUriForPath, revealRange }) {
    this.monaco = monaco;
    this.postMessage = postMessage;
    this.getModelMeta = getModelMeta;
    this.resolveUriForPath = resolveUriForPath;
    this.revealRange = revealRange;
    this.pendingRequests = new Map();
    this.knownPathsByUri = new Map();
    this.cachedLocationTargets = new Map();
    this.nextRequestNum = 1;
    this.disposables = [];

    this.registerProviders();
  }

  sendLspRequest({ method, model, position, triggerCharacter }, cancellationToken) {
    if (!model || model.isDisposed()) {
      return Promise.resolve(null);
    }
    const uri = model.uri.toString();
    const meta = this.getModelMeta(uri);
    const path = meta?.path ?? model.uri.path ?? '';
    const requestId = `lsp-${this.nextRequestNum++}`;

    return new Promise((resolve) => {
      let cancelDisposable = null;
      const timer = setTimeout(() => {
        this.pendingRequests.delete(requestId);
        cancelDisposable?.dispose?.();
        resolve(null);
      }, REQUEST_TIMEOUT_MS);
      if (typeof timer?.unref === 'function') {
        timer.unref();
      }

      if (cancellationToken && typeof cancellationToken.onCancellationRequested === 'function') {
        cancelDisposable = cancellationToken.onCancellationRequested(() => {
          const entry = this.pendingRequests.get(requestId);
          if (entry) {
            clearTimeout(entry.timer);
            this.pendingRequests.delete(requestId);
          }
          cancelDisposable?.dispose?.();
          resolve(null);
        });
      }

      this.pendingRequests.set(requestId, {
        resolve: (payload) => {
          clearTimeout(timer);
          cancelDisposable?.dispose?.();
          resolve(payload);
        },
        timer,
      });

      const message = {
        type: 'lspRequest',
        requestId,
        method,
        uri,
        path,
        line: position?.lineNumber ?? 1,
        column: position?.column ?? 1,
      };
      if (triggerCharacter !== undefined) {
        message.triggerCharacter = triggerCharacter;
      }
      this.postMessage(message);
    });
  }

  resolveRequest(requestId, payload) {
    const pending = this.pendingRequests.get(requestId);
    if (!pending) return false;
    this.pendingRequests.delete(requestId);
    pending.resolve(payload);
    return true;
  }

  normalizeLocationItem(item, sourceModel) {
    if (!item || typeof item !== 'object') return null;
    const range = extractNormalizedRange(this.monaco, item);
    let targetUriObj;
    let targetPath = item.path ?? '';

    if (typeof item.uri === 'string' && item.uri.length > 0) {
      targetUriObj = this.monaco.Uri.parse(item.uri);
      if (!targetPath) {
        targetPath = this.getModelMeta(item.uri)?.path ?? targetUriObj.path;
      }
    } else if (targetPath) {
      const resolvedStr = this.resolveUriForPath(targetPath, sourceModel?.uri);
      targetUriObj = this.monaco.Uri.parse(resolvedStr);
    } else if (sourceModel) {
      targetUriObj = sourceModel.uri;
      targetPath = this.getModelMeta(sourceModel.uri.toString())?.path ?? sourceModel.uri.path;
    } else {
      return null;
    }

    const uriStr = targetUriObj.toString();
    if (targetPath) {
      this.knownPathsByUri.set(uriStr, targetPath);
    }

    const targetRecord = {
      uri: uriStr,
      path: targetPath,
      startLine: range.startLineNumber,
      startColumn: range.startColumn,
      endLine: range.endLineNumber,
      endColumn: range.endColumn,
    };
    this.cachedLocationTargets.set(
      `${uriStr}:${range.startLineNumber}:${range.startColumn}`,
      targetRecord
    );

    return {
      uri: targetUriObj,
      range,
      targetRecord,
    };
  }

  registerProviders() {
    const { monaco } = this;
    this.providers = {};

    // 1. CompletionItemProvider
    const completionProvider = {
      triggerCharacters: ['.', ':', '/', '@', '<', '"', "'"],
      provideCompletionItems: async (model, position, context, token) => {
        const res = await this.sendLspRequest(
          {
            method: 'completion',
            model,
            position,
            triggerCharacter: context?.triggerCharacter ?? null,
          },
          token
        );
        if (!res) return { suggestions: [] };
        const rawList = Array.isArray(res)
          ? res
          : Array.isArray(res.items)
            ? res.items
            : Array.isArray(res.suggestions)
              ? res.suggestions
              : [];
        const word = model.getWordUntilPosition(position);
        const defaultRange = new monaco.Range(
          position.lineNumber,
          word.startColumn,
          position.lineNumber,
          word.endColumn
        );

        const suggestions = rawList
          .filter((item) => item && typeof item.label === 'string')
          .map((item, idx) => ({
            label: item.label,
            kind:
              typeof item.monacoKind === 'number'
                ? item.monacoKind
                : normalizeCompletionKind(item.kind),
            detail: item.detail ?? undefined,
            documentation:
              typeof item.documentation === 'string'
                ? { value: item.documentation }
                : item.documentation ?? undefined,
            insertText: item.insertText ?? item.label,
            insertTextRules: item.isSnippet
              ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
              : undefined,
            sortText: item.sortText ?? String(idx).padStart(4, '0'),
            filterText: item.filterText ?? undefined,
            range: item.range || item.startLine ? extractNormalizedRange(monaco, item, position) : defaultRange,
          }));

        return {
          incomplete: Boolean(res.isIncomplete ?? res.incomplete),
          suggestions,
        };
      },
    };
    this.providers.completion = completionProvider;
    this.disposables.push(monaco.languages.registerCompletionItemProvider('*', completionProvider));

    // 2. HoverProvider
    const hoverProvider = {
      provideHover: async (model, position, token) => {
        const res = await this.sendLspRequest({ method: 'hover', model, position }, token);
        if (!res) return null;
        if (typeof res === 'string') {
          return res.trim() ? { contents: [{ value: res }] } : null;
        }
        const markdown =
          typeof res.markdown === 'string'
            ? res.markdown
            : typeof res.contents === 'string'
              ? res.contents
              : Array.isArray(res.contents)
                ? res.contents
                    .map((c) => (typeof c === 'string' ? c : c?.value ?? ''))
                    .filter(Boolean)
                    .join('\n\n')
                : '';
        if (!markdown.trim()) return null;
        const hover = {
          contents: [{ value: markdown }],
        };
        if (res.range || res.startLine !== undefined) {
          hover.range = extractNormalizedRange(monaco, res, position);
        }
        return hover;
      },
    };
    this.providers.hover = hoverProvider;
    this.disposables.push(monaco.languages.registerHoverProvider('*', hoverProvider));

    // 3. DefinitionProvider (powers Cmd+Click & F12)
    const definitionProvider = {
      provideDefinition: async (model, position, token) => {
        const res = await this.sendLspRequest({ method: 'definition', model, position }, token);
        if (!res) return null;
        const items = Array.isArray(res) ? res : [res];
        const locations = items
          .map((item) => this.normalizeLocationItem(item, model))
          .filter(Boolean)
          .map(({ uri, range }) => ({ uri, range }));
        return locations.length > 0 ? locations : null;
      },
    };
    this.providers.definition = definitionProvider;
    this.disposables.push(monaco.languages.registerDefinitionProvider('*', definitionProvider));

    // 4. ReferenceProvider (Shift+F12 / Find References)
    const referenceProvider = {
      provideReferences: async (model, position, _context, token) => {
        const res = await this.sendLspRequest({ method: 'references', model, position }, token);
        if (!res) return [];
        const items = Array.isArray(res) ? res : res.items ?? [];
        return items
          .map((item) => this.normalizeLocationItem(item, model))
          .filter(Boolean)
          .map(({ uri, range }) => ({ uri, range }));
      },
    };
    this.providers.references = referenceProvider;
    this.disposables.push(monaco.languages.registerReferenceProvider('*', referenceProvider));

    // 5. DocumentSymbolProvider (Cmd+Shift+O Go to Symbol in Editor & Sticky Scroll)
    const mapDocSymbol = (sym) => {
      if (!sym || typeof sym.name !== 'string') return null;
      const range = extractNormalizedRange(monaco, sym);
      const selectionRange = sym.selectionRange
        ? extractNormalizedRange(monaco, { range: sym.selectionRange })
        : range;
      const mapped = {
        name: sym.name,
        detail: sym.detail ?? '',
        kind:
          typeof sym.monacoKind === 'number'
            ? sym.monacoKind
            : normalizeSymbolKind(sym.kind),
        tags: [],
        range,
        selectionRange,
      };
      if (Array.isArray(sym.children) && sym.children.length > 0) {
        mapped.children = sym.children.map(mapDocSymbol).filter(Boolean);
      }
      return mapped;
    };

    const documentSymbolProvider = {
      provideDocumentSymbols: async (model, token) => {
        const res = await this.sendLspRequest(
          { method: 'documentSymbol', model, position: { lineNumber: 1, column: 1 } },
          token
        );
        if (!res) return [];
        const items = Array.isArray(res) ? res : res.symbols ?? res.items ?? [];
        return items.map(mapDocSymbol).filter(Boolean);
      },
    };
    this.providers.documentSymbol = documentSymbolProvider;
    this.disposables.push(monaco.languages.registerDocumentSymbolProvider('*', documentSymbolProvider));

    // 6. Editor Opener (intercepts Cmd+Click / F12 / Reference jump for both same-file and cross-file!)
    this.disposables.push(
      monaco.editor.registerEditorOpener({
        openCodeEditor: (source, resource, selectionOrPosition) => {
          if (!resource) return false;
          const uriStr = resource.toString();
          const startLine = Math.max(
            1,
            Number(
              selectionOrPosition?.startLineNumber ??
                selectionOrPosition?.lineNumber ??
                1
            )
          );
          const startColumn = Math.max(
            1,
            Number(selectionOrPosition?.startColumn ?? selectionOrPosition?.column ?? 1)
          );
          const cached = this.cachedLocationTargets.get(`${uriStr}:${startLine}:${startColumn}`);
          const endLine = Math.max(
            startLine,
            Number(
              selectionOrPosition?.endLineNumber &&
                (selectionOrPosition.endLineNumber !== startLine ||
                  selectionOrPosition.endColumn !== startColumn)
                ? selectionOrPosition.endLineNumber
                : (cached?.endLine ?? startLine)
            )
          );
          const endColumn = Math.max(
            1,
            Number(
              selectionOrPosition?.endColumn &&
                (selectionOrPosition.endLineNumber !== startLine ||
                  selectionOrPosition.endColumn !== startColumn)
                ? selectionOrPosition.endColumn
                : (cached?.endColumn ?? startColumn)
            )
          );
          const path =
            this.getModelMeta(uriStr)?.path ??
            cached?.path ??
            this.knownPathsByUri.get(uriStr) ??
            resource.path ??
            '';

          const target = {
            uri: uriStr,
            path,
            startLine,
            startColumn,
            endLine,
            endColumn,
          };

          this.postMessage({
            type: 'navigateDefinition',
            target,
          });

          if (source?.getModel()?.uri.toString() === uriStr) {
            this.revealRange(target);
          }
          return true;
        },
      })
    );

    // 7. Link Opener (delegates URL / file links safely to Swift host)
    const linkOpener = {
      open: (resource) => {
        if (!resource) return false;
        this.postMessage({
          type: 'openLink',
          href: resource.toString(true),
        });
        return true;
      },
    };
    this.providers.linkOpener = linkOpener;
    this.disposables.push(monaco.editor.registerLinkOpener(linkOpener));
  }

  dispose() {
    for (const [, pending] of this.pendingRequests) {
      clearTimeout(pending.timer);
      pending.resolve(null);
    }
    this.pendingRequests.clear();
    for (const d of this.disposables) {
      d.dispose();
    }
    this.disposables.length = 0;
  }
}
