import * as esbuild from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');
const outDir = path.join(repoRoot, 'macos/Resources/CodeEditor');
const licensesDir = path.join(outDir, 'licenses');

const monacoPkgPath = path.join(__dirname, 'node_modules/monaco-editor/package.json');
const pierreHighlightsPkgPath = path.join(
  __dirname,
  'node_modules/@pierre/highlights/package.json'
);
const pierreDiffsPkgPath = path.join(__dirname, 'node_modules/@pierre/diffs/package.json');
const pierreThemingPkgPath = path.join(
  __dirname,
  'node_modules/@pierre/theming/package.json'
);
const diffPkgPath = path.join(__dirname, 'node_modules/diff/package.json');
const hastToHtmlPkgPath = path.join(
  __dirname,
  'node_modules/hast-util-to-html/package.json'
);

const HAST_ECOSYSTEM_PACKAGES = [
  'hast-util-to-html',
  'hast-util-whitespace',
  'property-information',
  'stringify-entities',
  'character-entities-html4',
  'character-entities-legacy',
  'comma-separated-tokens',
  'space-separated-tokens',
  'html-void-elements',
  'ccount',
  'zwitch',
];

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

/**
 * ThinkRail-style surgical plugin for @pierre/diffs:
 * 1. Stubs unused Shiki / bundled theme catalog dynamic imports so only our
 *    offline @pierre/highlights WASM backend + custom CSS-variable Zed theme are bundled.
 * 2. Applies ThinkRail's @pierre/diffs@1.6.4 partial-render row trimming fix.
 */
function createPierreSurgicalPlugin() {
  return {
    name: 'omg-pierre-surgical',
    setup(buildCtx) {
      buildCtx.onResolve(
        {
          filter:
            /^shiki(\/|$)|^@pierre\/highlights\/themes(\/|$)|^@pierre\/theming\/themes$/,
        },
        () => ({
          path: 'omg-pierre-unused-backend-stub',
          namespace: 'omg-pierre-stub',
        })
      );

      buildCtx.onLoad({ filter: /.*/, namespace: 'omg-pierre-stub' }, () => ({
        contents: `
          export const bundledLanguages = {};
          export const createCssVariablesTheme = () => ({
            name: 'css-variables',
            type: 'dark',
            bg: 'transparent',
            fg: 'inherit',
            settings: [],
          });
          export const createHighlighterCore = async () => ({ dispose() {} });
          export const createJavaScriptRegexEngine = () => ({});
          export const createOnigurumaEngine = async () => ({});
          export const EncodedTokenMetadata = {};
          export const INITIAL = null;
          export const normalizeTheme = (t) => t;
          export const themes = {};
          export default { themes: {} };
        `,
        loader: 'js',
      }));

      buildCtx.onLoad({ filter: /@pierre[\\/]diffs[\\/]dist[\\/]components[\\/]FileDiff\.js$/ }, async (args) => {
        let source = await fs.readFile(args.path, 'utf8');
        source = source.replace(
          /if \(gutterElement\.dataset\.gutterBuffer === "annotation" && "lineAnnotation" in contentElement\.dataset\) \{\s*if \(preTrimCount > 0 \|\| hasPostTrim && visibleLineIndex >= postTrimStart\)/,
          'if (gutterElement.dataset.gutterBuffer === "annotation" && "lineAnnotation" in contentElement.dataset) {\n\t\t\t\tif (preTrimCount > 0 || hasPostTrim && visibleLineIndex > postTrimStart)'
        );
        source = source.replace(
          /if \(gutterElement\.dataset\.gutterBuffer === "metadata" && "noNewline" in contentElement\.dataset\) \{\s*if \(preTrimCount > 0 \|\| hasPostTrim && visibleLineIndex >= postTrimStart\)/,
          'if (gutterElement.dataset.gutterBuffer === "metadata" && "noNewline" in contentElement.dataset) {\n\t\t\t\tif (preTrimCount > 0 || hasPostTrim && visibleLineIndex > postTrimStart)'
        );
        return { contents: source, loader: 'js' };
      });
    },
  };
}

async function build() {
  await fs.rm(outDir, { recursive: true, force: true });
  await fs.mkdir(licensesDir, { recursive: true });

  const monacoPkg = JSON.parse(await fs.readFile(monacoPkgPath, 'utf8'));
  const pierreHighlightsPkg = JSON.parse(
    await fs.readFile(pierreHighlightsPkgPath, 'utf8')
  );
  const pierreDiffsPkg = JSON.parse(await fs.readFile(pierreDiffsPkgPath, 'utf8'));
  const pierreThemingPkg = JSON.parse(await fs.readFile(pierreThemingPkgPath, 'utf8'));
  const diffPkg = JSON.parse(await fs.readFile(diffPkgPath, 'utf8'));
  const hastToHtmlPkg = JSON.parse(await fs.readFile(hastToHtmlPkgPath, 'utf8'));

  // 1. Bundle Monaco's core editor web worker (used for link detection, word ops)
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

  // 2. Bundle main surgical Monaco + @pierre/diffs + @pierre/highlights workbench
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
    alias: {
      '@pierre/highlights': path.join(__dirname, 'node_modules/@pierre/highlights'),
    },
    plugins: [createPierreSurgicalPlugin()],
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
  await fs.copyFile(
    path.join(__dirname, 'node_modules/@pierre/diffs/LICENSE.md'),
    path.join(licensesDir, 'pierre-diffs-LICENSE.md')
  );
  await fs.copyFile(
    path.join(__dirname, 'node_modules/@pierre/theming/LICENSE.md'),
    path.join(licensesDir, 'pierre-theming-LICENSE.md')
  );
  await fs.copyFile(
    path.join(__dirname, 'node_modules/diff/LICENSE'),
    path.join(licensesDir, 'diff-LICENSE')
  );

  const hastLicenseBlocks = [];
  for (const pkgName of HAST_ECOSYSTEM_PACKAGES) {
    const pkgDir = path.join(__dirname, 'node_modules', pkgName);
    const pkgJson = JSON.parse(
      await fs.readFile(path.join(pkgDir, 'package.json'), 'utf8')
    );
    const licText = await fs.readFile(path.join(pkgDir, 'license'), 'utf8');
    hastLicenseBlocks.push(`=== ${pkgJson.name}@${pkgJson.version} (${pkgJson.license}) ===\n\n${licText.trim()}`);
  }
  await fs.writeFile(
    path.join(licensesDir, 'hast-ecosystem-MIT-LICENSES.txt'),
    `${hastLicenseBlocks.join('\n\n----------------------------------------\n\n')}\n`,
    'utf8'
  );

  const thirdPartyNotices = `# Code Editor dependencies

All editor, diff, icon font, worker, and WebAssembly syntax highlighting assets in
this directory are bundled for 100% offline use via OMG's local custom URL scheme
handlers (\`omg-code://app/\` / \`omg-editor://bundle/\`). Runtime code never fetches
remote scripts, stylesheets, workers, grammars, or fonts.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| monaco-editor (surgical core + Codicons) | ${monacoPkg.version} | MIT | https://github.com/microsoft/monaco-editor |
| @pierre/diffs (vanilla FileDiff + patch parser) | ${pierreDiffsPkg.version} | Apache-2.0 | https://github.com/pierrecomputer/pierre |
| @pierre/highlights (LiveTokenizer WASM/SIMD) | ${pierreHighlightsPkg.version} | Apache-2.0 | https://github.com/pierrecomputer/pierre |
| @pierre/theming (Zed CSS-variable theme resolver) | ${pierreThemingPkg.version} | Apache-2.0 | https://github.com/pierrecomputer/pierre |
| diff (jsdiff unified patch engine) | ${diffPkg.version} | BSD-3-Clause | https://github.com/kpdecker/jsdiff |
| hast-util-to-html & syntax-tree/unified HAST helpers | ${hastToHtmlPkg.version} | MIT | https://github.com/syntax-tree/hast-util-to-html |

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
