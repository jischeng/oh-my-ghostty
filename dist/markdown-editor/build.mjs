import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {readFile, writeFile, readdir} from 'node:fs/promises';
import path from 'node:path';
const outdir = fileURLToPath(new URL('../../macos/Resources/MarkdownPreview', import.meta.url));
const result = await build({entryPoints: ['editor.js'], outdir, entryNames: 'live-editor', bundle: true,
    format: 'iife', platform: 'browser', target: 'safari16', minify: true,
    legalComments: 'linked', metafile: true});
const packages = new Set(Object.keys(result.metafile.inputs).filter(input => input.startsWith('node_modules/')).map(input => {
    const parts = input.slice('node_modules/'.length).split('/');
    return parts[0].startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
}));
const notices = [];
for (const name of [...packages].sort()) {
    const directory = path.join('node_modules', name);
    const pkg = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
    const license = (await readdir(directory)).find(file => /^(licen[cs]e|copying)(\.|$)/i.test(file));
    notices.push(`${name}@${pkg.version} (${pkg.license || 'See source'})\n${license ? await readFile(path.join(directory, license), 'utf8') : 'License text: ' + (pkg.repository?.url || pkg.homepage || '')}`);
}
await writeFile(path.join(outdir, 'licenses', 'codemirror-editor.txt'), notices.join('\n\n' + '='.repeat(72) + '\n\n').replace(/[\t ]+$/gm, '').trimEnd() + '\n');
