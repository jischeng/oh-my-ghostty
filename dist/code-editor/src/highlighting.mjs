import { LiveTokenizer, tokenNames } from '@pierre/highlights';
import {
  ensureMonacoLanguageRegistered,
  getPierreLanguageForMonacoId,
  registerCoreLanguages,
} from './languages.mjs';

export const MAX_LINE_LENGTH = 20_000;
export const MAX_MODEL_LINES = 300_000;

const DUMMY_PIERRE_THEME = {
  name: 'omg-live',
  appearance: 'dark',
  style: {},
};

const INITIAL_SYNC_RENDER_LINES = 600;

function mapPierreTokenNameToScope(name) {
  if (!name || name === 'none' || name === 'primary' || name === 'text.jsx' || name === 'background' || name === 'foreground') {
    return '';
  }
  if (name === 'comment' || name === 'comment.doc' || name === 'predictive' || name === 'hint') {
    return 'comment';
  }
  if (name.startsWith('keyword') || name === 'preproc') {
    return 'keyword';
  }
  if (name.startsWith('function')) {
    return 'function';
  }
  if (
    name.startsWith('type') ||
    name === 'constructor' ||
    name === 'enum' ||
    name === 'namespace' ||
    name === 'label' ||
    name === 'tag.component.jsx'
  ) {
    return 'type';
  }
  if (name === 'string.regex') {
    return 'regexp';
  }
  if (name === 'string.escape') {
    return 'string.escape';
  }
  if (name.startsWith('string') || name === 'text.literal' || name === 'link_text' || name === 'link_uri') {
    return 'string';
  }
  if (name === 'number') {
    return 'number';
  }
  if (name === 'boolean' || name.startsWith('constant') || name === 'variant') {
    return 'constant';
  }
  if (name === 'property' || name === 'property.json_key') {
    return 'variable.property';
  }
  if (name.startsWith('variable') || name === 'embedded') {
    return 'variable';
  }
  if (name.startsWith('attribute') || name.startsWith('tag') || name.startsWith('selector')) {
    return 'attribute';
  }
  if (name === 'operator') {
    return 'operator';
  }
  if (name.startsWith('punctuation')) {
    return 'delimiter';
  }
  if (name === 'emphasis') {
    return 'emphasis';
  }
  if (name === 'emphasis.strong' || name === 'title') {
    return 'strong';
  }
  if (name === 'diff.plus') {
    return 'inserted';
  }
  if (name === 'diff.minus') {
    return 'deleted';
  }
  return '';
}

export const TOKEN_ID_TO_SCOPE = tokenNames.map(mapPierreTokenNameToScope);

export function decodePacked24Records(records, lineLength) {
  if (!records || !records.data || records.data.length === 0 || lineLength <= 0 || lineLength > MAX_LINE_LENGTH) {
    return [];
  }
  const { data, format } = records;
  const wide = format === 'wide32';
  const stride = wide ? 2 : 1;
  const tokens = [];
  let start = 0;
  let lastScope = null;

  for (let i = 0; i < data.length; i += stride) {
    const word = data[i];
    const rawEnd = wide ? word : (word & 0x00ffffff);
    const tokenId = wide ? data[i + 1] : (word >>> 24);
    const end = rawEnd > lineLength ? lineLength : rawEnd;
    if (end <= start) continue;

    const scopes = TOKEN_ID_TO_SCOPE[tokenId] ?? '';
    if (tokens.length === 0 && start > 0) {
      tokens.push({ startIndex: 0, scopes: '' });
      lastScope = '';
    }
    if (scopes !== lastScope) {
      tokens.push({ startIndex: start, scopes });
      lastScope = scopes;
    }
    start = end;
    if (start >= lineLength) break;
  }

  if (tokens.length === 0 && lineLength > 0) {
    tokens.push({ startIndex: 0, scopes: '' });
  }
  return tokens;
}

function hashRecordsData(data) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < data.length; i++) {
    hash ^= data[i];
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

class PierreLineState {
  constructor(lineIndex, candidateIds, nextLineHash) {
    this.lineIndex = lineIndex;
    this.candidateIds = candidateIds;
    this.nextLineHash = nextLineHash;
  }

  clone() {
    return new PierreLineState(
      this.lineIndex,
      this.candidateIds ? this.candidateIds.slice() : null,
      this.nextLineHash
    );
  }

  equals(other) {
    if (!(other instanceof PierreLineState)) return false;
    if (this.lineIndex !== other.lineIndex || this.nextLineHash !== other.nextLineHash) {
      return false;
    }
    const a = this.candidateIds;
    const b = other.candidateIds;
    if (a === b) return true;
    if (!a || !b || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }
}

export class PierreHighlightingManager {
  constructor(monaco) {
    this.monaco = monaco;
    this.registeredLanguages = registerCoreLanguages(monaco);
    this.providersRegistered = new Set();
    this.entriesByModel = new Map();
    this.entriesById = new Map();
    this.entriesByLanguage = new Map();
    this.disposables = [];
    this.nextEntryId = 1;

    for (const langId of this.registeredLanguages) {
      this.ensureTokensProvider(langId);
    }

    this.disposables.push(
      monaco.editor.onDidCreateModel((model) => {
        this.attachModel(model);
      }),
      monaco.editor.onDidChangeModelLanguage((event) => {
        this.detachModel(event.model);
        this.attachModel(event.model);
      })
    );

    for (const model of monaco.editor.getModels()) {
      this.attachModel(model);
    }
  }

  ensureLanguageAndProvider(monacoId) {
    if (!monacoId || monacoId === 'plaintext') return;
    ensureMonacoLanguageRegistered(this.monaco, monacoId, this.registeredLanguages);
    this.ensureTokensProvider(monacoId);
  }

  ensureTokensProvider(monacoId) {
    if (!monacoId || monacoId === 'plaintext' || this.providersRegistered.has(monacoId)) {
      return;
    }
    const pierreLang = getPierreLanguageForMonacoId(monacoId);
    if (!pierreLang) return;

    this.providersRegistered.add(monacoId);
    const disposable = this.monaco.languages.setTokensProvider(monacoId, {
      getInitialState: () => new PierreLineState(0, null, 0),
      tokenize: (line, state) => this.tokenizeLine(monacoId, pierreLang, line, state),
    });
    this.disposables.push(disposable);
  }

  attachModel(model) {
    if (!model || model.isDisposed() || this.entriesByModel.has(model)) {
      return;
    }
    const monacoId = model.getLanguageId();
    this.ensureLanguageAndProvider(monacoId);
    const pierreLang = getPierreLanguageForMonacoId(monacoId);
    if (!pierreLang) return;

    if (model.getLineCount() > MAX_MODEL_LINES) {
      return;
    }

    const initialCode = model.getValue();
    const entryId = this.nextEntryId++;
    let entryRef = null;

    let tokenizer;
    try {
      const useChunkedInit = model.getLineCount() > INITIAL_SYNC_RENDER_LINES;
      tokenizer = new LiveTokenizer({
        lang: pierreLang,
        theme: DUMMY_PIERRE_THEME,
        code: initialCode,
        tokenizeMaxLineLength: MAX_LINE_LENGTH,
        ...(useChunkedInit
          ? {
              renderRange: [0, INITIAL_SYNC_RENDER_LINES],
              onDeferTokenize: () => {
                if (entryRef && !entryRef.disposed && !model.isDisposed()) {
                  model.tokenization?.resetTokenization?.();
                }
              },
            }
          : {}),
      });
    } catch {
      return;
    }

    const entry = {
      id: entryId,
      model,
      monacoId,
      pierreLang,
      tokenizer,
      syncedVersionId: model.getVersionId(),
      disposed: false,
      modelDisposables: [],
    };
    entryRef = entry;

    entry.modelDisposables.push(
      model.onDidChangeContent((e) => {
        this.handleModelChange(entry, e);
      }),
      model.onWillDispose(() => {
        this.detachModel(model);
      })
    );

    this.entriesByModel.set(model, entry);
    this.entriesById.set(entryId, entry);
    let langSet = this.entriesByLanguage.get(monacoId);
    if (!langSet) {
      langSet = new Set();
      this.entriesByLanguage.set(monacoId, langSet);
    }
    langSet.add(entry);
  }

  handleModelChange(entry, event) {
    if (entry.disposed || entry.model.isDisposed()) return;

    if (entry.model.getLineCount() > MAX_MODEL_LINES) {
      this.detachModel(entry.model);
      entry.model.tokenization?.resetTokenization?.();
      return;
    }

    if (event.isEolChange) {
      entry.syncedVersionId = entry.model.getVersionId();
      return;
    }

    try {
      if (event.isFlush) {
        entry.tokenizer.reset(entry.model.getValue());
        entry.syncedVersionId = entry.model.getVersionId();
        return;
      }

      const edits = event.changes.map((change) => ({
        range: {
          start: {
            line: change.range.startLineNumber - 1,
            character: change.range.startColumn - 1,
          },
          end: {
            line: change.range.endLineNumber - 1,
            character: change.range.endColumn - 1,
          },
        },
        newText: change.text,
      }));

      const update = entry.tokenizer.applyEdits(edits);
      entry.syncedVersionId = entry.model.getVersionId();

      // If a single-line edit invalidated downstream lines (e.g. opening /* block comment)
      // and Monaco already tokenized synchronously before onDidChangeContent fired, refresh tokens.
      if (entry.tokenizedStaleVersion) {
        entry.tokenizedStaleVersion = false;
        entry.model.tokenization?.resetTokenization?.();
      } else if (update.lineChanges.length > 0) {
        for (const lc of update.lineChanges) {
          if (lc.newEndLine - lc.newStartLine > 1) {
            // Ensure Monaco re-evaluates multi-line lexical changes promptly.
            entry.model.tokenization?.forceTokenization?.(
              Math.min(entry.model.getLineCount(), lc.newEndLine)
            );
          }
        }
      }
    } catch {
      try {
        entry.tokenizer.reset(entry.model.getValue());
        entry.syncedVersionId = entry.model.getVersionId();
      } catch {
        this.detachModel(entry.model);
      }
    }
  }

  tokenizeLine(monacoId, pierreLang, line, state) {
    const lineState = state instanceof PierreLineState ? state : new PierreLineState(0, null, 0);
    const lineIndex = lineState.lineIndex;

    if (line.length > MAX_LINE_LENGTH) {
      return {
        tokens: [],
        endState: new PierreLineState(lineIndex + 1, lineState.candidateIds, 0),
      };
    }

    const langSet = this.entriesByLanguage.get(monacoId);
    const matchedEntries = [];

    if (langSet && langSet.size > 0) {
      const candidates =
        lineState.candidateIds && lineState.candidateIds.length > 0
          ? lineState.candidateIds.map((id) => this.entriesById.get(id)).filter(Boolean)
          : Array.from(langSet);

      for (const entry of candidates) {
        if (entry.disposed || entry.model.isDisposed()) continue;
        if (entry.syncedVersionId !== entry.model.getVersionId()) {
          entry.tokenizedStaleVersion = true;
          continue;
        }
        if (lineIndex < entry.tokenizer.lineCount && entry.tokenizer.getLineText(lineIndex) === line) {
          matchedEntries.push(entry);
        }
      }

      // If candidate narrowing missed (e.g. heuristic jump), retry across all active models of this language.
      if (matchedEntries.length === 0 && lineState.candidateIds !== null) {
        for (const entry of langSet) {
          if (entry.disposed || entry.model.isDisposed()) continue;
          if (entry.syncedVersionId !== entry.model.getVersionId()) continue;
          if (lineIndex < entry.tokenizer.lineCount && entry.tokenizer.getLineText(lineIndex) === line) {
            matchedEntries.push(entry);
          }
        }
      }
    }

    if (matchedEntries.length > 0) {
      const primary = matchedEntries[0];
      if (primary.tokenizer.pendingTokenization) {
        primary.tokenizer.flush(Math.min(primary.tokenizer.lineCount, lineIndex + 2));
      }
      const records = primary.tokenizer.getLineRecords(lineIndex);
      const tokens = decodePacked24Records(records, line.length);
      let nextLineHash = 0;
      if (lineIndex + 1 < primary.tokenizer.lineCount) {
        if (primary.tokenizer.pendingTokenization) {
          primary.tokenizer.flush(lineIndex + 2);
        }
        const nextRecords = primary.tokenizer.getLineRecords(lineIndex + 1);
        nextLineHash = hashRecordsData(nextRecords.data);
      }
      return {
        tokens,
        endState: new PierreLineState(
          lineIndex + 1,
          matchedEntries.map((e) => e.id),
          nextLineHash
        ),
      };
    }

    // Fallback for synthetic single-line queries (e.g. getTokenTypeIfInsertingCharacter or colorize)
    // Only run when no oversized model (> MAX_MODEL_LINES) suppressed tokenization for this line.
    if (line.length > 0 && line.length <= 2048) {
      let tempTokenizer = null;
      try {
        tempTokenizer = new LiveTokenizer({
          lang: pierreLang,
          theme: DUMMY_PIERRE_THEME,
          code: line,
          tokenizeMaxLineLength: MAX_LINE_LENGTH,
        });
        const records = tempTokenizer.getLineRecords(0);
        const tokens = decodePacked24Records(records, line.length);
        return {
          tokens,
          endState: new PierreLineState(lineIndex + 1, null, 0),
        };
      } catch {
        // Fall through to plain empty tokens
      } finally {
        tempTokenizer?.dispose();
      }
    }

    return {
      tokens: [],
      endState: new PierreLineState(lineIndex + 1, null, 0),
    };
  }

  getTokenizerForModel(model) {
    return this.entriesByModel.get(model)?.tokenizer ?? null;
  }

  detachModel(model) {
    const entry = this.entriesByModel.get(model);
    if (!entry) return;
    entry.disposed = true;
    this.entriesByModel.delete(model);
    this.entriesById.delete(entry.id);
    const langSet = this.entriesByLanguage.get(entry.monacoId);
    if (langSet) {
      langSet.delete(entry);
      if (langSet.size === 0) {
        this.entriesByLanguage.delete(entry.monacoId);
      }
    }
    for (const d of entry.modelDisposables) {
      d.dispose();
    }
    entry.modelDisposables.length = 0;
    try {
      entry.tokenizer.dispose();
    } catch {
      // Ignore already disposed
    }
  }

  dispose() {
    for (const model of Array.from(this.entriesByModel.keys())) {
      this.detachModel(model);
    }
    for (const d of this.disposables) {
      d.dispose();
    }
    this.disposables.length = 0;
  }
}
