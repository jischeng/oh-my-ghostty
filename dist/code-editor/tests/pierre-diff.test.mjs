import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { CODE_EDITOR_OUT_DIR, createWorkbenchDom } from './jsdom-harness.mjs';

function buildSampleFile({ modHeader = false, modMiddle = false, modFooter = false } = {}) {
  const lines = [];
  lines.push(modHeader ? 'import Foundation // updated import' : 'import Foundation');
  for (let i = 2; i <= 18; i++) {
    lines.push(`let unchangedTop${i} = ${i}`);
  }
  lines.push(
    modMiddle
      ? 'func computeTotal(items: [Int]) -> Int { items.reduce(0, +) }'
      : 'func computeTotal(items: [Int]) -> Int { return 0 }'
  );
  for (let i = 20; i <= 36; i++) {
    lines.push(`let unchangedBottom${i} = ${i}`);
  }
  lines.push(modFooter ? 'let status = "ready-v2"' : 'let status = "ready"');
  return `${lines.join('\n')}\n`;
}

function getDiffShadowRoot(h) {
  const container = h.document.querySelector('#diff-root diffs-container');
  assert.ok(container, 'Expected <diffs-container> inside #diff-root');
  assert.ok(container.shadowRoot, 'Expected open shadowRoot on <diffs-container>');
  return { container, shadowRoot: container.shadowRoot };
}

test('Pierre diff renders Review mode (collapsed hunks + interactive expansion) and Full Source mode cleanly', async () => {
  const h = await createWorkbenchDom();
  try {
    const originalText = buildSampleFile();
    const modifiedText = buildSampleFile({
      modHeader: true,
      modMiddle: true,
      modFooter: true,
    });

    assert.equal(
      h.omgEditor.activateDiff({
        id: 'review-vs-full',
        path: '/workspace/Sources/Engine.swift',
        originalText,
        modifiedText,
        review: true,
        inline: false,
        wordWrap: false,
      }),
      true
    );

    assert.equal(h.omgEditor.getState().mode, 'diff');
    const { container, shadowRoot } = getDiffShadowRoot(h);

    // Offline @pierre/highlights WASM must emit syntax-colored token spans using CSS variables
    const highlightedSpans = shadowRoot.querySelectorAll('span[style*="--omg-syntax-"]');
    assert.ok(
      highlightedSpans.length > 0,
      'Expected offline @pierre/highlights syntax token spans in diff'
    );

    // Review mode collapses unmodified context regions and renders interactive hunk separators
    const separatorsBefore = shadowRoot.querySelectorAll('[data-separator="line-info"]');
    assert.ok(
      separatorsBefore.length >= 2,
      `Expected collapsed hunk separators in Review mode, got ${separatorsBefore.length}`
    );
    const renderedAddLinesReview = shadowRoot.querySelectorAll('code[data-additions] [data-line]');
    assert.ok(
      renderedAddLinesReview.length < 37,
      `Review mode should collapse unchanged lines, got ${renderedAddLinesReview.length}`
    );

    // Clicking an expand button inside the hunk separator expands unmodified context lines
    const expandBtn = shadowRoot.querySelector('[data-expand-button]');
    assert.ok(expandBtn, 'Expected interactive [data-expand-button] in hunk separator');
    expandBtn.dispatchEvent(
      new h.window.MouseEvent('click', { bubbles: true, composed: true })
    );

    const renderedAfterExpandClick = shadowRoot.querySelectorAll(
      'code[data-additions] [data-line]'
    );
    assert.ok(
      renderedAfterExpandClick.length > renderedAddLinesReview.length,
      `Expected hunk expand click to reveal unmodified lines (${renderedAfterExpandClick.length} vs ${renderedAddLinesReview.length})`
    );

    // Switching review: false (Full Source mode) reuses the same <diffs-container> with zero flicker
    // and expands all 37 lines!
    assert.equal(
      h.omgEditor.activateDiff({
        id: 'review-vs-full',
        path: '/workspace/Sources/Engine.swift',
        originalText,
        modifiedText,
        review: false,
        inline: false,
        wordWrap: false,
      }),
      true
    );

    assert.equal(
      h.document.querySelector('#diff-root diffs-container'),
      container,
      'Toggling review mode must update in-place without recreating <diffs-container>'
    );
    assert.equal(
      shadowRoot.querySelectorAll('[data-separator="line-info"]').length,
      0,
      'Full Source mode must have zero collapsed hunk separators'
    );
    assert.equal(
      shadowRoot.querySelectorAll('code[data-additions] [data-line]').length,
      37,
      'Full Source mode must render all 37 lines'
    );

    // Switching back to review: true re-collapses unchanged lines cleanly
    h.omgEditor.activateDiff({
      id: 'review-vs-full',
      path: '/workspace/Sources/Engine.swift',
      originalText,
      modifiedText,
      review: true,
      inline: false,
      wordWrap: false,
    });
    assert.ok(shadowRoot.querySelectorAll('[data-separator="line-info"]').length >= 2);
    assert.ok(shadowRoot.querySelectorAll('code[data-additions] [data-line]').length < 37);

    // Identical before/after text: Review mode shows subtle empty state; Full Source renders all lines
    h.omgEditor.activateDiff({
      id: 'identical-file',
      path: '/workspace/Sources/Same.swift',
      originalText: 'let x = 1\nlet y = 2\n',
      modifiedText: 'let x = 1\nlet y = 2\n',
      review: true,
    });
    const emptyBanner = h.document.querySelector('.omg-pierre-diff-empty');
    assert.equal(emptyBanner.hidden, false);

    h.omgEditor.activateDiff({
      id: 'identical-file',
      path: '/workspace/Sources/Same.swift',
      originalText: 'let x = 1\nlet y = 2\n',
      modifiedText: 'let x = 1\nlet y = 2\n',
      review: false,
      inline: true,
    });
    assert.equal(emptyBanner.hidden, true);
    assert.equal(
      shadowRoot.querySelectorAll('code[data-unified] [data-line]').length,
      2
    );
  } finally {
    h.cleanup();
  }
});

test('split vs inline (unified) and wordWrap toggles update synchronously in-place', async () => {
  const h = await createWorkbenchDom();
  try {
    const payload = {
      id: 'layout-toggle',
      path: '/workspace/src/main.zig',
      originalText: 'const std = @import("std");\npub fn run() void {\n    const old_val = 1;\n}\n',
      modifiedText: 'const std = @import("std");\npub fn run() void {\n    const new_val = 42;\n}\n',
      review: true,
      inline: false,
      wordWrap: false,
    };

    h.omgEditor.activateDiff(payload);
    const { container, shadowRoot } = getDiffShadowRoot(h);
    const pre = shadowRoot.querySelector('pre[data-diff]');
    assert.ok(pre);

    // Split + horizontal scroll
    assert.ok(shadowRoot.querySelector('code[data-deletions]'));
    assert.ok(shadowRoot.querySelector('code[data-additions]'));
    assert.equal(shadowRoot.querySelector('code[data-unified]'), null);
    assert.equal(pre.getAttribute('data-overflow'), 'scroll');

    // Toggle inline: true + wordWrap: true on same file
    h.omgEditor.activateDiff({ ...payload, inline: true, wordWrap: true });
    assert.equal(h.document.querySelector('#diff-root diffs-container'), container);
    assert.ok(shadowRoot.querySelector('code[data-unified]'));
    assert.equal(shadowRoot.querySelector('code[data-deletions]'), null);
    assert.equal(shadowRoot.querySelector('code[data-additions]'), null);
    assert.equal(pre.getAttribute('data-overflow'), 'wrap');

    // Toggle back to split + unwrap
    h.omgEditor.activateDiff({ ...payload, inline: false, wordWrap: false });
    assert.ok(shadowRoot.querySelector('code[data-deletions]'));
    assert.ok(shadowRoot.querySelector('code[data-additions]'));
    assert.equal(pre.getAttribute('data-overflow'), 'scroll');
  } finally {
    h.cleanup();
  }
});

test('patchOnly: true renders unified git patches and raw hunk patches with syntax highlighting', async () => {
  const h = await createWorkbenchDom();
  try {
    const gitPatch = [
      'diff --git a/src/parser.rs b/src/parser.rs',
      'index 1111111..2222222 100644',
      '--- a/src/parser.rs',
      '+++ b/src/parser.rs',
      '@@ -10,3 +10,4 @@ pub fn parse_header(input: &str) -> bool {',
      '     let trimmed = input.trim();',
      '-    trimmed.starts_with("OMG")',
      '+    let has_prefix = trimmed.starts_with("OMG:");',
      '+    has_prefix && trimmed.len() > 4',
      ' }',
      '@@ -42,2 +43,3 @@ pub fn reset() {',
      '     let ready = true;',
      '+    log_reset(ready);',
      ' }',
      '',
    ].join('\n');

    assert.equal(
      h.omgEditor.activateDiff({
        id: 'patch-only-1',
        path: 'src/parser.rs',
        patch: gitPatch,
        patchOnly: true,
        review: true,
        inline: true,
      }),
      true
    );

    const diffState = h.omgEditor.getDiffState();
    assert.equal(diffState.patchOnly, true);
    assert.equal(diffState.isPartial, true);
    assert.equal(diffState.hunkCount, 2);
    assert.equal(diffState.changeCount, 2);

    const { shadowRoot } = getDiffShadowRoot(h);
    assert.ok(
      shadowRoot.querySelectorAll('span[style*="--omg-syntax-"]').length > 0,
      'patchOnly diff must still syntax-highlight via @pierre/highlights'
    );
    assert.match(shadowRoot.textContent, /has_prefix/);
    assert.match(shadowRoot.textContent, /log_reset/);

    // Toggling review: false when patchOnly: true must not throw (no full files to hydrate)
    assert.equal(
      h.omgEditor.activateDiff({
        id: 'patch-only-1',
        path: 'src/parser.rs',
        patch: gitPatch,
        patchOnly: true,
        review: false,
        inline: false,
      }),
      true
    );

    // Raw hunk-only patch without ---/+++ headers also parses and renders cleanly
    const rawHunkPatch = [
      '@@ -1,2 +1,2 @@',
      '-const port = 3000;',
      '+const port = 8080;',
      ' export default port;',
    ].join('\n');

    assert.equal(
      h.omgEditor.activateDiff({
        id: 'patch-raw-hunk',
        path: 'config.ts',
        patch: rawHunkPatch,
        patchOnly: true,
        inline: true,
      }),
      true
    );
    assert.match(shadowRoot.textContent, /8080/);
  } finally {
    h.cleanup();
  }
});

test('navigateDiff supports next, previous, wraparound, and direct hunk/change index landing', async () => {
  const h = await createWorkbenchDom();
  try {
    const scrolledLines = [];
    const origScrollIntoView = h.window.Element.prototype.scrollIntoView;
    h.window.Element.prototype.scrollIntoView = function spyScrollIntoView() {
      scrolledLines.push(this.getAttribute('data-line') ?? this.getAttribute('data-column-number'));
    };

    try {
      h.omgEditor.activateDiff({
        id: 'nav-test',
        path: '/workspace/Sources/Nav.swift',
        originalText: buildSampleFile(),
        modifiedText: buildSampleFile({
          modHeader: true,
          modMiddle: true,
          modFooter: true,
        }),
        review: true,
        inline: false,
      });

      assert.equal(h.omgEditor.getDiffState().changeCount, 3);

      // Step forward through changes 0 -> 1 -> 2 -> wraparound 0
      assert.equal(h.omgEditor.navigateDiff({ direction: 'next' }), true);
      assert.equal(h.omgEditor.getDiffState().currentChangeIndex, 0);
      assert.equal(h.omgEditor.getDiffState().currentLineNumber, 1);

      assert.equal(h.omgEditor.navigateDiff({ direction: 'next' }), true);
      assert.equal(h.omgEditor.getDiffState().currentChangeIndex, 1);
      assert.equal(h.omgEditor.getDiffState().currentLineNumber, 19);

      assert.equal(h.omgEditor.navigateDiff({ direction: 'next' }), true);
      assert.equal(h.omgEditor.getDiffState().currentChangeIndex, 2);
      assert.equal(h.omgEditor.getDiffState().currentLineNumber, 37);

      assert.equal(h.omgEditor.navigateDiff({ direction: 'next' }), true);
      assert.equal(h.omgEditor.getDiffState().currentChangeIndex, 0);

      // Step backward 0 -> wraparound 2 -> 1
      assert.equal(h.omgEditor.navigateDiff({ direction: 'previous' }), true);
      assert.equal(h.omgEditor.getDiffState().currentChangeIndex, 2);
      assert.equal(h.omgEditor.getDiffState().currentLineNumber, 37);

      // Direct landing by 0-based index
      assert.equal(h.omgEditor.navigateDiff({ direction: 'next', index: 1 }), true);
      assert.equal(h.omgEditor.getDiffState().currentChangeIndex, 1);
      assert.equal(h.omgEditor.getDiffState().currentLineNumber, 19);

      const { shadowRoot } = getDiffShadowRoot(h);
      // Flush rAF queued by InteractionManager.renderSelection in jsdom
      await new Promise((resolve) => setTimeout(resolve, 25));
      const activeLine = shadowRoot.querySelector('[data-line][data-editor-active-line]');
      assert.ok(activeLine, 'Expected navigated change row to carry [data-editor-active-line]');
      assert.equal(activeLine.getAttribute('data-line'), '19');
      assert.ok(scrolledLines.includes('19'), 'Expected scrollIntoView on navigated change line');
    } finally {
      h.window.Element.prototype.scrollIntoView = origScrollIntoView;
    }
  } finally {
    h.cleanup();
  }
});

test('setTheme and setFont propagate live to Pierre diff while keeping transparent glass backdrop', async () => {
  const h = await createWorkbenchDom();
  try {
    h.omgEditor.activateDiff({
      id: 'theme-font-sync',
      path: '/workspace/theme.ts',
      originalText: 'const count: number = 1;\n',
      modifiedText: 'const count: number = 2;\n',
      review: true,
      inline: false,
    });

    const diffRoot = h.document.getElementById('diff-root');
    const rootEl = h.document.documentElement;
    const { container, shadowRoot } = getDiffShadowRoot(h);

    // Apply custom dark theme
    h.omgEditor.setTheme({
      base: 'vs-dark',
      foreground: '#e6edf3',
      keywords: '#ff7b72',
      functions: '#d2a8ff',
      strings: '#a5d6ff',
      comments: '#8b949e',
      added: '#3fb950',
      deleted: '#f85149',
    });

    assert.equal(rootEl.style.getPropertyValue('--diffs-bg'), 'transparent');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-bg'), 'transparent');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-dark-bg'), 'transparent');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-light-bg'), 'transparent');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-bg-context-override'), 'transparent');
    assert.equal(diffRoot.style.getPropertyValue('--omg-syntax-keyword'), '#ff7b72');
    assert.equal(diffRoot.style.getPropertyValue('--omg-syntax-string'), '#a5d6ff');
    assert.equal(container.getAttribute('data-theme-type'), 'dark');
    const themeCssEl = shadowRoot.querySelector('style[data-theme-css]');
    assert.ok(themeCssEl);
    assert.match(themeCssEl.textContent, /color-scheme:\s*dark/);

    const unsafeStyle = shadowRoot.querySelector('style[data-unsafe-css]');
    assert.ok(unsafeStyle);
    assert.match(unsafeStyle.textContent, /background-color:\s*transparent\s*!important/);

    // Switch live to light theme
    h.omgEditor.setTheme({
      base: 'light',
      foreground: '#1f2328',
      keywords: '#cf222e',
      strings: '#0a3069',
    });
    assert.equal(rootEl.dataset.omgTheme, 'light');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-bg'), 'transparent');
    assert.equal(diffRoot.style.getPropertyValue('--omg-syntax-keyword'), '#cf222e');
    assert.equal(container.getAttribute('data-theme-type'), 'light');
    assert.match(
      shadowRoot.querySelector('style[data-theme-css]').textContent,
      /color-scheme:\s*light/
    );

    // Live font propagation
    h.omgEditor.setFont({
      family: "'Berkeley Mono', monospace",
      size: 16,
      ligatures: false,
    });
    assert.equal(diffRoot.style.getPropertyValue('--diffs-font-family'), "'Berkeley Mono', monospace");
    assert.equal(diffRoot.style.getPropertyValue('--diffs-font-size'), '16px');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-line-height'), '25px');
    assert.equal(diffRoot.style.getPropertyValue('--diffs-font-features'), '"calt" 0, "liga" 0');
  } finally {
    h.cleanup();
  }
});

test('Inline Ask Agent in Pierre diff, keyboard shortcuts, and clean restore on activateModel', async () => {
  const h = await createWorkbenchDom();
  try {
    // Open a Monaco model first and set a selection so we can verify viewState restoration later
    const uri = 'file:///workspace/AppController.swift';
    h.omgEditor.openOrUpdateModel({
      uri,
      path: '/workspace/AppController.swift',
      text: 'import AppKit\nfinal class AppController {\n  func boot() {}\n}\n',
    });
    h.omgEditor.activateModel({ uri, keymapProfile: 'idea' });
    h.omgEditor.revealRange({
      uri,
      startLine: 3,
      startColumn: 8,
      endLine: 3,
      endColumn: 12,
    });

    // Switch to Pierre diff view
    h.omgEditor.activateDiff({
      id: 'ask-agent-diff',
      path: '/workspace/Features/Git/DiffView.swift',
      originalText: 'func oldRender() {\n  print("old")\n}\n',
      modifiedText: 'func newRender() {\n  let mode = "pierre"\n  print(mode)\n}\n',
      review: true,
      inline: false,
    });

    // Clicking/focusing inside #diff-root notifies host of focus
    const scroller = h.document.querySelector('.omg-pierre-diff-scroller');
    scroller.dispatchEvent(new h.window.PointerEvent('pointerdown', { bubbles: true }));
    assert.ok(h.messages.some((m) => m.type === 'focus'));

    // Clicking a line number in the Pierre gutter selects that line and opens Ask Agent
    const { shadowRoot: askShadowRoot } = getDiffShadowRoot(h);
    const gutterLine2 = askShadowRoot.querySelector(
      'code[data-additions] [data-column-number="2"]'
    );
    assert.ok(gutterLine2, 'Expected line 2 gutter number element in additions column');
    gutterLine2.dispatchEvent(
      new h.window.PointerEvent('pointerdown', {
        pointerId: 1,
        button: 0,
        bubbles: true,
        composed: true,
      })
    );
    h.document.dispatchEvent(
      new h.window.PointerEvent('pointerup', {
        pointerId: 1,
        button: 0,
        bubbles: true,
        composed: true,
      })
    );
    assert.equal(h.omgEditor.getState().isAskAgentOpen, true);
    assert.equal(
      h.document.querySelector('#omg-ask-agent-bar .omg-ask-agent-badge').textContent,
      'DiffView.swift#L2'
    );

    // Select lines 2..3 in Pierre diff -> updates floating Ask Agent bar with multi-line badge
    assert.equal(
      h.omgEditor.selectDiffLines({
        startLine: 2,
        endLine: 3,
        side: 'additions',
        openAskAgent: true,
      }),
      true
    );
    assert.equal(h.omgEditor.getState().isAskAgentOpen, true);

    const bar = h.document.getElementById('omg-ask-agent-bar');
    const badge = bar.querySelector('.omg-ask-agent-badge');
    const input = bar.querySelector('.omg-ask-agent-input');
    assert.equal(badge.textContent, 'DiffView.swift#L2-3');

    input.value = 'Extract mode constant into view model';
    input.dispatchEvent(new h.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));

    assert.equal(h.omgEditor.getState().isAskAgentOpen, false);
    const askMsgs = h.messages.filter((m) => m.type === 'askAgent');
    assert.equal(askMsgs.length, 1);
    assert.equal(askMsgs[0].path, '/workspace/Features/Git/DiffView.swift');
    assert.equal(askMsgs[0].startLine, 2);
    assert.equal(askMsgs[0].endLine, 3);
    assert.equal(askMsgs[0].selectedText, '  let mode = "pierre"\n  print(mode)');
    assert.equal(askMsgs[0].prompt, 'Extract mode constant into view model');
    assert.equal(askMsgs[0].comment, 'Extract mode constant into view model');

    // Keyboard shortcut Cmd+Shift+L in diff mode opens Ask Agent bar
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', {
        key: 'L',
        code: 'KeyL',
        metaKey: true,
        shiftKey: true,
        bubbles: true,
      })
    );
    assert.equal(h.omgEditor.getState().isAskAgentOpen, true);

    // Close Ask Agent with Escape, then verify Cmd+W / Cmd+O / Shift+Escape forward hostCommands in diff mode
    input.dispatchEvent(new h.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    assert.equal(h.omgEditor.getState().isAskAgentOpen, false);

    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 'w', metaKey: true, bubbles: true })
    );
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 'o', metaKey: true, bubbles: true })
    );
    h.window.dispatchEvent(
      new h.window.KeyboardEvent('keydown', { key: 'Escape', shiftKey: true, bubbles: true })
    );

    const hostCmds = h.messages.filter((m) => m.type === 'hostCommand').map((m) => m.command);
    assert.deepEqual(hostCmds, ['close', 'open', 'hide']);

    // Switching back to activateModel hides Pierre diff and restores Monaco editor + viewState
    assert.equal(h.omgEditor.activateModel({ uri }), true);
    assert.equal(h.omgEditor.getState().mode, 'editor');
    assert.equal(h.document.getElementById('diff-root').style.display, 'none');
    assert.equal(h.document.getElementById('editor-root').style.display, 'block');
    assert.equal(h.omgEditor._internal.editor.getSelection().startLineNumber, 3);
    assert.equal(h.omgEditor._internal.editor.getSelection().startColumn, 8);
  } finally {
    h.cleanup();
  }
});

test('offline bundle contains zero external CDN fetch URLs', async () => {
  const editorJs = await fs.readFile(path.join(CODE_EDITOR_OUT_DIR, 'editor.js'), 'utf8');
  assert.doesNotMatch(
    editorJs,
    /https?:\/\/(cdn\.|unpkg\.com|jsdelivr\.net|esm\.sh|shiki)/i,
    'editor.js must not reference any external CDN URLs'
  );
});
