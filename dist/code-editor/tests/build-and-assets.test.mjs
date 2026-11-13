import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { CODE_EDITOR_OUT_DIR } from './jsdom-harness.mjs';

test('macos/Resources/CodeEditor contains all offline production assets and licenses', async () => {
  const expectedFiles = [
    'index.html',
    'editor.js',
    'editor.css',
    'editor.worker.js',
    'codicon.ttf',
    'highlights.wasm',
    'THIRD_PARTY_NOTICES.md',
    'licenses/monaco-editor-LICENSE',
    'licenses/monaco-editor-ThirdPartyNotices.txt',
    'licenses/pierre-highlights-LICENSE.md',
    'licenses/pierre-highlights-NOTICE.md',
  ];

  for (const rel of expectedFiles) {
    const stat = await fs.stat(path.join(CODE_EDITOR_OUT_DIR, rel));
    assert.ok(stat.isFile() && stat.size > 0, `Expected non-empty asset: ${rel}`);
  }
});

test('bundle size stays surgical (excludes heavy TS/CSS/HTML compiler workers)', async () => {
  const editorJsStat = await fs.stat(path.join(CODE_EDITOR_OUT_DIR, 'editor.js'));
  const editorCssStat = await fs.stat(path.join(CODE_EDITOR_OUT_DIR, 'editor.css'));
  const workerStat = await fs.stat(path.join(CODE_EDITOR_OUT_DIR, 'editor.worker.js'));
  const wasmStat = await fs.stat(path.join(CODE_EDITOR_OUT_DIR, 'highlights.wasm'));

  // Full Monaco with TS/CSS/HTML language services exceeds 10-12 MB; surgical bundle stays ~4.2 MB.
  assert.ok(
    editorJsStat.size > 500_000 && editorJsStat.size < 6_000_000,
    `Unexpected editor.js size: ${editorJsStat.size}`
  );
  assert.ok(
    editorCssStat.size > 20_000 && editorCssStat.size < 400_000,
    `Unexpected editor.css size: ${editorCssStat.size}`
  );
  assert.ok(
    workerStat.size > 50_000 && workerStat.size < 600_000,
    `Unexpected editor.worker.js size: ${workerStat.size}`
  );
  assert.ok(
    wasmStat.size > 200_000 && wasmStat.size < 500_000,
    `Unexpected highlights.wasm size: ${wasmStat.size}`
  );

  const entries = await fs.readdir(CODE_EDITOR_OUT_DIR);
  const compilerWorkers = entries.filter((name) =>
    /ts\.worker|css\.worker|html\.worker|json\.worker/i.test(name)
  );
  assert.deepEqual(compilerWorkers, [], 'Must not emit heavy compiler workers');
});

test('index.html and editor.css enforce offline CSP, zero CDN URLs, and transparent backdrop', async () => {
  const indexHtml = await fs.readFile(path.join(CODE_EDITOR_OUT_DIR, 'index.html'), 'utf8');
  const editorCss = await fs.readFile(path.join(CODE_EDITOR_OUT_DIR, 'editor.css'), 'utf8');

  assert.match(indexHtml, /Content-Security-Policy/i);
  assert.match(indexHtml, /default-src 'none'/);
  assert.match(indexHtml, /connect-src 'none'/);
  assert.match(indexHtml, /'wasm-unsafe-eval'/);
  assert.match(indexHtml, /worker-src 'self' blob:/);
  assert.match(indexHtml, /background:transparent!important/);
  assert.doesNotMatch(indexHtml, /https?:\/\//i);

  assert.doesNotMatch(editorCss, /https?:\/\//i);
  assert.match(editorCss, /url\(["']?\.\/codicon\.ttf["']?\)/);
  assert.match(editorCss, /\.omg-git-gutter-added/);
  assert.match(editorCss, /\.omg-git-gutter-modified/);
  assert.match(editorCss, /\.omg-git-gutter-deleted/);
  assert.match(editorCss, /\.omg-ask-agent-bar/);
});
