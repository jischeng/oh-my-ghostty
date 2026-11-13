import assert from 'node:assert/strict';
import test from 'node:test';
import { LiveTokenizer } from '@pierre/highlights';
import {
  decodePacked24Records,
  MAX_LINE_LENGTH,
  MAX_MODEL_LINES,
} from '../src/highlighting.mjs';
import {
  getPierreLanguageForMonacoId,
  resolveMonacoLanguageId,
} from '../src/languages.mjs';

const DUMMY_THEME = { name: 'test', appearance: 'dark', style: {} };

test('ThinkRail safety caps match specification', () => {
  assert.equal(MAX_LINE_LENGTH, 20_000);
  assert.equal(MAX_MODEL_LINES, 300_000);
});

test('resolves all required OMG file extensions and falls back gracefully on unknown types', () => {
  const requiredMappings = [
    ['config.ghostty', 'ghostty', 'ini'],
    ['nginx.conf', 'conf', 'ini'],
    ['Cargo.toml', 'toml', 'toml'],
    ['build.zig', 'zig', 'zig'],
    ['AppDelegate.swift', 'swift', 'swift'],
    ['lib.rs', 'rust', 'rust'],
    ['plan.py', 'python', 'python'],
    ['index.ts', 'typescript', 'ts'],
    ['View.tsx', 'tsx', 'tsx'],
    ['build.js', 'javascript', 'js'],
    ['package.json', 'json', 'jsonc'],
    ['ci.yaml', 'yaml', 'yaml'],
    ['README.md', 'markdown', 'markdown'],
    ['install.sh', 'shell', 'bash'],
    ['main.c', 'c', 'c'],
    ['renderer.cpp', 'cpp', 'cpp'],
    ['server.go', 'go', 'go'],
    ['index.html', 'html', 'html'],
    ['styles.css', 'css', 'css'],
    ['Info.xml', 'xml', 'xml'],
    ['schema.sql', 'sql', 'sql'],
  ];

  for (const [filename, expectedMonaco, expectedPierre] of requiredMappings) {
    const monacoId = resolveMonacoLanguageId({ path: `/workspace/${filename}` });
    assert.equal(monacoId, expectedMonaco, `Unexpected Monaco ID for ${filename}`);
    assert.equal(
      getPierreLanguageForMonacoId(monacoId),
      expectedPierre,
      `Unexpected Pierre grammar for ${filename}`
    );
  }

  // Graceful fallback for unknown extensions and hints
  assert.equal(resolveMonacoLanguageId({ path: '/workspace/mystery.unknownext999' }), 'plaintext');
  assert.equal(
    resolveMonacoLanguageId({ languageHint: 'totally-made-up-language', path: '/workspace/foo' }),
    'plaintext'
  );
  assert.equal(getPierreLanguageForMonacoId('plaintext'), null);
});

test('@pierre/highlights LiveTokenizer packed24 records decode into Monaco scopes and update incrementally', () => {
  const code = [
    'import Foundation',
    '@MainActor final class EditorHost {',
    '    // Line comment',
    '    func answer() -> Int { return 42 }',
    '}',
  ].join('\n');

  const lt = new LiveTokenizer({
    lang: 'swift',
    theme: DUMMY_THEME,
    code,
    tokenizeMaxLineLength: MAX_LINE_LENGTH,
  });

  try {
    const line0 = lt.getLineRecords(0);
    assert.equal(line0.format, 'packed24');
    const tokens0 = decodePacked24Records(line0, lt.getLineLength(0));
    assert.ok(tokens0.some((t) => t.scopes === 'keyword'));
    assert.ok(tokens0.some((t) => t.scopes === 'type'));

    const tokens2 = decodePacked24Records(lt.getLineRecords(2), lt.getLineLength(2));
    assert.ok(tokens2.some((t) => t.scopes === 'comment'));

    const tokens3 = decodePacked24Records(lt.getLineRecords(3), lt.getLineLength(3));
    assert.ok(tokens3.some((t) => t.scopes === 'function'));
    assert.ok(tokens3.some((t) => t.scopes === 'number'));

    // Open a multi-line /* block comment on line 1 and verify line 3 re-tokenizes as comment!
    const update = lt.applyEdits([
      {
        range: {
          start: { line: 1, character: 0 },
          end: { line: 1, character: 0 },
        },
        newText: '/* ',
      },
    ]);
    assert.ok(update.lineChanges.length > 0);
    const commentedLine3 = decodePacked24Records(lt.getLineRecords(3), lt.getLineLength(3));
    assert.deepEqual(commentedLine3, [{ startIndex: 0, scopes: 'comment' }]);
  } finally {
    lt.dispose();
  }
});

test('decodePacked24Records enforces MAX_LINE_LENGTH = 20_000 cap cleanly', () => {
  const fakeRecords = {
    revision: 1,
    format: 'packed24',
    data: new Uint32Array([(17 << 24) | 20_001]),
  };
  assert.deepEqual(decodePacked24Records(fakeRecords, MAX_LINE_LENGTH + 1), []);
});
