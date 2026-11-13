export class AskAgentController {
  constructor({ monaco, container, getTargetEditor, getModelMeta, postMessage }) {
    this.monaco = monaco;
    this.container = container;
    this.getTargetEditor = getTargetEditor;
    this.getModelMeta = getModelMeta;
    this.postMessage = postMessage;
    this.activeContext = null;
    this.disposables = [];

    this.barEl = this.buildBarElement();
    this.container.appendChild(this.barEl);
  }

  buildBarElement() {
    const doc = this.container.ownerDocument;
    const bar = doc.createElement('div');
    bar.id = 'omg-ask-agent-bar';
    bar.className = 'omg-ask-agent-bar';
    bar.hidden = true;
    bar.setAttribute('role', 'dialog');
    bar.setAttribute('aria-label', 'Ask Agent');

    const badge = doc.createElement('span');
    badge.className = 'omg-ask-agent-badge';
    this.badgeEl = badge;

    const input = doc.createElement('input');
    input.type = 'text';
    input.className = 'omg-ask-agent-input';
    input.placeholder = 'Ask Agent or press Enter to send to Quick Input…';
    input.autocomplete = 'off';
    input.spellcheck = false;
    this.inputEl = input;

    const sendBtn = doc.createElement('button');
    sendBtn.type = 'button';
    sendBtn.className = 'omg-ask-agent-btn omg-ask-agent-send';
    sendBtn.textContent = 'Send ↵';

    const cancelBtn = doc.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.className = 'omg-ask-agent-btn omg-ask-agent-cancel';
    cancelBtn.textContent = 'Esc';
    cancelBtn.title = 'Cancel';

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.isComposing) {
        e.preventDefault();
        e.stopPropagation();
        this.submitPrompt();
      } else if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        this.hidePrompt(true);
      }
    });

    sendBtn.addEventListener('click', (e) => {
      e.preventDefault();
      this.submitPrompt();
    });

    cancelBtn.addEventListener('click', (e) => {
      e.preventDefault();
      this.hidePrompt(true);
    });

    bar.append(badge, input, sendBtn, cancelBtn);
    return bar;
  }

  attachToEditor(editor) {
    const { monaco } = this;
    const actionDisposable = editor.addAction({
      id: 'omg.askAgent',
      label: 'Ask Agent / Send to Quick Input',
      keybindings: [
        monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyL,
        monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyI,
      ],
      contextMenuGroupId: '1_modification',
      contextMenuOrder: 0,
      run: (ed) => {
        this.openPromptForEditor(ed);
      },
    });
    this.disposables.push(actionDisposable);
  }

  captureSelectionContext(editorInstance) {
    const editor = editorInstance ?? this.getTargetEditor();
    const model = editor?.getModel?.();
    if (!editor || !model || model.isDisposed()) {
      return null;
    }

    const uri = model.uri.toString();
    const meta = this.getModelMeta(uri);
    const path = meta?.path ?? model.uri.path ?? '';
    const selection = editor.getSelection();

    let startLine = 1;
    let endLine = 1;
    let selectedText = '';

    if (selection && !selection.isEmpty()) {
      startLine = selection.startLineNumber;
      endLine =
        selection.endColumn === 1 && selection.endLineNumber > selection.startLineNumber
          ? selection.endLineNumber - 1
          : selection.endLineNumber;
      selectedText = model.getValueInRange(selection);
    } else {
      const pos = editor.getPosition() ?? { lineNumber: 1, column: 1 };
      startLine = pos.lineNumber;
      endLine = pos.lineNumber;
      selectedText = model.getLineContent(startLine);
    }

    return {
      editor,
      uri,
      path,
      startLine,
      endLine,
      selectedText,
      position: selection ? selection.getStartPosition() : editor.getPosition(),
    };
  }

  openPromptForEditor(editorInstance, initialComment = '') {
    const ctx = this.captureSelectionContext(editorInstance);
    if (!ctx) return false;

    this.activeContext = ctx;
    const basename = ctx.path ? ctx.path.split('/').pop() : 'selection';
    const lineRef =
      ctx.startLine === ctx.endLine
        ? `L${ctx.startLine}`
        : `L${ctx.startLine}-${ctx.endLine}`;
    this.badgeEl.textContent = `${basename}#${lineRef}`;
    this.inputEl.value = initialComment;

    let topPx = 12;
    let leftPx = 48;
    try {
      const coords = ctx.position
        ? ctx.editor.getScrolledVisiblePosition(ctx.position)
        : null;
      if (coords && Number.isFinite(coords.top) && Number.isFinite(coords.left)) {
        const containerHeight = this.container.clientHeight || 600;
        const containerWidth = this.container.clientWidth || 800;
        const preferredAbove = coords.top - 42;
        topPx =
          preferredAbove >= 8
            ? preferredAbove
            : Math.min(Math.max(8, coords.top + (coords.height || 20) + 6), Math.max(8, containerHeight - 48));
        leftPx = Math.min(Math.max(16, coords.left), Math.max(16, containerWidth - 440));
      }
    } catch {
      // Default top-right-ish anchor when DOM layout metrics aren't computed (e.g. jsdom)
    }

    this.barEl.style.top = `${Math.round(topPx)}px`;
    this.barEl.style.left = `${Math.round(leftPx)}px`;
    this.barEl.hidden = false;
    this.inputEl.focus();
    this.inputEl.select();
    return true;
  }

  submitPrompt(overrideComment) {
    const ctx = this.activeContext ?? this.captureSelectionContext();
    if (!ctx) return false;
    const comment =
      typeof overrideComment === 'string'
        ? overrideComment.trim()
        : this.inputEl.value.trim();

    this.postMessage({
      type: 'askAgent',
      uri: ctx.uri,
      path: ctx.path,
      startLine: ctx.startLine,
      endLine: ctx.endLine,
      selectedText: ctx.selectedText,
      comment,
    });

    this.hidePrompt(true);
    return true;
  }

  triggerAskAgent({ comment = '', immediate = false } = {}) {
    if (immediate) {
      const ctx = this.captureSelectionContext();
      if (!ctx) return false;
      this.postMessage({
        type: 'askAgent',
        uri: ctx.uri,
        path: ctx.path,
        startLine: ctx.startLine,
        endLine: ctx.endLine,
        selectedText: ctx.selectedText,
        comment: String(comment).trim(),
      });
      return true;
    }
    return this.openPromptForEditor(undefined, comment);
  }

  hidePrompt(restoreFocus = false) {
    const prevEditor = this.activeContext?.editor;
    this.activeContext = null;
    this.barEl.hidden = true;
    this.inputEl.value = '';
    if (restoreFocus && prevEditor) {
      prevEditor.focus?.();
    }
  }

  isVisible() {
    return !this.barEl.hidden;
  }

  dispose() {
    this.hidePrompt(false);
    this.barEl.remove();
    for (const d of this.disposables) {
      d.dispose();
    }
    this.disposables.length = 0;
  }
}
