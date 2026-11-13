export class AskAgentController {
  constructor({
    monaco,
    container,
    getTargetEditor,
    getDiffContext,
    getModelMeta,
    postMessage,
  }) {
    this.monaco = monaco;
    this.container = container;
    this.getTargetEditor = getTargetEditor;
    this.getDiffContext = getDiffContext;
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

  presentBarForContext(ctx, anchorCoords, initialComment = '') {
    this.activeContext = ctx;
    const basename = ctx.path ? ctx.path.split('/').pop() : 'selection';
    const lineRef =
      ctx.startLine === ctx.endLine
        ? `L${ctx.startLine}`
        : `L${ctx.startLine}-${ctx.endLine}`;
    this.badgeEl.textContent = `${basename}#${lineRef}`;
    this.inputEl.value = initialComment;

    let topPx = 14;
    let leftPx = 48;
    if (
      anchorCoords &&
      Number.isFinite(anchorCoords.top) &&
      Number.isFinite(anchorCoords.left)
    ) {
      const containerHeight = this.container.clientHeight || 600;
      const containerWidth = this.container.clientWidth || 800;
      const preferredAbove = anchorCoords.top - 42;
      topPx =
        preferredAbove >= 8
          ? preferredAbove
          : Math.min(
              Math.max(8, anchorCoords.top + (anchorCoords.height || 20) + 6),
              Math.max(8, containerHeight - 48)
            );
      leftPx = Math.min(
        Math.max(16, anchorCoords.left),
        Math.max(16, containerWidth - 440)
      );
    }

    this.barEl.style.top = `${Math.round(topPx)}px`;
    this.barEl.style.left = `${Math.round(leftPx)}px`;
    this.barEl.hidden = false;
    this.inputEl.focus();
    this.inputEl.select();
    return true;
  }

  openPromptForEditor(editorInstance, initialComment = '') {
    const ctx = this.captureSelectionContext(editorInstance);
    if (!ctx) return false;

    let coords = null;
    try {
      coords = ctx.position
        ? ctx.editor.getScrolledVisiblePosition(ctx.position)
        : null;
    } catch {
      coords = null;
    }
    return this.presentBarForContext(ctx, coords, initialComment);
  }

  openPromptForDiffContext(diffCtx, initialComment = '') {
    if (!diffCtx) return false;
    const ctx = {
      source: 'diff',
      path: String(diffCtx.path ?? ''),
      side: diffCtx.side ?? 'additions',
      startLine: Math.max(1, Math.trunc(Number(diffCtx.startLine) || 1)),
      endLine: Math.max(1, Math.trunc(Number(diffCtx.endLine) || 1)),
      selectedText: String(diffCtx.selectedText ?? ''),
      restoreFocusTarget: diffCtx.restoreFocusTarget ?? null,
    };
    if (ctx.endLine < ctx.startLine) {
      ctx.endLine = ctx.startLine;
    }
    return this.presentBarForContext(ctx, diffCtx.anchorCoords ?? null, initialComment);
  }

  emitOutboundMessage(ctx, promptText) {
    if (ctx.source === 'diff') {
      this.postMessage({
        type: 'askAgent',
        path: ctx.path,
        side: ctx.side ?? 'additions',
        startLine: ctx.startLine,
        endLine: ctx.endLine,
        selectedText: ctx.selectedText,
        prompt: promptText,
        comment: promptText,
      });
      return;
    }
    this.postMessage({
      type: 'askAgent',
      uri: ctx.uri,
      path: ctx.path,
      startLine: ctx.startLine,
      endLine: ctx.endLine,
      selectedText: ctx.selectedText,
      comment: promptText,
    });
  }

  submitPrompt(overrideComment) {
    let ctx = this.activeContext;
    if (!ctx) {
      const diffCtx = this.getDiffContext?.();
      ctx = diffCtx
        ? {
            source: 'diff',
            path: String(diffCtx.path ?? ''),
            side: diffCtx.side ?? 'additions',
            startLine: Math.max(1, Math.trunc(Number(diffCtx.startLine) || 1)),
            endLine: Math.max(1, Math.trunc(Number(diffCtx.endLine) || 1)),
            selectedText: String(diffCtx.selectedText ?? ''),
          }
        : this.captureSelectionContext();
    }
    if (!ctx) return false;
    const comment =
      typeof overrideComment === 'string'
        ? overrideComment.trim()
        : this.inputEl.value.trim();

    this.emitOutboundMessage(ctx, comment);
    this.hidePrompt(true);
    return true;
  }

  triggerAskAgent({ comment, prompt, immediate = false } = {}) {
    const initialText = String(prompt ?? comment ?? '');
    const diffCtx = this.getDiffContext?.();
    if (diffCtx) {
      if (immediate) {
        this.emitOutboundMessage(
          {
            source: 'diff',
            path: String(diffCtx.path ?? ''),
            side: diffCtx.side ?? 'additions',
            startLine: Math.max(1, Math.trunc(Number(diffCtx.startLine) || 1)),
            endLine: Math.max(1, Math.trunc(Number(diffCtx.endLine) || 1)),
            selectedText: String(diffCtx.selectedText ?? ''),
          },
          initialText.trim()
        );
        return true;
      }
      return this.openPromptForDiffContext(diffCtx, initialText);
    }

    if (immediate) {
      const ctx = this.captureSelectionContext();
      if (!ctx) return false;
      this.emitOutboundMessage(ctx, initialText.trim());
      return true;
    }
    return this.openPromptForEditor(undefined, initialText);
  }

  hidePrompt(restoreFocus = false) {
    const prevEditor = this.activeContext?.editor;
    const restoreTarget = this.activeContext?.restoreFocusTarget;
    this.activeContext = null;
    this.barEl.hidden = true;
    this.inputEl.value = '';
    if (restoreFocus) {
      if (prevEditor) {
        prevEditor.focus?.();
      } else if (restoreTarget) {
        restoreTarget.focus?.();
      }
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
