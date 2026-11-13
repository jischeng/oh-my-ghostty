import * as esbuild from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');
const outDir = path.join(repoRoot, 'macos/Resources/CodeEditor');
const licensesDir = path.join(outDir, 'licenses');

const monacoPkgPath = path.join(__dirname, 'node_modules/monaco-editor/package.json');
const pierrePkgPath = path.join(__dirname, 'node_modules/@pierre/highlights/package.json');

const INDEX_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'wasm-unsafe-eval' blob:; worker-src 'self' blob:; child-src 'self' blob:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data: blob:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <title>OMG Code Editor</title>
  <style>html,body,#app,#editor-root,#diff-root{background:transparent!important;margin:0;padding:0;width:100%;height:100%;overflow:hidden;}</style>
  <link rel="stylesheet" href="editor.css">
  <script defer src="editor.js"></script>
</head>
<body>
  <div id="app">
    <div id="editor-root"></div>
    <div id="diff-root" style="display:none"></div>
  </div>
</body>
</html>
`;

async function build() {
  await fs.rm(outDir, { recursive: true, force: true });
  await fs.mkdir(licensesDir, { recursive: true });

  const monacoPkg = JSON.parse(await fs.readFile(monacoPkgPath, 'utf8'));
  const pierrePkg = JSON.parse(await fs.readFile(pierrePkgPath, 'utf8'));

  // 1. Bundle Monaco's core editor web worker (used for diffing, link detection, word ops)
  const workerBuild = await esbuild.build({
    entryPoints: [path.join(__dirname, 'src/editor.worker.mjs')],
    bundle: true,
    write: false,
    format: 'iife',
    platform: 'browser',
    target: ['safari17'],
    minify: true,
    legalComments: 'none',
  });

  const workerCode = workerBuild.outputFiles[0].text;
  await fs.writeFile(path.join(outDir, 'editor.worker.js'), workerCode, 'utf8');

  // 2. Bundle main surgical Monaco + @pierre/highlights workbench
  await esbuild.build({
    entryPoints: {
      editor: path.join(__dirname, 'src/main.mjs'),
    },
    outdir: outDir,
    bundle: true,
    format: 'iife',
    platform: 'browser',
    target: ['safari17'],
    minify: true,
    legalComments: 'none',
    assetNames: '[name]',
    loader: {
      '.ttf': 'file',
    },
    define: {
      __OMG_EDITOR_WORKER_CODE__: JSON.stringify(workerCode),
    },
  });

  // 3. Copy standalone @pierre/highlights WASM binary asset
  await fs.copyFile(
    path.join(__dirname, 'node_modules/@pierre/highlights/dist/highlights.wasm'),
    path.join(outDir, 'highlights.wasm')
  );

  // 4. Write offline index.html
  await fs.writeFile(path.join(outDir, 'index.html'), INDEX_HTML, 'utf8');

  // 5. Copy third-party licenses & generate THIRD_PARTY_NOTICES.md
  await fs.copyFile(
    path.join(__dirname, 'node_modules/monaco-editor/LICENSE'),
    path.join(licensesDir, 'monaco-editor-LICENSE')
  );
  await fs.copyFile(
    path.join(__dirname, 'node_modules/monaco-editor/ThirdPartyNotices.txt'),
    path.join(licensesDir, 'monaco-editor-ThirdPartyNotices.txt')
  );
  await fs.copyFile(
    path.join(__dirname, 'node_modules/@pierre/highlights/LICENSE.md'),
    path.join(licensesDir, 'pierre-highlights-LICENSE.md')
  );
  await fs.copyFile(
    path.join(__dirname, 'node_modules/@pierre/highlights/NOTICE.md'),
    path.join(licensesDir, 'pierre-highlights-NOTICE.md')
  );

  const thirdPartyNotices = `# Code Editor dependencies

All editor, diff, icon font, worker, and WebAssembly syntax highlighting assets in
this directory are bundled for 100% offline use via OMG's \`omg-editor://bundle/\`
scheme handler. Runtime code never fetches remote scripts, stylesheets, workers,
or fonts.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| monaco-editor (surgical core + Codicons) | ${monacoPkg.version} | MIT | https://github.com/microsoft/monaco-editor |
| @pierre/highlights (LiveTokenizer WASM/SIMD) | ${pierrePkg.version} | Apache-2.0 | https://github.com/pierrecomputer/pierre |

Original copyright, license, and upstream notice files are retained in \`licenses/\`.
`;
  await fs.writeFile(path.join(outDir, 'THIRD_PARTY_NOTICES.md'), thirdPartyNotices, 'utf8');

  return { outDir };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  build().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

export { build };
