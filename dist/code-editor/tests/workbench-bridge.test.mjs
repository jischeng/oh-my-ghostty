import assert from 'node:assert/strict';
import test from 'node:test';
import { createWorkbenchDom } from './jsdom-harness.mjs';

test('emits ready on startup and manages multi-model state, viewState, and silent host updates', async () => {
  const h = await createWorkbenchDom();
  try {
    assert.equal(h.messages.length, 1);
    assert.deepEqual(h.messages[0], { type: 'ready' });

    const uriA = 'file:///workspace/alpha.swift';
    const uriB = 'file:///workspace/beta.zig';

    h.omgEditor.openOrUpdateModel({
      uri: uriA,
      path: '/workspace/alpha.swift',
      text: 'import AppKit\nfunc alphaOne() {}\nfunc alphaTwo() {}\n',
    });
    h.omgEditor.openOrUpdateModel({
      uri: uriB,
      path: '/workspace/beta.zig',
      text: 'const std = @import("std");\npub fn main() void {}\n',
    });

    // Host openOrUpdateModel MUST NOT echo didChangeContent
    assert.equal(
      h.messages.filter((m) => m.type === 'didChangeContent').length,
      0
    );

    assert.equal(
      h.omgEditor.activateModel({
        uri: uriA,
        readOnly: false,
        wordWrap: true,
        tabSize: 4,
        insertSpaces: true,
        keymapProfile: 'idea',
      }),
      true
    );
    assert.equal(h.omgEditor.getState().keymapProfile, 'idea');

    // Select range on model A, switch to model B, then switch back to A and verify viewState restored
    h.omgEditor.revealRange({
      uri: uriA,
      startLine: 3,
      startColumn: 6,
      endLine: 3,
      endColumn: 14,
    });
    const editor = h.omgEditor._internal.editor;
    assert.equal(editor.getSelection().startLineNumber, 3);
    assert.equal(editor.getSelection().startColumn, 6);

    h.omgEditor.activateModel({ uri: uriB, keymapProfile: 'vscode' });
    assert.equal(h.omgEditor.getState().activeUri, uriB);
    assert.equal(h.omgEditor.getState().keymapProfile, 'vscode');

    h.omgEditor.activateModel({ uri: uriA });
    assert.equal(editor.getSelection().startLineNumber, 3);
    assert.equal(editor.getSelection().startColumn, 6);
    assert.equal(editor.getSelection().endColumn, 14);

    // User/editor edit MUST emit didChangeContent
    const { monaco } = h.omgEditor._internal;
    const modelA = editor.getModel();
    modelA.pushEditOperations(
      [],
      [{ range: new monaco.Range(1, 1, 1, 1), text: '// header\n' }],
      () => null
    );

    const changeMsgs = h.messages.filter((m) => m.type === 'didChangeContent');
    assert.equal(changeMsgs.length, 1);
    assert.equal(changeMsgs[0].uri, uriA);
    assert.equal(changeMsgs[0].path, '/workspace/alpha.swift');
    assert.match(changeMsgs[0].text, /^\/\/ header\nimport AppKit/);
    assert.equal(typeof changeMsgs[0].versionId, 'number');

    // External File-Watcher reload (preserveView: true) updates text in-place WITHOUT echoing didChangeContent,
    // while keeping cursor/selection and undo stack intact!
    h.omgEditor.revealRange({
      uri: uriA,
      startLine: 4,
      startColumn: 6,
      endLine: 4,
      endColumn: 14,
    });
    h.omgEditor.openOrUpdateModel({
      uri: uriA,
      path: '/workspace/alpha.swift',
      text: '// header\nimport AppKit\nfunc alphaOne() {}\nfunc alphaTwo() { /* agent edit */ }\n',
      preserveView: true,
    });

    assert.equal(
      h.messages.filter((m) => m.type === 'didChangeContent').length,
      1,
      'preserveView external sync must not echo didChangeContent'
    );
    assert.equal(editor.getSelection().startLineNumber, 4);
    assert.equal(editor.getSelection().startColumn, 6);
    assert.equal(modelA.canUndo(), true, 'preserveView must preserve undo stack via pushEditOperations');

    // Verify LiveTokenizer is attached and disposed on closeModel
    assert.ok(h.omgEditor._internal.highlighting.getTokenizerForModel(modelA));
    assert.equal(h.omgEditor.closeModel({ uri: uriA }), true);
    assert.equal(h.omgEditor._internal.highlighting.getTokenizerForModel(modelA), null);
    assert.equal(modelA.isDisposed(), true);
  } finally {
    h.cleanup();
  }
});

test('enforces MAX_MODEL_LINES = 300_000 safety cap without allocating LiveTokenizer WASM', async () => {
  const h = await createWorkbenchDom();
  try {
    const hugeText = 'x\n'.repeat(h.omgEditor.constants.MAX_MODEL_LINES + 5);
    const uri = 'file:///workspace/huge.py';
    h.omgEditor.openOrUpdateModel({ uri, path: '/workspace/huge.py', text: hugeText });
    h.omgEditor.activateModel({ uri });
    const model = h.omgEditor._internal.editor.getModel();
    assert.ok(model.getLineCount() > h.omgEditor.constants.MAX_MODEL_LINES);
    assert.equal(h.omgEditor._internal.highlighting.getTokenizerForModel(model), null);
  } finally {
    h.cleanup();
  }
});

test('setTheme (transparent #00000000), setFont, setGitDiffLines, setDiagnostics, activateDiff & navigateDiff', async () => {
  const h = await createWorkbenchDom();
  try {
    const { themeData } = h.omgEditor.setTheme({
      base: 'vs-dark',
      foreground: '#abb2bf',
      cursor: '#528bff',
      selection: '#3e4451',
      lineHighlight: 'rgba(82, 139, 255, 0.08)',
      keywords: '#c678dd',
      functions: '#61afef',
      types: '#e5c07b',
      strings: '#98c379',
      numbers: '#d19a66',
      comments: '#5c6370',
      variables: '#e06c75',
    });

    assert.equal(themeData.colors['editor.background'], '#00000000');
    assert.equal(themeData.colors['editorGutter.background'], '#00000000');
    assert.match(themeData.colors['editorStickyScroll.background'], /^#[0-9a-f]{8}$/);

    const fontApplied = h.omgEditor.setFont({
      family: 'JetBrains Mono',
      size: 15,
      ligatures: true,
    });
    assert.equal(fontApplied.fontFamily, 'JetBrains Mono');
    assert.equal(fontApplied.fontSize, 15);

    const uri = 'file:///workspace/gutter.rs';
    h.omgEditor.openOrUpdateModel({
      uri,
      path: '/workspace/gutter.rs',
      text: 'fn a() {}\nfn b() {}\nfn c() {}\nfn d() {}\n',
    });
    h.omgEditor.activateModel({ uri });

    h.omgEditor.setGitDiffLines({
      uri,
      lines: { 1: 'added', 2: 'modified', 4: 'deleted' },
    });
    assert.equal(h.omgEditor.getState().gitGutterCount, 3);

    const markerCount = h.omgEditor.setDiagnostics({
      uri,
      markers: [
        {
          startLine: 2,
          startColumn: 4,
          endLine: 2,
          endColumn: 5,
          severity: 'error',
          message: 'cannot find value `x`',
          source: 'rust-analyzer',
        },
      ],
    });
    assert.equal(markerCount, 1);
    const markers = h.omgEditor._internal.monaco.editor.getModelMarkers({
      owner: 'omg-intelligence',
    });
    assert.equal(markers.length, 1);
    assert.equal(markers[0].message, 'cannot find value `x`');

    // Diff editor activation & hunk navigation
    assert.equal(
      h.omgEditor.activateDiff({
        id: 'commit-1',
        path: '/workspace/gutter.rs',
        originalText: 'fn a() {}\nfn b() { 1 }\nfn keep() {}\nfn d() { 2 }\n',
        modifiedText: 'fn a() {}\nfn b() { 100 }\nfn keep() {}\nfn d() { 200 }\n',
        inline: false,
        wordWrap: true,
        readOnly: true,
      }),
      true
    );
    assert.equal(h.omgEditor.getState().mode, 'diff');

    assert.equal(h.omgEditor.navigateDiff({ direction: 'next' }), true);
    const modEditor = h.omgEditor._internal.getDiffEditor().getModifiedEditor();
    assert.equal(modEditor.getPosition().lineNumber, 2);

    assert.equal(h.omgEditor.navigateDiff({ direction: 'next' }), true);
    assert.equal(modEditor.getPosition().lineNumber, 4);

    assert.equal(h.omgEditor.navigateDiff({ direction: 'prev' }), true);
    assert.equal(modEditor.getPosition().lineNumber, 2);

    // Switching back to normal model hides diff and restores editor mode
    h.omgEditor.activateModel({ uri });
    assert.equal(h.omgEditor.getState().mode, 'editor');

    // Verify performAction supports all required action names
    for (const action of [
      'find',
      'replace',
      'goToLine',
      'findNext',
      'findPrev',
      'documentSymbols',
      'foldAll',
      'unfoldAll',
    ]) {
      assert.equal(h.omgEditor.performAction({ action }), true, `performAction failed for ${action}`);
      if (action === 'goToLine' || action === 'documentSymbols') {
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }
  } finally {
    h.cleanup();
  }
});

test('Ask Agent inline prompt bar & outbound askAgent payload', async () => {
  const h = await createWorkbenchDom();
  try {
    const uri = 'file:///workspace/agent.ts';
    h.omgEditor.openOrUpdateModel({
      uri,
      path: '/workspace/agent.ts',
      text: 'export function compute(x: number) {\n  return x * 2;\n}\n',
    });
    h.omgEditor.activateModel({ uri });
    h.omgEditor.revealRange({
      uri,
      startLine: 1,
      startColumn: 1,
      endLine: 2,
      endColumn: 16,
    });

    // Open inline Ask Agent bar via performAction
    assert.equal(h.omgEditor.performAction({ action: 'askAgent' }), true);
    assert.equal(h.omgEditor.getState().isAskAgentOpen, true);

    const bar = h.document.getElementById('omg-ask-agent-bar');
    const badge = bar.querySelector('.omg-ask-agent-badge');
    const input = bar.querySelector('.omg-ask-agent-input');
    assert.equal(badge.textContent, 'agent.ts#L1-2');

    // Escape cancels without posting askAgent
    input.value = 'ignore me';
    input.dispatchEvent(new h.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    assert.equal(h.omgEditor.getState().isAskAgentOpen, false);
    assert.equal(h.messages.filter((m) => m.type === 'askAgent').length, 0);

    // Open again, type instruction, press Enter -> emits askAgent
    h.omgEditor.performAction({ action: 'askAgent' });
    input.value = 'Refactor to handle BigInt';
    input.dispatchEvent(new h.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));

    assert.equal(h.omgEditor.getState().isAskAgentOpen, false);
    const askMsgs = h.messages.filter((m) => m.type === 'askAgent');
    assert.equal(askMsgs.length, 1);
    assert.deepEqual(askMsgs[0], {
      type: 'askAgent',
      uri,
      path: '/workspace/agent.ts',
      startLine: 1,
      endLine: 2,
      selectedText: 'export function compute(x: number) {\n  return x * 2;',
      comment: 'Refactor to handle BigInt',
    });
  } finally {
    h.cleanup();
  }
});

test('LSP request/resolveRequest roundtrip, cross-file navigateDefinition, openLink, and hostCommands', async () => {
  const h = await createWorkbenchDom();
  try {
    const uri = 'omg-ssh://remote-box/repo/src/main.swift';
    h.omgEditor.openOrUpdateModel({
      uri,
      path: '/repo/src/main.swift',
      text: 'let svc = HelperService()\nsvc.run()\n',
    });
    h.omgEditor.activateModel({ uri, keymapProfile: 'vscode' });

    const { monaco, editor } = h.omgEditor._internal;
    const model = editor.getModel();
    const pos = new monaco.Position(2, 6);

    // 1. HoverProvider roundtrip
    const lspBridge = h.omgEditor._internal.lspBridge;
    assert.ok(lspBridge);
    const hoverPromise = lspBridge.providers.hover.provideHover(model, pos, null);

    const hoverReq = h.messages.findLast((m) => m.type === 'lspRequest');
    assert.equal(hoverReq.method, 'hover');
    assert.equal(hoverReq.uri, uri);
    assert.equal(hoverReq.path, '/repo/src/main.swift');
    assert.equal(hoverReq.line, 2);
    assert.equal(hoverReq.column, 6);

    assert.equal(
      h.omgEditor.resolveRequest(hoverReq.requestId, {
        markdown: '```swift\nfunc run()\n```',
        range: { start: { line: 2, column: 5 }, end: { line: 2, column: 8 } },
      }),
      true
    );
    const hoverRes = await hoverPromise;
    assert.equal(hoverRes.contents[0].value, '```swift\nfunc run()\n```');
    assert.equal(hoverRes.range.startLineNumber, 2);
    assert.equal(hoverRes.range.startColumn, 5);

    // 1b. CompletionItemProvider roundtrip
    const compPromise = lspBridge.providers.completion.provideCompletionItems(
      model,
      pos,
      { triggerCharacter: '.' },
      null
    );
    const compReq = h.messages.findLast((m) => m.type === 'lspRequest');
    assert.equal(compReq.method, 'completion');
    assert.equal(compReq.triggerCharacter, '.');
    h.omgEditor.resolveRequest(compReq.requestId, {
      items: [
        {
          label: 'run()',
          kind: 'method',
          detail: '() -> Void',
          insertText: 'run()',
        },
      ],
    });
    const compRes = await compPromise;
    assert.equal(compRes.suggestions.length, 1);
    assert.equal(compRes.suggestions[0].label, 'run()');

    // 1c. DefinitionProvider + ReferenceProvider + DocumentSymbolProvider roundtrips
    const defPromise = lspBridge.providers.definition.provideDefinition(model, pos, null);
    const defReq = h.messages.findLast((m) => m.type === 'lspRequest');
    assert.equal(defReq.method, 'definition');
    h.omgEditor.resolveRequest(defReq.requestId, {
      path: '/repo/src/HelperService.swift',
      startLine: 14,
      startColumn: 10,
      endLine: 14,
      endColumn: 13,
    });
    const defLocations = await defPromise;
    assert.equal(defLocations.length, 1);
    const loc = defLocations[0];
    // Must preserve omg-ssh://remote-box authority, never falling back to local file://!
    assert.equal(loc.uri.toString(), 'omg-ssh://remote-box/repo/src/HelperService.swift');

    const refPromise = lspBridge.providers.references.provideReferences(model, pos, {}, null);
    const refReq = h.messages.findLast((m) => m.type === 'lspRequest');
    assert.equal(refReq.method, 'references');
    h.omgEditor.resolveRequest(refReq.requestId, [
      { path: '/repo/src/main.swift', startLine: 2, startColumn: 5, endLine: 2, endColumn: 8 },
    ]);
    const refs = await refPromise;
    assert.equal(refs.length, 1);

    const symPromise = lspBridge.providers.documentSymbol.provideDocumentSymbols(model, null);
    const symReq = h.messages.findLast((m) => m.type === 'lspRequest');
    assert.equal(symReq.method, 'documentSymbol');
    h.omgEditor.resolveRequest(symReq.requestId, [
      {
        name: 'HelperService',
        kind: 'class',
        startLine: 1,
        startColumn: 1,
        endLine: 10,
        endColumn: 2,
        children: [{ name: 'run', kind: 'method', startLine: 3, startColumn: 3, endLine: 5, endColumn: 4 }],
      },
    ]);
    const syms = await symPromise;
    assert.equal(syms.length, 1);
    assert.equal(syms[0].name, 'HelperService');
    assert.equal(syms[0].children[0].name, 'run');

    // 1d. LinkOpener delegates external links to Swift host
    lspBridge.providers.linkOpener.open(monaco.Uri.parse('https://ghostty.org/docs'));
    assert.deepEqual(h.messages.findLast((m) => m.type === 'openLink'), {
      type: 'openLink',
      href: 'https://ghostty.org/docs',
    });

    // Trigger Monaco's ICodeEditorService.openCodeEditor (what Cmd+Click / F12 invokes!)
    await editor._codeEditorService.openCodeEditor(
      {
        resource: loc.uri,
        options: { selection: { startLineNumber: 14, startColumn: 10 } },
      },
      editor
    );

    const navMsg = h.messages.findLast((m) => m.type === 'navigateDefinition');
    assert.deepEqual(navMsg, {
      type: 'navigateDefinition',
      target: {
        uri: 'omg-ssh://remote-box/repo/src/HelperService.swift',
        path: '/repo/src/HelperService.swift',
        startLine: 14,
        startColumn: 10,
        endLine: 14,
        endColumn: 13,
      },
    });

    // 3. Host keyboard shortcuts (Shift+Escape -> hide, Cmd+S -> save in vscode vs saveAll in idea, Cmd+P -> open)
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 'Escape', shiftKey: true, bubbles: true })
    );
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 's', metaKey: true, bubbles: true })
    );
    h.omgEditor.activateModel({ uri, keymapProfile: 'idea' });
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 's', metaKey: true, bubbles: true })
    );
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 'p', metaKey: true, bubbles: true })
    );

    const hostCmds = h.messages.filter((m) => m.type === 'hostCommand').map((m) => m.command);
    assert.deepEqual(hostCmds, ['hide', 'save', 'saveAll', 'open']);
  } finally {
    h.cleanup();
  }
});
