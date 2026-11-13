export class KeymapController {
  constructor({ monaco, postMessage, isAskAgentOpen }) {
    this.monaco = monaco;
    this.postMessage = postMessage;
    this.isAskAgentOpen = isAskAgentOpen;
    this.profile = 'vscode';
    this.contextKeys = [];
    this.staticDisposables = [];
    this.editors = new Set();
  }

  emitHostCommand(command) {
    this.postMessage({
      type: 'hostCommand',
      command,
    });
  }

  runEditorAction(editor, actionId) {
    if (!editor) return;
    editor.focus?.();
    const action = editor.getAction?.(actionId);
    if (action) {
      Promise.resolve(action.run()).catch(() => {});
    } else {
      editor.trigger?.('omg-keymap', actionId, null);
    }
  }

  attachEditor(editor) {
    if (!editor || this.editors.has(editor)) return;
    this.editors.add(editor);
    const { KeyMod, KeyCode } = this.monaco;

    const ctxKey = editor.createContextKey('omgKeymapProfile', this.profile);
    this.contextKeys.push(ctxKey);

    // Cross-profile host commands
    editor.addCommand(KeyMod.Shift | KeyCode.Escape, () => {
      if (this.isAskAgentOpen?.()) return;
      this.emitHostCommand('hide');
    });
    editor.addCommand(KeyMod.CtrlCmd | KeyMod.Shift | KeyCode.KeyS, () => {
      this.emitHostCommand('saveAll');
    });
    editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyW, () => {
      this.emitHostCommand('close');
    });
    editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyO, () => {
      this.emitHostCommand('open');
    });
    editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyP, () => {
      this.emitHostCommand('open');
    });
    editor.addCommand(KeyMod.WinCtrl | KeyCode.Tab, () => {
      this.emitHostCommand('nextDocument');
    });
    editor.addCommand(KeyMod.WinCtrl | KeyMod.Shift | KeyCode.Tab, () => {
      this.emitHostCommand('previousDocument');
    });

    // JetBrains IDEA keymap bindings (active only when omgKeymapProfile == 'idea')
    const whenIdea = "omgKeymapProfile == 'idea'";
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyS,
      () => this.emitHostCommand('saveAll'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyD,
      () => this.runEditorAction(editor, 'editor.action.copyLinesDownAction'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyY,
      () => this.runEditorAction(editor, 'editor.action.deleteLines'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.Backspace,
      () => this.runEditorAction(editor, 'editor.action.deleteLines'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyR,
      () => this.runEditorAction(editor, 'editor.action.startFindReplaceAction'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyL,
      () => this.runEditorAction(editor, 'editor.action.gotoLine'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.Alt | KeyMod.Shift | KeyCode.UpArrow,
      () => this.runEditorAction(editor, 'editor.action.moveLinesUpAction'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.Alt | KeyMod.Shift | KeyCode.DownArrow,
      () => this.runEditorAction(editor, 'editor.action.moveLinesDownAction'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyMod.Shift | KeyCode.BracketRight,
      () => this.emitHostCommand('nextDocument'),
      whenIdea
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyMod.Shift | KeyCode.BracketLeft,
      () => this.emitHostCommand('previousDocument'),
      whenIdea
    );

    // VS Code keymap bindings (active only when omgKeymapProfile == 'vscode')
    const whenVscode = "omgKeymapProfile == 'vscode'";
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyS,
      () => this.emitHostCommand('save'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyD,
      () => this.runEditorAction(editor, 'editor.action.addSelectionToNextFindMatch'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.Shift | KeyCode.KeyK,
      () => this.runEditorAction(editor, 'editor.action.deleteLines'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.KeyF,
      () => this.runEditorAction(editor, 'editor.action.startFindReplaceAction'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.WinCtrl | KeyCode.KeyG,
      () => this.runEditorAction(editor, 'editor.action.gotoLine'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyCode.KeyL,
      () => this.runEditorAction(editor, 'expandLineSelection'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.Alt | KeyMod.Shift | KeyCode.DownArrow,
      () => this.runEditorAction(editor, 'editor.action.copyLinesDownAction'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.Alt | KeyMod.Shift | KeyCode.UpArrow,
      () => this.runEditorAction(editor, 'editor.action.copyLinesUpAction'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.Alt | KeyCode.UpArrow,
      () => this.runEditorAction(editor, 'editor.action.moveLinesUpAction'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.Alt | KeyCode.DownArrow,
      () => this.runEditorAction(editor, 'editor.action.moveLinesDownAction'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.RightArrow,
      () => this.emitHostCommand('nextDocument'),
      whenVscode
    );
    editor.addCommand(
      KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.LeftArrow,
      () => this.emitHostCommand('previousDocument'),
      whenVscode
    );
  }

  installGlobalShortcuts(win) {
    if (!win || typeof win.addEventListener !== 'function') return;
    const onKeyDown = (event) => {
      if (event.defaultPrevented) return;
      if (event.key === 'Escape' && event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey) {
        if (this.isAskAgentOpen?.()) return;
        event.preventDefault();
        this.emitHostCommand('hide');
        return;
      }
      const cmd = event.metaKey && !event.ctrlKey;
      const key = (event.key || '').toLowerCase();
      if (cmd && !event.altKey && key === 's') {
        event.preventDefault();
        if (event.shiftKey || this.profile === 'idea') {
          this.emitHostCommand('saveAll');
        } else {
          this.emitHostCommand('save');
        }
      } else if (cmd && !event.shiftKey && !event.altKey && key === 'w') {
        event.preventDefault();
        this.emitHostCommand('close');
      } else if (cmd && !event.shiftKey && !event.altKey && (key === 'o' || key === 'p')) {
        event.preventDefault();
        this.emitHostCommand('open');
      } else if (event.ctrlKey && !event.metaKey && !event.altKey && event.key === 'Tab') {
        event.preventDefault();
        this.emitHostCommand(event.shiftKey ? 'previousDocument' : 'nextDocument');
      }
    };
    win.addEventListener('keydown', onKeyDown, false);
    this.staticDisposables.push({
      dispose: () => win.removeEventListener('keydown', onKeyDown, false),
    });
  }

  setProfile(nextProfile) {
    const normalized = nextProfile === 'idea' ? 'idea' : 'vscode';
    this.profile = normalized;
    for (const ctxKey of this.contextKeys) {
      ctxKey.set(normalized);
    }
  }

  getProfile() {
    return this.profile;
  }

  dispose() {
    for (const d of this.staticDisposables) {
      d?.dispose?.();
    }
    this.staticDisposables.length = 0;
    this.contextKeys.length = 0;
    this.editors.clear();
  }
}
